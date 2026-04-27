# GitLab Backup Restore

This repository starts a local GitLab 17.8.1 container, restores the bundled backup tarball into it on first boot, and leaves the instance running so you can browse groups/projects and export what you need.

## What is included

- `docker-compose.yml`: GitLab CE with persistent volumes and a first-run restore hook.
- `bootstrap/bootstrap-and-restore.sh`: waits for GitLab to come up, restores the backup once, then restarts services.
- `1739446275_2025_02_13_17.8.1_gitlab_before_cleaning.tar`: the GitLab backup archive to import.

## Requirements

- Docker Desktop or Docker Engine with Compose support
- At least 8 GB of RAM available to Docker
- Enough free disk for the extracted GitLab data in `gitlab-data/`

## Start GitLab and import the backup

```bash
docker compose up -d
docker compose logs -f gitlab
```

Open `http://localhost:8080` after the logs show the restore has completed and GitLab is healthy again.

The first startup can take a while because GitLab has to initialize, copy the tarball into the data volume, restore the backup, and restart.

## Important behavior

- The restore runs only once per data volume.
- A marker file is written to `gitlab-data/.restore-complete` after a successful import.
- Subsequent `docker compose up -d` runs just start the restored instance.

If you need to rerun the restore from scratch:

```bash
docker compose down
rm -rf gitlab-config gitlab-logs gitlab-data
docker compose up -d
```

## Login and access

The restored backup brings back the GitLab database, users, groups, and projects from the source system.

If you already know the original credentials, use them. If you do not know the `root` password, reset it inside the container:

```bash
docker compose exec gitlab gitlab-rake "gitlab:password:reset[root]"
```

SSH access is exposed on `localhost:2224` if you need it. The web UI is on `localhost:8080`.

## Export projects

You can export all projects without logging in to the web UI:

```bash
scripts/export-all-projects.sh
```

The script creates a short-lived local admin API token inside the restored container, starts a GitLab project export for every project, waits for completion, downloads the archives, and revokes the token. Archives are written to `project-exports/` by default.

To choose a different output directory:

```bash
scripts/export-all-projects.sh /path/to/output-directory
```

If GitLab's project export jobs hang or fail on restored data, export the Git repositories directly as portable bundles instead:

```bash
scripts/export-all-repositories.sh
```

Repository bundles are written to `project-repository-bundles/` by default. Restore one with:

```bash
git clone project-repository-bundles/group__project.bundle project
```

For a manual UI export after logging in:

1. Open the project you want to extract.
2. Go to `Settings` -> `General` -> `Advanced`.
3. Use the export action in the UI.

For direct repository access, you can also clone projects from the restored instance over HTTP or SSH and archive them outside GitLab.

## Useful commands

```bash
docker compose ps
docker compose logs -f gitlab
docker compose exec gitlab gitlab-rake gitlab:check SANITIZE=true
docker compose down
```

## Notes

- The compose file is pinned to `gitlab/gitlab-ce:17.8.1-ce.0` to match the version embedded in the backup filename.
- The backup tarball itself is mounted read-only from the repository root and copied into GitLab's internal backup directory before restore.
