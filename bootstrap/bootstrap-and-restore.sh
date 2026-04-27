#!/bin/bash

set -euo pipefail

BACKUP_ARCHIVE="${BACKUP_ARCHIVE:?BACKUP_ARCHIVE must be set}"
BACKUP_PATH="/restore-src/${BACKUP_ARCHIVE}"
RESTORE_MARKER="/var/opt/gitlab/.restore-complete"
WRAPPER_PID=""
RESTORE_ARCHIVE=""
RESTORE_BASENAME=""

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

  local backup_id
  backup_id="$(tar -xOf "${BACKUP_PATH}" backup_information.yml | awk -F': ' '/^:backup_id:/ { gsub(/\047/, "", $2); print $2; exit }')"
  if [[ -z "${backup_id}" ]]; then
    echo "Could not read backup_id from ${BACKUP_PATH}"
    exit 1
  fi

  RESTORE_ARCHIVE="${backup_id}_gitlab_backup.tar"
  RESTORE_BASENAME="${backup_id}"
  local restore_path="/var/opt/gitlab/backups/${RESTORE_ARCHIVE}"
  local legacy_path="/var/opt/gitlab/backups/${BACKUP_ARCHIVE}"

  if [[ ! -f "${restore_path}" ]]; then
    echo "Copying ${BACKUP_ARCHIVE} into /var/opt/gitlab/backups as ${RESTORE_ARCHIVE}"
    if [[ -f "${legacy_path}" ]]; then
      ln "${legacy_path}" "${restore_path}" 2>/dev/null || cp "${legacy_path}" "${restore_path}"
    else
      cp "${BACKUP_PATH}" "${restore_path}"
    fi
  fi

  chown git:git "${restore_path}"
  chmod 0600 "${restore_path}"
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

  echo "Restoring backup ${RESTORE_BASENAME}"
  gitlab-backup restore BACKUP="${RESTORE_BASENAME}" force=yes

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
