#!/usr/bin/env bash
set -euo pipefail

write_bridge_config() {
  local config_file="${BRIDGE_CONFIG_FILE:-/opt/livesync-bridge/dat/config.json}"
  mkdir -p "$(dirname "${config_file}")" "${BRIDGE_STORAGE_PATH:-/data/vault}"

  jq -n \
    --arg url "${COUCHDB_URL:-http://couchdb:5984}" \
    --arg database "${LIVESYNC_DATABASE:?Missing LIVESYNC_DATABASE}" \
    --arg username "${COUCHDB_USER:?Missing COUCHDB_USER}" \
    --arg password "${COUCHDB_PASSWORD:?Missing COUCHDB_PASSWORD}" \
    --arg passphrase "${LIVESYNC_PASSPHRASE:-}" \
    --arg obfuscatePassphrase "${LIVESYNC_OBFUSCATE_PASSPHRASE:-${LIVESYNC_PASSPHRASE:-}}" \
    --arg baseDir "${LIVESYNC_BASE_DIR:-}" \
    --arg storage "${BRIDGE_STORAGE_PATH:-/data/vault}" \
    '{
      peers: [
        {
          type: "couchdb",
          name: "livesync",
          group: "main",
          url: $url,
          database: $database,
          username: $username,
          password: $password,
          passphrase: $passphrase,
          obfuscatePassphrase: $obfuscatePassphrase,
          baseDir: $baseDir,
          useRemoteTweaks: true
        },
        {
          type: "storage",
          name: "vault-files",
          group: "main",
          baseDir: $storage,
          scanOfflineChanges: false
        }
      ]
    }' > "${config_file}"
}

wait_for_couchdb() {
  local url="${COUCHDB_URL:-http://couchdb:5984}"
  local attempts="${COUCHDB_WAIT_ATTEMPTS:-60}"

  for _ in $(seq 1 "${attempts}"); do
    if curl -fsS -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" "${url}/" >/dev/null; then
      return
    fi
    sleep 2
  done

  echo "CouchDB did not become ready: ${url}" >&2
  exit 1
}

couchdb_put_config() {
  local section="$1"
  local key="$2"
  local value="$3"
  local url="${COUCHDB_URL:-http://couchdb:5984}"
  local json_value

  json_value="$(jq -Rn --arg value "${value}" '$value')"
  curl -fsS \
    -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
    -X PUT \
    -H "Content-Type: application/json" \
    --data "${json_value}" \
    "${url}/_node/_local/_config/${section}/${key}" >/dev/null
}

configure_couchdb() {
  local url="${COUCHDB_URL:-http://couchdb:5984}"
  local db="${LIVESYNC_DATABASE:?Missing LIVESYNC_DATABASE}"
  local status

  wait_for_couchdb

  couchdb_put_config chttpd enable_cors true
  couchdb_put_config httpd enable_cors true
  couchdb_put_config chttpd require_valid_user true
  couchdb_put_config chttpd_auth require_valid_user true || true
  couchdb_put_config cors credentials true
  couchdb_put_config cors origins "${COUCHDB_CORS_ORIGINS:-app://obsidian.md,capacitor://localhost,http://localhost}"
  couchdb_put_config cors headers "${COUCHDB_CORS_HEADERS:-accept,authorization,content-type,origin,referer}"
  couchdb_put_config cors methods "${COUCHDB_CORS_METHODS:-GET,PUT,POST,HEAD,DELETE}"

  status="$(curl -sS -o /dev/null -w "%{http_code}" \
    -u "${COUCHDB_USER}:${COUCHDB_PASSWORD}" \
    -X PUT \
    "${url}/${db}")"

  if [[ "${status}" != "201" && "${status}" != "412" ]]; then
    echo "Could not create or verify CouchDB database ${db}: HTTP ${status}" >&2
    exit 1
  fi
}

write_targets_config() {
  if [[ -f "${TARGETS_FILE}" ]]; then
    return
  fi

  if [[ -n "${TARGETS_JSON:-}" ]]; then
    mkdir -p "$(dirname "${TARGETS_FILE}")"
    printf '%s\n' "${TARGETS_JSON}" > "${TARGETS_FILE}"
    return
  fi

  if [[ -n "${GIT_REMOTE_URL:-}" ]]; then
    mkdir -p "$(dirname "${TARGETS_FILE}")"
    jq -n \
      --arg name "${GIT_TARGET_NAME:-vault}" \
      --arg source "${GIT_SOURCE:-/vault}" \
      --arg worktree "${GIT_WORKTREE:-/git/vault}" \
      --arg remote "${GIT_REMOTE_URL}" \
      --arg branch "${GIT_BRANCH:-main}" \
      --arg message "${GIT_COMMIT_MESSAGE:-backup(vault): Snapshot {{date}}}" \
      --arg excludes "${GIT_EXCLUDES:-.gitmodules,.gitignore,.editorconfig,.prettierignore,.prettierrc.json,.obsidian/,.trash/,node_modules/}" \
      --arg autoSubmodules "${AUTO_SUBMODULES:-true}" \
      '{
        targets: [
          {
            name: $name,
            source: $source,
            worktree: $worktree,
            remote: $remote,
            branch: $branch,
            commit_message: $message,
            auto_submodules: ($autoSubmodules == "true"),
            exclude: ($excludes | split(",") | map(select(length > 0)))
          }
        ]
      }' > "${TARGETS_FILE}"
    return
  fi

  echo "Missing targets. Provide TARGETS_FILE, TARGETS_JSON, or GIT_REMOTE_URL." >&2
  exit 1
}

run_bridge() {
  configure_couchdb
  write_bridge_config
  echo "LiveSync Bridge wrapper started"
  echo "Database: ${LIVESYNC_DATABASE}"
  echo "Storage: ${BRIDGE_STORAGE_PATH:-/data/vault}"
  cd /opt/livesync-bridge
  export LSB_CONFIG="${BRIDGE_CONFIG_FILE:-/opt/livesync-bridge/dat/config.json}"
  exec deno task run
}

run_backup() {
  write_targets_config

  if ! jq empty "${TARGETS_FILE}" >/dev/null; then
    echo "Invalid JSON in ${TARGETS_FILE}" >&2
    exit 1
  fi

  mkdir -p /var/log
  touch /var/log/cron.log

  echo "${CRON_SCHEDULE} /usr/local/bin/livesync-git-backup >> /var/log/cron.log 2>&1" > /etc/crontabs/root

  echo "LiveSync Git backup worker started"
  echo "Schedule: ${CRON_SCHEDULE}"
  echo "Targets: ${TARGETS_FILE}"

  if [[ "${RUN_ON_START:-true}" == "true" ]]; then
    /usr/local/bin/livesync-git-backup || true
  fi

  crond -l 2 -f &
  tail -f /var/log/cron.log
}

case "${MODE:-backup}" in
  bridge)
    run_bridge
    ;;
  backup)
    run_backup
    ;;
  *)
    echo "Unknown MODE: ${MODE}" >&2
    exit 1
    ;;
esac
