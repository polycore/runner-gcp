#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin"

cat > "${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${!#}"
case "${url}" in
  */attributes/host-project) printf 'acme-prod' ;;
  */attributes/runner-image) printf 'europe-west1-docker.pkg.dev/acme-prod/polycore/runner:live' ;;
  */attributes/control-plane-ws) printf 'wss://cp.example.test/runner' ;;
  */attributes/runner-id) printf 'rnr_test' ;;
  */attributes/polycore-project-slug) printf 'acme-prod' ;;
  */attributes/google-cloud-project) printf 'acme-prod' ;;
  */attributes/container-name) printf 'polycore-runner' ;;
  */attributes/health-check-port) printf '8080' ;;
  */attributes/secret-join-token) printf 'join-secret' ;;
  */attributes/secret-signing-secret) printf 'signing-secret' ;;
  */attributes/extra-secrets)
    printf '%s %s\n' "$(printf 'api-secret' | base64)" "$(printf 'API_KEY' | base64)"
    ;;
  */attributes/extra-env)
    printf '%s %s\n' "$(printf 'PLAIN_VALUE' | base64)" "$(printf 'hello world' | base64)"
    ;;
  */service-accounts/default/token)
    printf '{"access_token":"metadata-token"}'
    ;;
  */secrets/join-secret/versions/latest:access)
    printf '{"payload":{"data":"%s"}}' "$(printf 'join-token' | base64)"
    ;;
  */secrets/signing-secret/versions/latest:access)
    printf '{"payload":{"data":"%s"}}' "$(printf 'signing-value' | base64)"
    ;;
  */secrets/api-secret/versions/latest:access)
    printf '{"payload":{"data":"%s"}}' "$(printf 'api-value' | base64)"
    ;;
  *)
    echo "unexpected curl URL: ${url}" >&2
    exit 1
    ;;
esac
EOF

cat > "${TMP}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker' >> "${COMMAND_LOG}"
printf ' %q' "$@" >> "${COMMAND_LOG}"
printf '\n' >> "${COMMAND_LOG}"
EOF

cat > "${TMP}/bin/docker-credential-gcr" <<'EOF'
#!/usr/bin/env bash
printf 'docker-credential-gcr' >> "${COMMAND_LOG}"
printf ' %q' "$@" >> "${COMMAND_LOG}"
printf '\n' >> "${COMMAND_LOG}"
EOF

cat > "${TMP}/bin/iptables" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" -C "* ]]; then
  exit 1
fi
printf 'iptables' >> "${COMMAND_LOG}"
printf ' %q' "$@" >> "${COMMAND_LOG}"
printf '\n' >> "${COMMAND_LOG}"
EOF

chmod +x "${TMP}/bin/"*
export COMMAND_LOG="${TMP}/commands.log"
export PATH="${TMP}/bin:${PATH}"
export POLYCORE_STARTUP_LOG="${TMP}/startup.log"
export POLYCORE_STATE_DIR="${TMP}/state"

bash "${ROOT}/terraform/vm-startup.sh"

grep -Fq 'docker pull europe-west1-docker.pkg.dev/acme-prod/polycore/runner:live' "${COMMAND_LOG}"
grep -Fq 'docker run -d --name polycore-runner --restart=always --network=host' "${COMMAND_LOG}"
grep -Fq 'PORT=8080' "${COMMAND_LOG}"
grep -Fq 'POLYCORE_JOIN_TOKEN=join-token' "${COMMAND_LOG}"
grep -Fq 'POLYCORE_SIGNING_SECRET=signing-value' "${COMMAND_LOG}"
if grep -Fq 'POLYCORE_RUNNER_CONFIG' "${COMMAND_LOG}"; then
  exit 1
fi
grep -Fq 'API_KEY=api-value' "${COMMAND_LOG}"
grep -Fq 'PLAIN_VALUE=hello\ world' "${COMMAND_LOG}"
grep -Fq 'iptables -I INPUT -p tcp -s 130.211.0.0/22 --dport 8080 -j ACCEPT' "${COMMAND_LOG}"
grep -Fq 'CMD ["node_modules/.bin/polycore-runner", "connect", "--config", "/app/integration/polycore.json"]' \
  "${ROOT}/Dockerfile.example"

echo "vm-startup.sh test passed"
