#!/usr/bin/env bash
set -euo pipefail

LOCK_FILE="/tmp/livesync-git-backup.lock"
DATE_VALUE="$(date '+%Y-%m-%d %H:%M:%S')"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

setup_ssh() {
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"

  if [[ -n "${SSH_PRIVATE_KEY_BASE64:-}" ]]; then
    printf '%s' "${SSH_PRIVATE_KEY_BASE64}" | base64 -d > "${HOME}/.ssh/id_rsa"
  elif [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
    printf '%s\n' "${SSH_PRIVATE_KEY}" > "${HOME}/.ssh/id_rsa"
  fi

  if [[ -f "${HOME}/.ssh/id_rsa" ]]; then
    chmod 600 "${HOME}/.ssh/id_rsa"
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

write_rsync_filter() {
  local target="$1"
  local filter_file="$2"
  {
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
  local filter_file="/tmp/${name}.rsync-filter"

  if [[ ! -d "${source}" ]]; then
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

  for i in $(seq 0 $((count - 1))); do
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
  sync_files "${name}" "${target}" "${source}" "${worktree}"
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

  local length
  length="$(jq '.targets | length' "${TARGETS_FILE}")"
  for i in $(seq 0 $((length - 1))); do
    run_target "$(json_target "${i}")"
  done
}

main "$@"
