#!/bin/bash

set -euo pipefail

BACKUP_ARCHIVE="${BACKUP_ARCHIVE:?BACKUP_ARCHIVE must be set}"
BACKUP_PATH="/restore-src/${BACKUP_ARCHIVE}"
BACKUP_BASENAME="${BACKUP_ARCHIVE%.tar}"
RESTORE_MARKER="/var/opt/gitlab/.restore-complete"
WRAPPER_PID=""

cleanup() {
  if [[ -n "${WRAPPER_PID}" ]] && kill -0 "${WRAPPER_PID}" >/dev/null 2>&1; then
    kill "${WRAPPER_PID}" >/dev/null 2>&1 || true
    wait "${WRAPPER_PID}" || true
  fi
}

trap cleanup EXIT

wait_for_gitlab() {
  local attempts=0
  local max_attempts=120

  until curl --fail --silent http://127.0.0.1/-/health >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if (( attempts >= max_attempts )); then
      echo "GitLab did not become healthy in time."
      exit 1
    fi
    sleep 10
  done
}

copy_backup_into_place() {
  mkdir -p /var/opt/gitlab/backups

  if [[ ! -f "${BACKUP_PATH}" ]]; then
    echo "Backup archive not found at ${BACKUP_PATH}"
    exit 1
  fi

  if [[ ! -f "/var/opt/gitlab/backups/${BACKUP_ARCHIVE}" ]]; then
    echo "Copying ${BACKUP_ARCHIVE} into /var/opt/gitlab/backups"
    cp "${BACKUP_PATH}" "/var/opt/gitlab/backups/${BACKUP_ARCHIVE}"
  fi
}

restore_backup_once() {
  if [[ -f "${RESTORE_MARKER}" ]]; then
    echo "Restore marker found. Skipping backup import."
    return
  fi

  copy_backup_into_place

  echo "Waiting for GitLab services to become healthy before restore"
  wait_for_gitlab

  echo "Stopping Puma and Sidekiq for restore"
  gitlab-ctl stop puma
  gitlab-ctl stop sidekiq

  echo "Restoring backup ${BACKUP_BASENAME}"
  gitlab-backup restore BACKUP="${BACKUP_BASENAME}" force=yes

  echo "Reconfiguring and restarting GitLab after restore"
  gitlab-ctl reconfigure
  gitlab-ctl restart

  touch "${RESTORE_MARKER}"
  echo "Restore completed"
}

echo "Starting GitLab omnibus wrapper"
/assets/wrapper &
WRAPPER_PID=$!

restore_backup_once

trap - EXIT
wait "${WRAPPER_PID}"
