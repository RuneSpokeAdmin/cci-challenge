#!/usr/bin/env bash
# Blocks until the Postgres sidecar accepts connections, or times out.
# CircleCI service containers start in parallel with the job, so the job must
# wait for readiness rather than assume it.
set -euo pipefail

HOST="${DB_HOST:-localhost}"
PORT="${DB_PORT:-5432}"
RETRIES="${DB_WAIT_RETRIES:-30}"

echo "Waiting for Postgres at ${HOST}:${PORT} (up to ${RETRIES}s)..."
for i in $(seq 1 "${RETRIES}"); do
  if pg_isready -h "${HOST}" -p "${PORT}" -q; then
    echo "Postgres is ready after ${i}s."
    exit 0
  fi
  sleep 1
done

echo "ERROR: Postgres did not become ready within ${RETRIES}s." >&2
exit 1
