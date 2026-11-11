# Polycore runner: GCP preset

Deploy a customer-hosted [Polycore](https://polycore.ai) runner on Google Cloud.
Terraform owns the infrastructure; the GitHub Action owns image releases.

The runtime uses a size-one managed instance group (MIG) on Container-Optimized
OS. It does not use the deprecated Compute Engine container startup agent.

## Flow

1. Terraform creates Artifact Registry, IAM, Secret Manager bindings, the
   health check, instance template, and MIG.
2. CI builds and pushes `runner:<version>`, then moves `runner:live` to that
   digest.
3. CI performs a rolling replacement with one surge VM and zero unavailable
   VMs. The old VM remains until the replacement is healthy.

The instance template always pulls `runner:live`. Rollback moves `live` to a
previous version digest and repeats the rolling replacement.

## Terraform

```hcl
module "polycore_runner" {
  source = "git::https://github.com/polycore/runner-gcp.git//terraform?ref=v0.2.0"

  project_id   = "acme-prod"
  region       = "europe-west1"
  zone         = "europe-west1-b"
  image_name   = "runner"
  runner_id    = "rnr_..."
  project_slug = "acme-prod"

  enable_firestore     = true
  enable_firebase_auth = false

  extra_secrets = {
    MY_API_KEY = "my-api-key"
  }
}
```

`runner_name` defaults to `polycore-runner`. The module also supports custom
secret IDs, plain environment variables, machine type, and network.

Apply Terraform, then add the enrollment secret versions:

```sh
printf '%s' '<joinToken>' | gcloud secrets versions add POLYCORE_JOIN_TOKEN \
  --data-file=- --project=acme-prod
printf '%s' '<signingSecret>' | gcloud secrets versions add POLYCORE_SIGNING_SECRET \
  --data-file=- --project=acme-prod
```

The first VM waits for secret versions and `runner:live` if they are not yet
available.

## GitHub Action

Authenticate as the module's `deploy_service_account_email`, then deploy:

```yaml
- uses: actions/checkout@v4
- uses: google-github-actions/auth@v2
  with:
    credentials_json: ${{ secrets.POLYCORE_DEPLOY_SA_KEY }}
- uses: google-github-actions/setup-gcloud@v2
- uses: polycore/runner-gcp/.github/actions/deploy-runner-gcp@v0.2.0
  with:
    project: acme-prod
    zone: europe-west1-b
    image: europe-west1-docker.pkg.dev/acme-prod/polycore/runner
    version: 1.4.2
    integration_dir: polycore-runner
```

The image owns its filesystem layout and must pass its `polycore.json` path to
`polycore-runner connect --config`. It must use a runner SDK version whose
`GET /health` returns `200` only while the runner has an active control-plane
session. Terraform restricts the
health endpoint to Google Cloud health probes. Failed application health checks
do not recreate the VM because a control-plane outage cannot be repaired from
the customer project.

Pin the Terraform module and Action to the same release tag.

## Existing standalone VMs

Deployments created by v0.1 can use the `deploy-runner-gcp-vm` Action to keep
their standalone VM and existing Terraform state. Change the Action path and
pin the release containing the fix; keep the existing `with` inputs:

```yaml
- uses: polycore/runner-gcp/.github/actions/deploy-runner-gcp-vm@v0.2.1
  with:
    mode: rollout
    project: acme-prod
    image: europe-west1-docker.pkg.dev/acme-prod/polycore/runner:COMMIT_SHA
    runner_id: ${{ vars.POLYCORE_RUNNER_ID }}
    project_slug: acme
    integration_dir: polycore-runner
```

Keep the existing v0.1 Terraform module pin for this path. Updating it to v0.2
starts the MIG migration described below. No runner SDK upgrade is required
for the standalone Action.

The VM prunes unused Docker images before pulling and after successful startup.
Images referenced by containers are preserved, and a failed pull leaves the
existing container in place. The replacement must run on the pulled image for
ten seconds without restarting before startup succeeds.

The Action waits for a startup result tied to a unique deployment ID. A startup
failure or timeout fails the deploy; an old success message cannot pass it.
`startup_timeout_seconds` defaults to 600 seconds. This checks container startup,
not the control-plane connection.

## Upgrading from v0.1

Keep the existing Terraform state and review the upgrade plan. The v0.1 Action
created a standalone VM that is outside the v0.2 module. Apply v0.2, stop that
VM before the first v0.2 rollout so only one process uses the runner ID, then
delete it after the MIG is healthy.

## Development

```sh
bash tests/action.test.sh
bash tests/vm-startup.test.sh
python3 -m unittest discover -s tests -v
bash tests/vm-action.test.sh
terraform -chdir=terraform fmt -check
terraform -chdir=terraform init -backend=false -input=false
terraform -chdir=terraform validate
```

Shell tests require Bash 4.4 or later. Cloud and Docker commands are mocked.
Release tags must point to a commit merged into `main`, with CI passing.

## License

Apache-2.0.
