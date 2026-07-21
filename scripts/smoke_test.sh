#!/usr/bin/env bash
# Post-build smoke test: runs the freshly built image against a throwaway
# Postgres, both on a shared Docker network, and asserts /health returns 200.
# Everything is container-to-container by name - no reliance on the script's
# own localhost, which does not reach the remote Docker engine.
set -euo pipefail

IMAGE="${1:?usage: smoke_test.sh <image-ref>}"
NET="smoke-net"

cleanup() {
  docker rm -f smoke-app smoke-db >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 1. Private network the two containers share.
docker network create "${NET}" >/dev/null 2>&1 || true

# 2. Postgres, named "smoke-db", reachable by that name on the network.
docker run -d --rm --name smoke-db --network "${NET}" \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=widgets cimg/postgres:16.4 >/dev/null

# 3. The app, named "smoke-app", pointed at Postgres by its container name.
docker run -d --rm --name smoke-app --network "${NET}" \
  -e DATABASE_URL="postgresql://postgres:postgres@smoke-db:5432/widgets" \
  "${IMAGE}" >/dev/null

# 4. Health check FROM A CONTAINER on the same network, reaching the app
#    by its name. Never touches the script's own localhost.
echo "Waiting for app to come up..."
for i in $(seq 1 30); do
  if docker run --rm --network "${NET}" curlimages/curl:8.10.1 \
       -fsS "http://smoke-app:8000/health" >/dev/null 2>&1; then
    echo "Smoke test passed: /health returned 200."
    docker run --rm --network "${NET}" curlimages/curl:8.10.1 \
       -fsS "http://smoke-app:8000/health"
    echo
    exit 0
  fi
  sleep 2
done

echo "ERROR: app did not pass smoke test in time." >&2
docker logs smoke-app || true
exit 1
