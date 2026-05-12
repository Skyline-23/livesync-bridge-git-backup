#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f "${TARGETS_FILE}" ]]; then
  echo "Missing targets file: ${TARGETS_FILE}" >&2
  exit 1
fi

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
