# LiveSync Bridge Git Backup

Env-only Docker wrapper for [LiveSync Bridge](https://github.com/vrtmrz/livesync-bridge)
plus a cron-based Git snapshot worker.

It is meant to run next to a Self-hosted LiveSync/CouchDB stack:

```text
Obsidian clients
  -> obsidian-livesync plugin
  -> CouchDB
  -> LiveSync Bridge
  -> filesystem vault
  -> this worker
  -> GitHub
```

## Image

```text
ghcr.io/skyline-23/livesync-bridge-git-backup:latest
```

`latest` is published from the `main` branch. Use the same image for both
`MODE=bridge` and `MODE=backup`.

## Why this exists

Self-hosted LiveSync is a sync layer, not a Git backup layer. LiveSync Bridge can
materialize the remote vault into a filesystem folder. This worker periodically
copies that folder into one or more Git worktrees and pushes snapshots.

## Components

| Component | Runs where | Role |
| --- | --- | --- |
| `obsidian-livesync` | Obsidian desktop/mobile app | Syncs the local Obsidian vault with CouchDB. |
| CouchDB | Server / Dokploy | Stores the Self-hosted LiveSync remote database. |
| `MODE=bridge` | Server / Dokploy | Runs LiveSync Bridge and materializes CouchDB data into a normal filesystem vault folder. |
| `MODE=backup` | Server / Dokploy | Commits and pushes filesystem snapshots to Git. |

This image does not replace the Obsidian plugin. Users still install
`obsidian-livesync` in Obsidian and point it at the same CouchDB database.

## Bridge Mode

Use `MODE=bridge` to run the LiveSync Bridge wrapper. It configures CouchDB
through the CouchDB HTTP API, creates the LiveSync database if needed, generates
the upstream Bridge config from environment variables, and starts Bridge.

| Name | Default | Description |
| --- | --- | --- |
| `MODE` | `backup` | Set to `bridge`. |
| `COUCHDB_URL` | `http://couchdb:5984` | CouchDB URL from the bridge container. |
| `COUCHDB_USER` | required | CouchDB user. |
| `COUCHDB_PASSWORD` | required | CouchDB password. |
| `LIVESYNC_DATABASE` | required | Self-hosted LiveSync database name. |
| `LIVESYNC_PASSPHRASE` | empty | LiveSync E2EE passphrase. |
| `LIVESYNC_OBFUSCATE_PASSPHRASE` | `LIVESYNC_PASSPHRASE` | Path obfuscation passphrase. |
| `LIVESYNC_BASE_DIR` | empty | Optional remote vault subfolder to materialize. |
| `BRIDGE_STORAGE_PATH` | `/data/vault` | Filesystem output path. |
| `COUCHDB_CORS_ORIGINS` | Obsidian desktop/mobile defaults | CORS origins written to CouchDB. |

## Backup Mode

Use `MODE=backup` to run the Git snapshot worker. The simplest deployment only
needs `GIT_REMOTE_URL`; the target JSON is generated automatically.

For advanced setups, mount a JSON file at `/config/targets.json` or pass
`TARGETS_JSON`.

```json
{
  "targets": [
    {
      "name": "vault",
      "source": "/vault",
      "worktree": "/git/vault",
      "remote": "https://github.com/YOUR_ORG/YOUR_VAULT_REPO.git",
      "branch": "main",
      "commit_message": "backup(vault): Snapshot {{date}}",
      "exclude": ["node_modules/", ".obsidian/workspace.json"]
    }
  ]
}
```

Each target is processed in order. Most deployments only need one `vault`
target.

See [config/targets.example.json](config/targets.example.json).

## Backup Environment

| Name | Default | Description |
| --- | --- | --- |
| `MODE` | `backup` | Set to `backup`. |
| `CRON_SCHEDULE` | `0 */6 * * *` | Backup schedule in cron format. |
| `TARGETS_FILE` | `/config/targets.json` | Target configuration path. |
| `TARGETS_JSON` | empty | Inline target JSON. Used before `GIT_REMOTE_URL` mode. |
| `GIT_REMOTE_URL` | empty | HTTPS or SSH remote URL for the generated single vault target. |
| `GIT_BRANCH` | `main` | Branch for the generated target. |
| `GIT_SOURCE` | `/vault` | Source folder for the generated target. |
| `GIT_WORKTREE` | `/git/vault` | Worktree folder for the generated target. |
| `GIT_COMMIT_MESSAGE` | `backup(vault): Snapshot {{date}}` | Commit message for the generated target. |
| `GIT_EXCLUDES` | built-in Obsidian local-state ignores | Comma-separated rsync exclude patterns. |
| `GIT_TOKEN` | empty | PAT for HTTPS remotes. Recommended for Dokploy. |
| `GITHUB_TOKEN` | empty | Alternative token env name. Used when `GIT_TOKEN` is empty. |
| `GIT_USERNAME` | `x-access-token` | HTTPS username used with `GIT_TOKEN`. |
| `SSH_PRIVATE_KEY_BASE64` | empty | Base64-encoded SSH private key for SSH remotes. |
| `SSH_PRIVATE_KEY` | empty | Plain SSH private key for SSH remotes. |
| `GIT_AUTHOR_NAME` | `LiveSync Backup Bot` | Commit author name. |
| `GIT_AUTHOR_EMAIL` | `livesync-backup@noreply.local` | Commit author email. |
| `RUN_ON_START` | `true` | Run one backup immediately before cron starts. |
| `DRY_RUN` | `false` | Show pending changes without committing or pushing. |

## Dokploy / Compose

Use [compose.example.yml](compose.example.yml) as the starting point. It has no
config file mounts; all user-controlled values are environment variables.

Required values:

```env
COUCHDB_USER=admin
COUCHDB_PASSWORD=change-this-couchdb-password
LIVESYNC_DATABASE=knowledge_vault
LIVESYNC_PASSPHRASE=change-this-livesync-passphrase
GIT_REMOTE_URL=https://github.com/YOUR_ORG/YOUR_VAULT_REPO.git
GIT_TOKEN=github_pat_change_this
```

Important rules:

- Do not put `.git` inside the LiveSync Bridge storage folder.
- Keep the bridge output folder and Git worktrees separate.
- Use a PAT with repository write access, or deploy keys if you use SSH remotes.
- Exclude local Obsidian state such as workspace, graph, backlink, LiveSync
  plugin data, and `node_modules/`.

## Basic Vault Backup

The default setup backs up one materialized vault folder to one Git repository.
Point `source` at the folder produced by LiveSync Bridge, and point `remote` at
the Git repository that should receive snapshots.
