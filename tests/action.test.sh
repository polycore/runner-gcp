#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

ruby -ryaml - "${ROOT}/.github/actions/deploy-runner-gcp/action.yml" "${TEST_DIR}" <<'RUBY'
action = YAML.safe_load(File.read(ARGV[0]), aliases: true)
steps = action.fetch("runs").fetch("steps")
verify = steps.find { |step| step["name"] == "Verify runner startup" }
raise "missing startup gate" unless verify
raise "teardown must not wait" unless verify.fetch("if") == "${{ inputs.mode != 'teardown' }}"
raise "wrong deployment id" unless verify.fetch("env").fetch("DEPLOYMENT_ID") == "${{ steps.meta.outputs.deployment_id }}"
%w[Provision\ runner\ VM Roll\ out\ runner\ VM].each do |name|
  raise "verification must run after #{name}" unless steps.index(verify) > steps.index { |step| step["name"] == name }
end
steps.each_with_index do |step, index|
  script = step.fetch("run").gsub(/\$\{\{.*?\}\}/, "test-value")
  file = File.join(ARGV[1], "step-#{index}.sh")
  File.write(file, script)
  raise "invalid shell in #{step.fetch('name')}" unless system("bash", "-n", file)
end
metadata = steps.find { |step| step["id"] == "meta" }.fetch("run")
File.write(File.join(ARGV[1], "metadata.sh"), metadata.gsub(/\$\{\{.*?\}\}/, "test-value"))
File.write(File.join(ARGV[1], "verify.sh"), verify.fetch("run"))
RUBY

export RUNNER_HOME="${TEST_DIR}/metadata"
export EXTRA_SECRETS='[]' EXTRA_ENV='{}'
export GITHUB_OUTPUT="${TEST_DIR}/output"
bash "${TEST_DIR}/metadata.sh"
FIRST_ID="$(sed -n 's/^deployment_id=//p' "${GITHUB_OUTPUT}")"
grep -Fq "deployment-id=${FIRST_ID}," "${GITHUB_OUTPUT}"
: > "${GITHUB_OUTPUT}"
bash "${TEST_DIR}/metadata.sh"
SECOND_ID="$(sed -n 's/^deployment_id=//p' "${GITHUB_OUTPUT}")"
[[ -n "${FIRST_ID}" && -n "${SECOND_ID}" && "${FIRST_ID}" != "${SECOND_ID}" ]]

mkdir -p "${TEST_DIR}/bin"
cat > "${TEST_DIR}/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
printf '{"contents":"%s"}' "${SERIAL_CONTENTS}"
EOF
chmod +x "${TEST_DIR}/bin/gcloud"
export PATH="${TEST_DIR}/bin:${PATH}"
export ACTION_PATH="${ROOT}/.github/actions/deploy-runner-gcp"
export PROJECT=acme-prod ZONE=europe-west1-b VM_NAME=polycore-runner
export DEPLOYMENT_ID="${SECOND_ID}" STARTUP_TIMEOUT_SECONDS=1
export SERIAL_CONTENTS='=== startup complete; deployment=old-deployment ==='
if bash "${TEST_DIR}/verify.sh"; then
  echo "error: stale startup output passed the deployment gate" >&2
  exit 1
fi

export SERIAL_CONTENTS="=== startup failed; deployment=${SECOND_ID}; exit=1 ==="
if bash "${TEST_DIR}/verify.sh"; then
  echo "error: failed startup passed the deployment gate" >&2
  exit 1
fi
export SERIAL_CONTENTS="=== startup complete; deployment=${SECOND_ID} ==="
bash "${TEST_DIR}/verify.sh"

echo "action.yml tests passed"
