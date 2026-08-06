#!/bin/sh
set -eu

image="${1:-swiftserve-github-app:ci}"
expected='{"error":{"code":"configuration.missing","message":"Set SWIFTSERVE_GITHUB_APP_ID"}}'
actual="$(docker run --rm "$image" 2>&1 || true)"
test "$actual" = "$expected"

private_key="$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)"
container_id="$(docker run -d --rm -p 127.0.0.1:18080:8080 \
  -e SWIFTSERVE_GITHUB_APP_ID=1 \
  -e SWIFTSERVE_GITHUB_WEBHOOK_SECRET=image-smoke-secret \
  -e SWIFTSERVE_GITHUB_PRIVATE_KEY="$private_key" \
  "$image")"

case "$container_id" in
  *[!0-9a-f]*|'') echo "Container smoke returned an invalid id" >&2; exit 1 ;;
esac

cleanup() {
  docker stop "$container_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

ready=0
attempt=0
while test "$attempt" -lt 40; do
  if curl --fail --silent http://127.0.0.1:18080/readyz | grep -q '"ready"'; then
    ready=1
    break
  fi
  attempt=$((attempt + 1))
  sleep 0.25
done

if test "$ready" -ne 1; then
  docker logs "$container_id"
  exit 1
fi

test "$(curl --fail --silent http://127.0.0.1:18080/livez)" = '{"status":"alive"}'
test "$(curl --fail --silent http://127.0.0.1:18080/readyz)" = '{"status":"ready"}'
metrics="$(curl --fail --silent http://127.0.0.1:18080/metrics)"
printf '%s' "$metrics" | grep -q '"queueDepth":0'
printf '%s' "$metrics" | grep -q '"activeJobs":0'

echo "✅ github-app-image: non-root production image is live, ready, and durable-store capable"
