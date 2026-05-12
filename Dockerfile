FROM denoland/deno:alpine-2.3.1

WORKDIR /app

RUN apk add --no-cache \
  bash \
  curl \
  dcron \
  git \
  jq \
  openssh-client \
  rsync \
  tzdata \
  util-linux

RUN git clone --depth 1 --recursive https://github.com/vrtmrz/livesync-bridge.git /opt/livesync-bridge \
  && cd /opt/livesync-bridge \
  && deno install --global -A

COPY scripts/backup.sh /usr/local/bin/livesync-git-backup
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint

RUN chmod +x /usr/local/bin/livesync-git-backup /usr/local/bin/entrypoint \
  && touch /var/log/cron.log

ENV MODE="backup" \
  CRON_SCHEDULE="0 */6 * * *" \
  TARGETS_FILE="/config/targets.json" \
  GIT_USERNAME="x-access-token" \
  GIT_AUTHOR_NAME="LiveSync Backup Bot" \
  GIT_AUTHOR_EMAIL="livesync-backup@noreply.local" \
  DRY_RUN="false"

ENTRYPOINT ["/usr/local/bin/entrypoint"]
