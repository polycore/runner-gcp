#!/usr/bin/env bash

set -euo pipefail
STARTUP_LOG="${POLYCORE_STARTUP_LOG:-/var/log/polycore-runner-startup.log}"
exec > >(tee -a "${STARTUP_LOG}") 2>&1
echo "=== polycore runner startup $(date -u +%FT%TZ) ==="

md() {
  curl -fsS -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/$1"
}
attr() { md "attributes/$1"; }

HOST_PROJECT="$(attr host-project)"
RUNNER_IMAGE="$(attr runner-image)"
CONTROL_PLANE_WS="$(attr control-plane-ws)"
RUNNER_ID="$(attr runner-id)"
RUNNER_CONFIG_PATH="$(attr runner-config-path)"
POLYCORE_PROJECT_SLUG="$(attr polycore-project-slug)"
GOOGLE_CLOUD_PROJECT="$(attr google-cloud-project)"
CONTAINER_NAME="$(attr container-name)"
HEALTH_CHECK_PORT="$(attr health-check-port)"
SECRET_JOIN_TOKEN="$(attr secret-join-token)"
SECRET_SIGNING_SECRET="$(attr secret-signing-secret)"
EXTRA_SECRETS="$(attr extra-secrets 2>/dev/null || true)"
EXTRA_ENV="$(attr extra-env 2>/dev/null || true)"

TOKEN_JSON="$(md service-accounts/default/token)"
TOKEN="$(printf '%s' "${TOKEN_JSON}" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [ -z "${TOKEN}" ]; then
  echo "Failed to obtain a VM service-account token." >&2
  exit 1
fi

fetch_secret() {
  local response encoded
  response="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" \
    "https://secretmanager.googleapis.com/v1/projects/${HOST_PROJECT}/secrets/$1/versions/latest:access")"
  encoded="$(printf '%s' "${response}" | sed -n 's/.*"data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ -z "${encoded}" ]; then
    echo "Secret $1 returned no payload." >&2
    return 1
  fi
  printf '%s' "${encoded}" | base64 -d
}

wait_for_secret() {
  local secret_id="$1" value attempt
  for attempt in $(seq 1 60); do
    if value="$(fetch_secret "${secret_id}" 2>/dev/null)" && [[ -n "${value}" ]]; then
      printf '%s' "${value}"
      return
    fi
    echo "Secret ${secret_id} is not available yet; retrying in 10 seconds (${attempt}/60)." >&2
    sleep 10
  done
  echo "Secret ${secret_id} was not available after 60 attempts." >&2
  return 1
}

decode() { printf '%s' "$1" | base64 -d; }

echo "--- configuring Artifact Registry authentication ---"
export HOME=/root
REGISTRY_HOST="${RUNNER_IMAGE%%/*}"
docker-credential-gcr configure-docker --registries "${REGISTRY_HOST}"

echo "--- allowing Google Cloud health probes on ${HEALTH_CHECK_PORT} ---"
for source_range in 130.211.0.0/22 35.191.0.0/16; do
  iptables -C INPUT -p tcp -s "${source_range}" --dport "${HEALTH_CHECK_PORT}" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp -s "${source_range}" --dport "${HEALTH_CHECK_PORT}" -j ACCEPT
done

echo "--- reading runner secrets ---"
JOIN_TOKEN="$(wait_for_secret "${SECRET_JOIN_TOKEN}")"
SIGNING_SECRET="$(wait_for_secret "${SECRET_SIGNING_SECRET}")"

DOCKER_ENV=(
  -e "PORT=${HEALTH_CHECK_PORT}"
  -e "POLYCORE_RUNNER_CONFIG=${RUNNER_CONFIG_PATH}"
  -e "POLYCORE_CONTROL_PLANE_URL=${CONTROL_PLANE_WS}"
  -e "POLYCORE_RUNNER_ID=${RUNNER_ID}"
  -e "POLYCORE_JOIN_TOKEN=${JOIN_TOKEN}"
  -e "POLYCORE_SIGNING_SECRET=${SIGNING_SECRET}"
  -e "POLYCORE_PROJECT_SLUG=${POLYCORE_PROJECT_SLUG}"
  -e "GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT}"
)

while read -r encoded_secret encoded_env; do
  [ -z "${encoded_secret}" ] && continue
  secret_id="$(decode "${encoded_secret}")"
  env_name="$(decode "${encoded_env}")"
  value="$(wait_for_secret "${secret_id}")"
  DOCKER_ENV+=(-e "${env_name}=${value}")
  echo "--- loaded secret ${secret_id} -> ${env_name} ---"
done <<< "${EXTRA_SECRETS}"

while read -r encoded_key encoded_value; do
  [ -z "${encoded_key}" ] && continue
  key="$(decode "${encoded_key}")"
  value="$(decode "${encoded_value}")"
  DOCKER_ENV+=(-e "${key}=${value}")
done <<< "${EXTRA_ENV}"

echo "--- pulling ${RUNNER_IMAGE} ---"
for attempt in $(seq 1 60); do
  if docker pull "${RUNNER_IMAGE}"; then
    break
  fi
  if [[ "${attempt}" == "60" ]]; then
    echo "Failed to pull ${RUNNER_IMAGE} after ${attempt} attempts." >&2
    exit 1
  fi
  echo "Image is not available yet; retrying in 10 seconds (${attempt}/60)."
  sleep 10
done

echo "--- starting runner container (${CONTAINER_NAME}) ---"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER_NAME}" --restart=always --network=host \
  "${DOCKER_ENV[@]}" \
  "${RUNNER_IMAGE}"

echo "=== startup complete; waiting for the runner health endpoint ==="
