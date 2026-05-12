FROM alpine:3.20

RUN apk add --no-cache \
  bash \
  dcron \
  git \
  jq \
  openssh-client \
  rsync \
  tzdata \
  util-linux

COPY scripts/backup.sh /usr/local/bin/livesync-git-backup
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint

RUN chmod +x /usr/local/bin/livesync-git-backup /usr/local/bin/entrypoint \
  && touch /var/log/cron.log

ENV CRON_SCHEDULE="0 */6 * * *" \
  TARGETS_FILE="/config/targets.json" \
  GIT_USERNAME="x-access-token" \
  GIT_AUTHOR_NAME="LiveSync Backup Bot" \
  GIT_AUTHOR_EMAIL="livesync-backup@noreply.local" \
  DRY_RUN="false"

ENTRYPOINT ["/usr/local/bin/entrypoint"]
