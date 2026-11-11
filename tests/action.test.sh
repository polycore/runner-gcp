#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

ruby -ryaml - "${ROOT}/.github/actions/deploy-runner-gcp/action.yml" "${TMP}" <<'RUBY'
action = YAML.safe_load(File.read(ARGV[0]), aliases: true)
inputs = action.fetch("inputs")
%w[project image version integration_dir].each do |name|
  raise "#{name} must be required" unless inputs.fetch(name).fetch("required")
end
raise "unexpected default runner name" unless inputs.dig("runner_name", "default") == "polycore-runner"
raise "deploy must remain the default" unless inputs.dig("mode", "default") == "deploy"

steps = action.fetch("runs").fetch("steps")
steps.each_with_index do |step, index|
  script = step["run"]
  next unless script
  raise "#{step.fetch("name")} interpolates an expression in shell" if script.include?("${{")
  path = File.join(ARGV[1], "step-#{index}.sh")
  File.write(path, script)
  raise "invalid shell in #{step.fetch("name")}" unless system("bash", "-n", path)
end

{
  "Validate inputs" => "validate.sh",
  "Check immutable runner version" => "version.sh",
  "Roll runner MIG" => "roll.sh",
  "Validate deployment target" => "target.sh",
}.each do |name, file|
  step = steps.find { |candidate| candidate["name"] == name }
  raise "missing #{name}" unless step
  File.write(File.join(ARGV[1], file), step.fetch("run"))
end
%w[Validate\ deployment\ target Roll\ runner\ MIG].each do |name|
  step = steps.find { |candidate| candidate["name"] == name }
  raise "publish must skip #{name}" unless step.fetch("if") == "inputs.mode == 'deploy'"
end
RUBY

export MODE=deploy
IMAGE="europe-west1-docker.pkg.dev/acme-prod/polycore/runner" \
  VERSION="1.2.3" bash "${TMP}/validate.sh"
if IMAGE="runner:live" VERSION="1.2.3" bash "${TMP}/validate.sh" 2>/dev/null; then
  exit 1
fi
if IMAGE="runner" VERSION="live" bash "${TMP}/validate.sh" 2>/dev/null; then
  exit 1
fi
if MODE=invalid IMAGE=runner VERSION=1.2.3 bash "${TMP}/validate.sh" 2>/dev/null; then
  exit 1
fi
MODE=publish IMAGE=runner VERSION=1.2.3 bash "${TMP}/validate.sh"

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" >> "${COMMAND_LOG}"
printf '\n' >> "${COMMAND_LOG}"
case " $* " in
  *" artifacts docker tags list "*) printf '%s\n' "${MOCK_TAGS:-}" ;;
  *" rolling-action replace --help "*)
    if [[ "${MOCK_STABLE:-true}" == "true" ]]; then
      printf '%s\n' '--min-ready'
    fi
    ;;
  *"value(targetSize)"*) printf '%s\n' "${MOCK_TARGET_SIZE:-1}" ;;
  *"detailedHealthState"*) printf '%s\n' "${MOCK_HEALTH:-HEALTHY}" ;;
  *" managed list-instances "*)
    count="$(cat "${INSTANCE_READS}")"
    echo "$((count + 1))" > "${INSTANCE_READS}"
    if [[ "${count}" == 0 || "${MOCK_REPLACED:-true}" == false ]]; then
      echo 'projects/acme-prod/zones/europe-west1-b/instances/runner-old'
    else
      echo 'projects/acme-prod/zones/europe-west1-b/instances/runner-new'
    fi
    ;;
esac
EOF
chmod +x "${TMP}/bin/gcloud"
export COMMAND_LOG="${TMP}/commands.log"
export INSTANCE_READS="${TMP}/instance-reads"
echo 0 > "${INSTANCE_READS}"
export PATH="${TMP}/bin:${PATH}"

export IMAGE="europe-west1-docker.pkg.dev/acme-prod/polycore/runner"
export VERSION="1.2.3"
export GITHUB_OUTPUT="${TMP}/version-output"
MOCK_TAGS="1.2.3" bash "${TMP}/version.sh"
grep -Fxq 'exists=true' "${GITHUB_OUTPUT}"
: > "${GITHUB_OUTPUT}"
MOCK_TAGS="" bash "${TMP}/version.sh"
grep -Fxq 'exists=false' "${GITHUB_OUTPUT}"

MIG_NAME="polycore-runner" PROJECT="acme-prod" ZONE="europe-west1-b" \
  bash "${TMP}/roll.sh"
grep -Eq 'rolling-action replace polycore-runner .*--max-surge=1 .*--max-unavailable=0 .*--min-ready=30s' \
  "${COMMAND_LOG}"

: > "${COMMAND_LOG}"
echo 0 > "${INSTANCE_READS}"
MOCK_STABLE="false" MIG_NAME="polycore-runner" PROJECT="acme-prod" ZONE="europe-west1-b" \
  bash "${TMP}/roll.sh"
grep -Fxq 'components install beta --quiet ' "${COMMAND_LOG}"
grep -Eq 'beta compute instance-groups managed rolling-action replace polycore-runner .*--min-ready=30s' \
  "${COMMAND_LOG}"

export MIG_NAME=polycore-runner PROJECT=acme-prod ZONE=europe-west1-b
bash "${TMP}/target.sh"
if MOCK_TARGET_SIZE=0 bash "${TMP}/target.sh" 2>/dev/null; then
  echo "staged MIG must not deploy" >&2
  exit 1
fi
echo 0 > "${INSTANCE_READS}"
if MOCK_REPLACED=false bash "${TMP}/roll.sh" 2>/dev/null; then
  echo "old instance must not pass deployment" >&2
  exit 1
fi
echo 0 > "${INSTANCE_READS}"
if MOCK_HEALTH=UNHEALTHY bash "${TMP}/roll.sh" 2>/dev/null; then
  echo "unhealthy replacement must not pass deployment" >&2
  exit 1
fi

echo "action.yml test passed"
