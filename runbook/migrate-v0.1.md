# Migrate a standalone runner to a MIG

Use a release tagged from merged `main` with passing CI. Do not apply a module
or deploy an image from an unmerged branch. Migrate one environment at a time,
starting with development.

## Prepare the customer changes

- Keep the existing Terraform module address and state. Update the module and
  Action pins to `v0.3.0` or a later reviewed release.
- Keep `runner_name = "polycore-runner"` when retaining the v0.1
  `polycore-runner-deploy` account. A different name replaces that account and
  invalidates its existing GitHub credential.
- Move the runner ID, project slug, extra secrets, and plain environment values
  from the workflow to Terraform. Keep the existing enrollment secrets.
- Pass the config path in the image command, such as
  `polycore-runner connect --config /app/integration/polycore.json`. Use runner
  SDK 2.10.1 or later, whose `/health` endpoint checks its control-plane session.
- Grant the new dedicated VM account the data access the runner needs. The
  default Compute Engine account's permissions are not inherited. The module
  can grant Firestore/Auth access; customer configuration owns other grants,
  including Storage access and signing permissions when used.
- Expose the module's `target_size` as a root variable, named
  `polycore_runner_size` in the commands below, with default `1`.
- Offer `mode: publish` in the deploy workflow's manual inputs. That mode
  publishes an image without starting or replacing a VM.

## Stage without starting a second runner

Disable only the runner workflow before merging the customer workflow changes:

```sh
gh workflow disable deploy-polycore-runner.yml --repo "$CUSTOMER_REPO"
```

After the customer PR is merged and the preset release exists, check out the
merged customer commit. In the environment's existing Terraform root:

```sh
# Use the scoped arguments from the customer runbook when sharing a backend stack.
MIG_TERRAFORM_ARGS=()
terraform init -upgrade
terraform plan "${MIG_TERRAFORM_ARGS[@]}" -var='polycore_runner_size=0'
terraform apply "${MIG_TERRAFORM_ARGS[@]}" -var='polycore_runner_size=0'
```

Review the plan before applying. Registry, enrollment secrets, and the existing
deploy account must not be replaced. Unrelated backend resources must not
change. The old VM is not managed by this module and must remain running.

The migration moves API resources to their new addresses. It removes legacy
default-account IAM bindings from Terraform ownership with `destroy = false`:
the bindings remain in GCP because backend workloads may share that identity.
Keep them through cutover and audit their ownership separately afterward.

## Publish and cut over

Re-enable the runner workflow and publish from merged `main`:

```sh
gh workflow enable deploy-polycore-runner.yml --repo "$CUSTOMER_REPO"
gh workflow run deploy-polycore-runner.yml --repo "$CUSTOMER_REPO" \
  --ref main -f env="$RUNNER_ENV" -f mode=publish
```

Wait for that run to succeed. Confirm the MIG has target size zero, then stop
the old VM and enable one managed instance:

```sh
gcloud compute instance-groups managed describe polycore-runner \
  --project="$RUNNER_PROJECT" --zone="$RUNNER_ZONE" --format='value(targetSize)'
gcloud compute instances stop "$OLD_RUNNER_VM" \
  --project="$RUNNER_PROJECT" --zone="$RUNNER_ZONE"
terraform plan "${MIG_TERRAFORM_ARGS[@]}" -var='polycore_runner_size=1'
terraform apply "${MIG_TERRAFORM_ARGS[@]}" -var='polycore_runner_size=1'
gcloud compute instance-groups managed wait-until polycore-runner \
  --project="$RUNNER_PROJECT" --zone="$RUNNER_ZONE" --stable --timeout=900
gcloud compute instance-groups managed list-instances polycore-runner \
  --project="$RUNNER_PROJECT" --zone="$RUNNER_ZONE" \
  --format='table(instance,instanceHealth[0].detailedHealthState)'
```

Require one `HEALTHY` instance and confirm the existing runner is connected in
Polycore. Exercise representative read operations, including Storage when
configured. Keep the old VM stopped for rollback.

Dispatch `mode=deploy` from `main` and require success. This verifies a fresh
replacement and the deployment gate before proceeding to the next environment.

## Roll back a failed cutover

Stop the MIG before restarting the standalone VM, so the two do not compete for
the same runner ID:

```sh
terraform apply "${MIG_TERRAFORM_ARGS[@]}" -var='polycore_runner_size=0'
gcloud compute instances start "$OLD_RUNNER_VM" \
  --project="$RUNNER_PROJECT" --zone="$RUNNER_ZONE"
```

Confirm the old runner reconnects. Keep the workflow in publish-only use while
investigating; normal deploy mode rejects a zero-sized MIG. Do not destroy the
Terraform stack or rotate enrollment secrets as part of rollback.
