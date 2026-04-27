#!/usr/bin/env bash

set -euo pipefail

OUT_DIR="${1:-project-repository-bundles}"
SERVICE="${GITLAB_SERVICE:-gitlab}"
CONTAINER="${GITLAB_CONTAINER:-gitlab-restore}"
CONTAINER_OUT="/tmp/gitlab-repository-bundles-$(date +%Y%m%d%H%M%S)"

mkdir -p "${OUT_DIR}"

echo "Creating repository bundles inside ${CONTAINER}:${CONTAINER_OUT}"
set +e
docker compose exec -T \
  -e GITLAB_REPO_EXPORT_DIR="${CONTAINER_OUT}" \
  "${SERVICE}" bash <<'BASH'
set -euo pipefail

OUT_DIR="${GITLAB_REPO_EXPORT_DIR:?}"
REPO_ROOT="/var/opt/gitlab/git-data/repositories"
MANIFEST="${OUT_DIR}/repositories.tsv"
FAILURES="${OUT_DIR}/failures.txt"
EMPTY_REPOS="${OUT_DIR}/empty-repositories.txt"

mkdir -p "${OUT_DIR}"
rm -f "${MANIFEST}" "${FAILURES}" "${EMPTY_REPOS}"

gitlab-psql -d gitlabhq_production -At -F $'\t' -c "
WITH RECURSIVE ns AS (
  SELECT id, path::text AS full_path, parent_id
  FROM namespaces
  WHERE parent_id IS NULL
  UNION ALL
  SELECT n.id, (ns.full_path || '/' || n.path)::text AS full_path, n.parent_id
  FROM namespaces n
  JOIN ns ON n.parent_id = ns.id
)
SELECT p.id, ns.full_path || '/' || p.path AS full_path, pr.disk_path
FROM projects p
JOIN ns ON ns.id = p.namespace_id
JOIN project_repositories pr ON pr.project_id = p.id
WHERE pr.disk_path IS NOT NULL
ORDER BY p.id;
" > "${MANIFEST}"

total="$(wc -l < "${MANIFEST}" | tr -d ' ')"
index=0

while IFS=$'\t' read -r project_id full_path disk_path; do
  index=$((index + 1))
  safe_name="$(printf '%s' "${full_path}" | sed -E 's/[^0-9A-Za-z._-]+/__/g')"
  repo="${REPO_ROOT}/${disk_path}.git"
  target="${OUT_DIR}/${safe_name}.bundle"

  echo "[${index}/${total}] Bundling ${full_path}"

  if [[ ! -d "${repo}" ]]; then
    echo "${full_path}: missing repository at ${repo}" >> "${FAILURES}"
    echo "  FAILED: missing repository"
    continue
  fi

  if ! git --git-dir="${repo}" for-each-ref --count=1 --format='%(refname)' | grep -q .; then
    echo "${full_path}" >> "${EMPTY_REPOS}"
    echo "  skipped empty repository"
    continue
  fi

  if ! git --git-dir="${repo}" bundle create "${target}" --all; then
    rm -f "${target}"
    echo "${full_path}: git bundle failed" >> "${FAILURES}"
    echo "  FAILED: git bundle failed"
    continue
  fi

  wiki_repo="${REPO_ROOT}/${disk_path}.wiki.git"
  if [[ -d "${wiki_repo}" ]]; then
    if ! git --git-dir="${wiki_repo}" for-each-ref --count=1 --format='%(refname)' | grep -q .; then
      continue
    fi

    wiki_target="${OUT_DIR}/${safe_name}.wiki.bundle"
    if ! git --git-dir="${wiki_repo}" bundle create "${wiki_target}" --all; then
      rm -f "${wiki_target}"
      echo "${full_path}.wiki: git bundle failed" >> "${FAILURES}"
      echo "  FAILED: wiki bundle failed"
    fi
  fi
done < "${MANIFEST}"

if [[ -f "${FAILURES}" ]]; then
  echo "Some repositories failed to bundle; see ${FAILURES}" >&2
  exit 1
fi

echo "All repository bundles completed"
BASH
EXPORT_STATUS=$?
set -e

echo "Copying repository bundles to ${OUT_DIR}"
docker cp "${CONTAINER}:${CONTAINER_OUT}/." "${OUT_DIR}/"

if [[ "${EXPORT_STATUS}" -eq 0 ]]; then
  docker compose exec -T "${SERVICE}" rm -rf "${CONTAINER_OUT}" >/dev/null
  echo "Repository bundles are in ${OUT_DIR}"
else
  echo "Some repository bundles failed. Partial output was copied to ${OUT_DIR}; see failures.txt if present." >&2
  exit "${EXPORT_STATUS}"
fi
