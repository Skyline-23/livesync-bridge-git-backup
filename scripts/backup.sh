#!/usr/bin/env bash
set -euo pipefail

LOCK_FILE="/tmp/livesync-git-backup.lock"
DATE_VALUE="$(date '+%Y-%m-%d %H:%M:%S')"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

setup_ssh() {
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"

  if [[ -n "${SSH_PRIVATE_KEY_BASE64:-}" ]]; then
    if ! printf '%s' "${SSH_PRIVATE_KEY_BASE64}" | tr -d '[:space:]' | base64 -d > "${HOME}/.ssh/id_rsa"; then
      echo "Invalid SSH_PRIVATE_KEY_BASE64. Provide a base64-encoded OpenSSH private key." >&2
      exit 1
    fi
  elif [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    printf '%b\n' "${SSH_PRIVATE_KEY}" > "${HOME}/.ssh/id_rsa"
  fi

  if [[ -f "${HOME}/.ssh/id_rsa" ]]; then
    sed -i 's/\r$//' "${HOME}/.ssh/id_rsa"
    chmod 600 "${HOME}/.ssh/id_rsa"
    if ! ssh-keygen -y -f "${HOME}/.ssh/id_rsa" >/dev/null; then
      echo "Invalid SSH private key. Check SSH_PRIVATE_KEY_BASE64 or SSH_PRIVATE_KEY formatting." >&2
      exit 1
    fi
  fi
}

setup_git_auth() {
  local token username
  token="$(git_token)"
  username="${GIT_USERNAME:-x-access-token}"

  if [[ -z "${token}" ]]; then
    return
  fi

  git config --global url."https://${username}:${token}@github.com/".insteadOf "https://github.com/"
  git config --global url."https://${username}:${token}@github.com/".insteadOf "git@github.com:"
  git config --global url."https://${username}:${token}@github.com/".insteadOf "ssh://git@github.com/"
}

remote_host() {
  local remote="$1"
  if [[ "${remote}" =~ ^git@([^:]+): ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "${remote}" =~ ^ssh://[^@]+@([^/]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "${remote}" =~ ^https://([^/]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi
}

trust_remote_host() {
  local remote="$1"
  local host
  host="$(remote_host "${remote}")"
  if [[ -n "${host}" ]]; then
    ssh-keyscan -H "${host}" >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true
  fi
}

git_token() {
  if [[ -n "${GIT_TOKEN:-}" ]]; then
    printf '%s\n' "${GIT_TOKEN}"
    return
  fi
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf '%s\n' "${GITHUB_TOKEN}"
  fi
}

auth_remote() {
  local remote="$1"
  local token username
  token="$(git_token)"
  username="${GIT_USERNAME:-x-access-token}"

  if [[ -z "${token}" ]]; then
    printf '%s\n' "${remote}"
    return
  fi

  if [[ "${remote}" =~ ^https://github.com/(.+)$ ]]; then
    printf 'https://%s:%s@github.com/%s\n' "${username}" "${token}" "${BASH_REMATCH[1]}"
    return
  fi

  printf '%s\n' "${remote}"
}

redact_remote() {
  sed -E 's#https://([^:/]+):[^@]+@#https://\\1:***@#' <<< "$1"
}

json_target() {
  local index="$1"
  jq -c ".targets[${index}]" "${TARGETS_FILE}"
}

json_value() {
  local target="$1"
  local expr="$2"
  jq -r "${expr} // empty" <<< "${target}"
}

json_bool() {
  local target="$1"
  local expr="$2"
  jq -r "${expr} // false" <<< "${target}"
}

ensure_worktree() {
  local name="$1"
  local remote="$2"
  local branch="$3"
  local worktree="$4"
  local remote_auth
  remote_auth="$(auth_remote "${remote}")"

  if [[ ! -d "${worktree}/.git" ]]; then
    log "${name}: cloning $(redact_remote "${remote_auth}")#${branch}"
    rm -rf "${worktree}"
    mkdir -p "$(dirname "${worktree}")"
    git clone --branch "${branch}" "${remote_auth}" "${worktree}"
  fi

  git -C "${worktree}" remote set-url origin "${remote_auth}"
  git -C "${worktree}" fetch origin "${branch}"
  git -C "${worktree}" checkout "${branch}"
  git -C "${worktree}" pull --ff-only origin "${branch}"
}

submodule_name_from_key() {
  local key="$1"
  key="${key#submodule.}"
  printf '%s\n' "${key%.path}"
}

submodule_target() {
  local parent="$1"
  local module_name="$2"
  local path="$3"
  local remote="$4"
  local branch="$5"
  local source worktree safe_name excludes

  source="$(json_value "${parent}" '.source')/${path}"
  safe_name="${path//\//-}"
  worktree="${SUBMODULE_WORKTREE_ROOT:-/git/submodules}/${path}"
  excludes="${SUBMODULE_GIT_EXCLUDES:-.gitmodules,.gitignore,.editorconfig,.prettierignore,.prettierrc.json,.obsidian/,.trash/,node_modules/}"

  jq -n \
    --arg name "${module_name:-${safe_name}}" \
    --arg source "${source}" \
    --arg worktree "${worktree}" \
    --arg remote "${remote}" \
    --arg branch "${branch}" \
    --arg message "backup(${safe_name}): Snapshot {{date}}" \
    --arg excludes "${excludes}" \
    '{
      name: $name,
      source: $source,
      worktree: $worktree,
      remote: $remote,
      branch: $branch,
      commit_message: $message,
      optional_source: true,
      exclude: ($excludes | split(",") | map(select(length > 0)))
    }'
}

parent_target_with_submodules() {
  local parent="$1"
  local submodules_json="$2"
  jq --argjson submodules "${submodules_json}" \
    '.auto_submodules = false
      | .submodules = ((.submodules // []) + $submodules)
      | .exclude = (((.exclude // []) + ($submodules | map(.path + "/"))) | unique)' \
    <<< "${parent}"
}

expand_auto_submodule_target() {
  local target="$1"
  local name remote branch worktree module_name path url module_branch submodules target_file

  if [[ "$(json_bool "${target}" '.auto_submodules')" != "true" ]]; then
    printf '%s\n' "${target}"
    return
  fi

  name="$(json_value "${target}" '.name')"
  remote="$(json_value "${target}" '.remote')"
  branch="$(json_value "${target}" '.branch')"
  worktree="$(json_value "${target}" '.worktree')"
  branch="${branch:-main}"

  trust_remote_host "${remote}"
  ensure_worktree "${name}" "${remote}" "${branch}" "${worktree}" >&2

  if [[ ! -f "${worktree}/.gitmodules" ]]; then
    printf '%s\n' "$(jq '.auto_submodules = false' <<< "${target}")"
    return
  fi

  target_file="$(mktemp)"
  submodules="[]"

  while read -r key path; do
    module_name="$(submodule_name_from_key "${key}")"
    url="$(git -C "${worktree}" config --file .gitmodules --get "submodule.${module_name}.url")"
    module_branch="$(git -C "${worktree}" config --file .gitmodules --get "submodule.${module_name}.branch" || true)"
    module_branch="${module_branch:-main}"

    trust_remote_host "${url}"
    submodule_target "${target}" "${module_name}" "${path}" "${url}" "${module_branch}" >> "${target_file}"
    submodules="$(jq -c --arg path "${path}" --arg branch "${module_branch}" '. + [{path: $path, branch: $branch}]' <<< "${submodules}")"
  done < <(git -C "${worktree}" config --file .gitmodules --get-regexp 'submodule\..*\.path' || true)

  if [[ -s "${target_file}" ]]; then
    cat "${target_file}"
  fi
  rm -f "${target_file}"

  parent_target_with_submodules "${target}" "${submodules}"
}

expand_targets() {
  local expanded_file expanded_objects length
  expanded_file="$(mktemp)"
  expanded_objects="$(mktemp)"
  length="$(jq '.targets | length' "${TARGETS_FILE}")"

  for ((i = 0; i < length; i++)); do
    expand_auto_submodule_target "$(json_target "${i}")" >> "${expanded_objects}"
  done

  jq -s '{targets: .}' "${expanded_objects}" > "${expanded_file}"

  mv "${expanded_file}" "${TARGETS_FILE}"
  rm -f "${expanded_objects}"
}

write_rsync_filter() {
  local target="$1"
  local filter_file="$2"
  {
    printf -- '- .git\n'
    printf -- '- .git/\n'
    printf -- '- .git/**\n'
    jq -r '.exclude[]? | "- " + .' <<< "${target}"
  } > "${filter_file}"
}

sync_files() {
  local name="$1"
  local target="$2"
  local source="$3"
  local worktree="$4"
  local optional_source
  local filter_file="/tmp/${name}.rsync-filter"
  optional_source="$(json_bool "${target}" '.optional_source')"

  if [[ ! -d "${source}" ]]; then
    if [[ "${optional_source}" == "true" ]]; then
      log "${name}: optional source does not exist, skipping target: ${source}"
      return 2
    fi
    log "${name}: source does not exist: ${source}"
    return 1
  fi

  write_rsync_filter "${target}" "${filter_file}"
  log "${name}: syncing ${source}/ -> ${worktree}/"

  rsync -a --delete --filter="merge ${filter_file}" "${source}/" "${worktree}/"
}

update_submodules() {
  local name="$1"
  local target="$2"
  local worktree="$3"
  local count path branch

  count="$(jq '.submodules // [] | length' <<< "${target}")"
  if [[ "${count}" == "0" ]]; then
    return
  fi

  log "${name}: syncing submodule metadata"
  git -C "${worktree}" submodule sync --recursive
  git -C "${worktree}" submodule update --init --recursive

  for ((i = 0; i < count; i++)); do
    path="$(jq -r ".submodules[${i}].path // empty" <<< "${target}")"
    branch="$(jq -r ".submodules[${i}].branch // \"main\"" <<< "${target}")"

    if [[ -z "${path}" ]]; then
      log "${name}: invalid submodule entry: missing path"
      return 1
    fi

    git -C "${worktree}" submodule update --init -- "${path}"
    git -C "${worktree}/${path}" fetch origin "${branch}"
    git -C "${worktree}/${path}" checkout "${branch}"
    git -C "${worktree}/${path}" pull --ff-only origin "${branch}"
    log "${name}: submodule ${path} updated from origin/${branch}"
  done
}

commit_and_push() {
  local name="$1"
  local target="$2"
  local worktree="$3"
  local branch="$4"
  local template message

  template="$(json_value "${target}" '.commit_message')"
  if [[ -z "${template}" ]]; then
    template="backup(${name}): Snapshot {{date}}"
  fi

  message="${template//\{\{date\}\}/${DATE_VALUE}}"
  message="${message//\{\{name\}\}/${name}}"

  git -C "${worktree}" config user.name "${GIT_AUTHOR_NAME}"
  git -C "${worktree}" config user.email "${GIT_AUTHOR_EMAIL}"
  git -C "${worktree}" add -A

  if git -C "${worktree}" diff --cached --quiet; then
    log "${name}: no changes"
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "${name}: dry run, would commit: ${message}"
    git -C "${worktree}" status --short
    return
  fi

  git -C "${worktree}" commit -m "${message}"
  git -C "${worktree}" push origin "${branch}"
  log "${name}: pushed ${branch}"
}

run_target() {
  local target="$1"
  local name source worktree remote branch

  name="$(json_value "${target}" '.name')"
  source="$(json_value "${target}" '.source')"
  worktree="$(json_value "${target}" '.worktree')"
  remote="$(json_value "${target}" '.remote')"
  branch="$(json_value "${target}" '.branch')"

  branch="${branch:-main}"

  if [[ -z "${name}" || -z "${source}" || -z "${worktree}" || -z "${remote}" ]]; then
    log "Invalid target: ${target}"
    return 1
  fi

  log "${name}: starting"
  trust_remote_host "${remote}"
  ensure_worktree "${name}" "${remote}" "${branch}" "${worktree}"
  sync_files "${name}" "${target}" "${source}" "${worktree}" || {
    local sync_status="$?"
    if [[ "${sync_status}" == "2" ]]; then
      return 0
    fi
    return "${sync_status}"
  }
  update_submodules "${name}" "${target}" "${worktree}"
  commit_and_push "${name}" "${target}" "${worktree}" "${branch}"
}

main() {
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    log "Another backup is already running"
    exit 0
  fi

  setup_ssh
  setup_git_auth
  expand_targets

  local length
  length="$(jq '.targets | length' "${TARGETS_FILE}")"
  for ((i = 0; i < length; i++)); do
    run_target "$(json_target "${i}")"
  done
}

main "$@"
