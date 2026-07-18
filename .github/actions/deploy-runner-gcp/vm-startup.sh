#!/usr/bin/env bash
#
# GCE startup script for a Polycore runner VM (owned by the GCP preset).
# Fetches enrollment (+ optional extra) secrets, pulls the image, and launches
# the container with Application Default Credentials (the VM service account).
# Metadata is set by the deploy-runner-gcp GitHub Action.

set -euo pipefail
exec > >(tee -a /var/log/polycore-runner-startup.log) 2>&1
echo "=== polycore runner startup $(date -u +%FT%TZ) ==="

md() { curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/$1"; }
attr() { md "attributes/$1"; }

TOKEN="$(md "service-accounts/default/token" | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")"

HOST_PROJECT="$(attr host-project)"
RUNNER_IMAGE="$(attr runner-image)"
CONTROL_PLANE_WS="$(attr control-plane-ws)"
RUNNER_ID="$(attr runner-id)"
RUNNER_CONFIG_PATH="$(attr runner-config-path)"
POLYCORE_PROJECT_SLUG="$(attr polycore-project-slug)"
GOOGLE_CLOUD_PROJECT="$(attr google-cloud-project)"
CONTAINER_NAME="$(attr container-name)"
SECRET_JOIN_TOKEN="$(attr secret-join-token)"
SECRET_SIGNING_SECRET="$(attr secret-signing-secret)"
# Optional: JSON array of {"secret":"ID","env":"ENV_VAR"} objects.
EXTRA_SECRETS_JSON="$(attr extra-secrets || true)"
# Optional: JSON object of plain env bindings {"KEY":"value",...}.
EXTRA_ENV_JSON="$(attr extra-env || true)"

fetch_secret() {
  curl -s -H "Authorization: Bearer ${TOKEN}" \
    "https://secretmanager.googleapis.com/v1/projects/${HOST_PROJECT}/secrets/$1/versions/latest:access" \
    | python3 -c "import sys,json,base64;print(base64.b64decode(json.load(sys.stdin)['payload']['data']).decode('utf-8'),end='')"
}

echo "--- ensuring docker is installed ---"
if ! command -v docker >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y docker.io curl python3
fi
systemctl enable --now docker

echo "--- reading enrollment secrets ---"
JOIN_TOKEN="$(fetch_secret "${SECRET_JOIN_TOKEN}")"
SIGNING_SECRET="$(fetch_secret "${SECRET_SIGNING_SECRET}")"

DOCKER_ENV=(
  -e "POLYCORE_RUNNER_CONFIG=${RUNNER_CONFIG_PATH}"
  -e "POLYCORE_CONTROL_PLANE_URL=${CONTROL_PLANE_WS}"
  -e "POLYCORE_RUNNER_ID=${RUNNER_ID}"
  -e "POLYCORE_JOIN_TOKEN=${JOIN_TOKEN}"
  -e "POLYCORE_SIGNING_SECRET=${SIGNING_SECRET}"
  -e "POLYCORE_PROJECT_SLUG=${POLYCORE_PROJECT_SLUG}"
  -e "GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT}"
)

if [ -n "${EXTRA_SECRETS_JSON}" ] && [ "${EXTRA_SECRETS_JSON}" != "None" ]; then
  while IFS=$'\t' read -r secret_id env_name; do
    [ -z "${secret_id}" ] && continue
    value="$(fetch_secret "${secret_id}" 2>/dev/null || true)"
    if [ -n "${value}" ]; then
      DOCKER_ENV+=(-e "${env_name}=${value}")
      echo "--- loaded secret ${secret_id} → ${env_name} ---"
    else
      echo "--- secret ${secret_id} not accessible; skipping ${env_name} ---"
    fi
  done < <(python3 -c "
import json,sys
raw=sys.argv[1]
if not raw: raise SystemExit
for item in json.loads(raw):
    print(item['secret']+'\t'+item['env'])
" "${EXTRA_SECRETS_JSON}")
fi

if [ -n "${EXTRA_ENV_JSON}" ] && [ "${EXTRA_ENV_JSON}" != "None" ]; then
  while IFS=$'\t' read -r key value; do
    [ -z "${key}" ] && continue
    DOCKER_ENV+=(-e "${key}=${value}")
  done < <(python3 -c "
import json,sys
raw=sys.argv[1]
if not raw: raise SystemExit
for k,v in json.loads(raw).items():
    print(k+'\t'+str(v))
" "${EXTRA_ENV_JSON}")
fi

echo "--- docker login to Artifact Registry ---"
REGISTRY_HOST="${RUNNER_IMAGE%%/*}"
echo "${TOKEN}" | docker login -u oauth2accesstoken --password-stdin "https://${REGISTRY_HOST}"

echo "--- pulling ${RUNNER_IMAGE} ---"
docker pull "${RUNNER_IMAGE}"

echo "--- (re)starting runner container (${CONTAINER_NAME}) ---"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run -d --name "${CONTAINER_NAME}" --restart=always \
  "${DOCKER_ENV[@]}" \
  "${RUNNER_IMAGE}"

echo "=== startup complete; runner container launched ==="
