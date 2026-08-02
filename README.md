# Polycore runner: GCP preset

Public install path for a customer-hosted [Polycore](https://polycore.ai) runner
on Google Cloud. This repository contains:

- a Terraform module for Artifact Registry, IAM, Secret Manager, and the
  restricted runner health check
- a GitHub Action that builds the runner image and deploys it to a size-one
  managed instance group (MIG)
- a reference Dockerfile

The runtime uses Google's `cos-stable` Container-Optimized OS image. Docker is
already installed on COS, so no package installation happens during boot. The
startup script pulls an image pinned by digest, fetches secrets with the VM
service account, and starts the runner with host networking. It does not use the
deprecated Compute Engine container startup agent or
`gce-container-declaration` metadata.

## Deployment model

Each deploy builds and pushes the requested image tag, resolves its immutable
Artifact Registry digest, and creates a new immutable instance template. A
rollout uses `maxSurge=1`, `maxUnavailable=0`, and `SUBSTITUTE`, so the MIG
creates a replacement VM before removing the old VM. The Action waits for both
the target template and a stable, healthy MIG before succeeding.

The runner health endpoint is restricted by VPC firewall to Google Cloud's
health check ranges. It returns `200` only while the runner has an active,
enrolled control-plane session. This proves a replacement can load its
configuration, read its secrets, and establish the outbound WebSocket before it
replaces the old VM. Application health failures are configured as `DO_NOTHING`:
the control plane is an external dependency, so recreating VMs during its outage
would cause an autohealing loop. Docker restarts an exited runner process, and
the MIG still repairs infrastructure-level VM failures.

## Runtime contract

| Environment variable | Purpose |
| --- | --- |
| `PORT` | Health endpoint port, set by the deploy Action |
| `POLYCORE_RUNNER_CONFIG` | Path to the baked `polycore.json` |
| `POLYCORE_CONTROL_PLANE_URL` | Control-plane WebSocket URL |
| `POLYCORE_RUNNER_ID` | `rnr_...` from enrollment |
| `POLYCORE_JOIN_TOKEN` | Enrollment join token from Secret Manager |
| `POLYCORE_SIGNING_SECRET` | Signing secret from Secret Manager |
| `POLYCORE_PROJECT_SLUG` | Polycore project served by this runner |
| `GOOGLE_CLOUD_PROJECT` | GCP project used by ADC-backed capabilities |

The image must use a runner SDK version whose `/health` endpoint reflects its
live, enrolled control-plane session.

## Terraform

```hcl
module "polycore_runner" {
  source = "git::https://github.com/polycore/runner-gcp.git//terraform?ref=v0.2.0"

  project_id  = "acme-prod"
  region      = "europe-west1"
  runner_name = "polycore-runner"

  enable_firestore     = true
  enable_firebase_auth = false
}
```

Apply Terraform before the first deploy. It creates a dedicated
`polycore-runner-vm` runtime service account, plus the `${runner_name}-health`
health check on port `8080`, and permits that port only from Google's documented
health probe ranges. Keep Terraform's `runner_name`, `health_check_port`, and
`vm_service_account_id` identical to the Action's `vm_name`,
`health_check_port`, and `vm_service_account` when overriding the defaults.

## GitHub Action

```yaml
- uses: google-github-actions/auth@v2
  with:
    credentials_json: ${{ secrets.POLYCORE_DEPLOY_SA_KEY }}
- uses: google-github-actions/setup-gcloud@v2
- uses: polycore/runner-gcp/.github/actions/deploy-runner-gcp@v0.2.0
  with:
    mode: rollout # first deployment: provision
    project: acme-prod
    region: europe-west1
    zone: europe-west1-b
    image: europe-west1-docker.pkg.dev/acme-prod/polycore/runner:latest
    runner_id: ${{ vars.POLYCORE_RUNNER_ID }}
    project_slug: acme-prod
    integration_dir: polycore-runner
```

`mode: provision` creates the MIG. If a legacy standalone VM with the same name
exists, the Action keeps it until the MIG is healthy and then deletes it.
Subsequent deploys use `mode: rollout`. `mode: teardown` removes both the MIG
and any legacy standalone VM; Terraform continues to own shared infrastructure.

Pin both the Terraform module and Action to the same release tag.

## License

Apache-2.0. The install tooling is public; the Polycore control plane and
proprietary product are separate.
