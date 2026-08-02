# Polycore runner: GCP preset

Public deployment preset for a customer-hosted [Polycore](https://polycore.ai)
runner on Google Cloud.

- **Terraform owns the runtime:** Artifact Registry, service accounts and IAM,
  Secret Manager bindings, health checking, the Container-Optimized OS instance
  template, and the size-one managed instance group (MIG).
- **Deployment CI owns releases:** build and push an immutable version, move the
  `live` tag to that digest, and perform a health-gated rolling replacement.

The preset does not use the deprecated Compute Engine container startup agent
or `gce-container-declaration` metadata. COS already includes Docker; the
Terraform-managed startup script fetches secrets, pulls `IMAGE:live`, and starts
the runner.

## Deployment model

A release publishes two references to the same manifest:

```text
runner:1.4.2  -> sha256:abc...   immutable release
runner:live   -> sha256:abc...   mutable deployment pointer
```

The instance template always contains `runner:live`, so it does not change for
each application release. CI moves `live`, then asks the MIG to replace its VM
with `maxSurge=1`, `maxUnavailable=0`, and `SUBSTITUTE`. The new VM pulls the
new `live` digest and must establish an enrolled control-plane session before
the old VM is removed.

Rollback uses the same path: move `live` to a retained version digest and run
another rolling replacement.

## Health behavior

Terraform creates and attaches the health check. Its firewall permits port
`8080` only from Google Cloud's documented health-probe ranges. The runner's
`GET /health` returns `200` only while it has an active, enrolled control-plane
session.

Application health failures use `DO_NOTHING`: a control-plane outage cannot be
repaired by recreating customer VMs. Docker restarts an exited process, while
the MIG still repairs infrastructure-level VM failures. Health remains the gate
for rolling replacement.

## Terraform

```hcl
module "polycore_runner" {
  source = "git::https://github.com/polycore/runner-gcp.git//terraform?ref=v0.2.0"

  project_id   = "acme-prod"
  region       = "europe-west1"
  zone         = "europe-west1-b"
  runner_name  = "polycore-runner" # optional; this is the default
  image_name   = "runner"
  runner_id    = "rnr_..."
  project_slug = "acme-prod"

  enable_firestore     = true
  enable_firebase_auth = false

  # Optional Secret Manager id to container env mappings.
  extra_secrets = {
    MY_API_KEY = "my-api-key"
  }
  extra_env = {
    MY_PROJECT_ID = "proj_..."
  }
}
```

Apply Terraform before running deployment CI. On the first apply, the initial
VM can start before secret versions or `runner:live` exist; the startup script
waits for them, and Terraform does not block on initial application health.

Terraform creates empty enrollment secret shells. Add the values returned by
runner enrollment as Secret Manager versions before deploying:

```sh
printf '%s' '<joinToken>' | gcloud secrets versions add POLYCORE_JOIN_TOKEN \
  --data-file=- --project=acme-prod
printf '%s' '<signingSecret>' | gcloud secrets versions add POLYCORE_SIGNING_SECRET \
  --data-file=- --project=acme-prod
```

The module outputs `image_repository`, `managed_instance_group_name`, and
`deploy_service_account_email` for CI configuration.

## GitHub Action

The caller authenticates as the Terraform-created deploy service account before
using the Action:

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
    runner_name: polycore-runner
    integration_dir: polycore-runner
```

The Action does not provision infrastructure or write VM metadata. It only:

1. Builds and pushes `runner:1.4.2`.
2. Resolves its digest and moves `runner:live` to it.
3. Forces a rolling replacement of the Terraform-managed MIG.
4. Waits until the MIG is stable and healthy.

Pin the Terraform module and Action to the same release tag.

## Runtime contract

Terraform injects the following container environment without placing secret
values in instance metadata:

| Environment variable | Purpose |
| --- | --- |
| `PORT` | Restricted health endpoint port |
| `POLYCORE_RUNNER_CONFIG` | Path to the baked `polycore.json` |
| `POLYCORE_CONTROL_PLANE_URL` | Control-plane WebSocket URL |
| `POLYCORE_RUNNER_ID` | `rnr_...` from enrollment |
| `POLYCORE_JOIN_TOKEN` | Value fetched from Secret Manager |
| `POLYCORE_SIGNING_SECRET` | Value fetched from Secret Manager |
| `POLYCORE_PROJECT_SLUG` | Polycore project served by the runner |
| `GOOGLE_CLOUD_PROJECT` | GCP project used by ADC-backed capabilities |

The image must use a runner SDK version whose `/health` endpoint reflects its
live, enrolled control-plane session.

## License

Apache-2.0. The install tooling is public; the Polycore control plane and
proprietary product are separate.
