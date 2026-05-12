# LiveSync Bridge Git Backup

Cron-based Git snapshot worker for vault files produced by
[LiveSync Bridge](https://github.com/vrtmrz/livesync-bridge).

It is meant to run next to a Self-hosted LiveSync/CouchDB stack:

```text
Obsidian clients -> CouchDB -> LiveSync Bridge -> filesystem vault -> this worker -> GitHub
```

## Image

```text
ghcr.io/skyline-23/livesync-bridge-git-backup:latest
```

`latest` is published from the `main` branch.

## Why this exists

Self-hosted LiveSync is a sync layer, not a Git backup layer. LiveSync Bridge can
materialize the remote vault into a filesystem folder. This worker periodically
copies that folder into one or more Git worktrees and pushes snapshots.

## Target Config

Mount a JSON file at `/config/targets.json`.

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

## Environment

| Name | Default | Description |
| --- | --- | --- |
| `CRON_SCHEDULE` | `0 */6 * * *` | Backup schedule in cron format. |
| `TARGETS_FILE` | `/config/targets.json` | Target configuration path. |
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

Use [compose.example.yml](compose.example.yml) as the starting point.

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
