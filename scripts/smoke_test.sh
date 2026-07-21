#!/usr/bin/env bash
# Post-build smoke test: runs the freshly built image as a container, wired to
# the same Postgres sidecar, and asserts the live /health endpoint returns 200.
# This proves the *image* works - not just the source - before we publish it.
set -euo pipefail

IMAGE="${1:?usage: smoke_test.sh <image-ref>}"
NETWORK_DB_URL="${DATABASE_URL:?DATABASE_URL must be set}"

echo "Starting container from ${IMAGE}..."
CONTAINER_ID=$(docker run -d --rm \
  --network host \
  -e DATABASE_URL="${NETWORK_DB_URL}" \
  "${IMAGE}")

cleanup() { docker stop "${CONTAINER_ID}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Waiting for app to come up..."
for i in $(seq 1 20); do
  if curl -fsS http://localhost:8000/health >/dev/null 2>&1; then
    echo "Smoke test passed: /health returned 200."
    curl -fsS http://localhost:8000/health
    echo
    exit 0
  fi
  sleep 1
done

echo "ERROR: app did not pass smoke test in time." >&2
docker logs "${CONTAINER_ID}" || true
exit 1
