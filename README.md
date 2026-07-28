# Polycore runner - GCP preset

Public install path for a customer-hosted [Polycore](https://polycore.ai) runner
on Google Cloud. **This repo is the only thing customers need from GitHub** for
GCP deploy. You never need access to Polycore's private application monorepo.

Contains:

- **Terraform module** (`terraform/`) - Artifact Registry, deploy SA, VM SA IAM
  (ADC), enrollment secret shells
- **GitHub Action** (`.github/actions/deploy-runner-gcp`) - build/push image,
  provision / rollout / teardown the GCE VM
- **Dockerfile.example** - reference customer image layout

Your integration repo stays thin: `polycore.json`, `actions/`, `context/`,
`Dockerfile`, pinned `@polycore/runner` on npm.

## Runtime contract

Container env (what `@polycore/runner` reads):

| Env | Purpose |
| --- | --- |
| `POLYCORE_RUNNER_CONFIG` | Path to baked `polycore.json` |
| `POLYCORE_CONTROL_PLANE_URL` | `wss://cp.polycore.ai/runner` |
| `POLYCORE_RUNNER_ID` | `rnr_…` from enroll |
| `POLYCORE_JOIN_TOKEN` | Enrollment join token |
| `POLYCORE_SIGNING_SECRET` | Enrollment signing secret |
| `POLYCORE_PROJECT_SLUG` | Polycore project this runner serves |
| `GOOGLE_CLOUD_PROJECT` | GCP project when Firestore queries are on |

Credentials for Google APIs: **Application Default Credentials** (VM service
account). No key files on the happy path.

Secret Manager **resource ids** default to `POLYCORE_JOIN_TOKEN` /
`POLYCORE_SIGNING_SECRET` (same strings as the container env names), but both
the Terraform module and the deploy Action accept overrides when a host project
already uses different secret ids. The startup script always maps whatever was
fetched onto the fixed container env names above.

## Terraform

```hcl
module "polycore_runner" {
  source = "git::https://github.com/polycore/runner-gcp.git//terraform?ref=v0.1.2"

  project_id     = "acme-prod"
  project_number = "123456789012"
  region         = "europe-west1"

  enable_firestore     = true
  enable_firebase_auth = false
  # extra_secret_ids = ["MY_API_KEY"]
  # Optional: override Secret Manager ids for the enrollment shells
  # join_token_secret_id     = "polycore-join-token"
  # signing_secret_secret_id = "polycore-signing-secret"
}
```

Pin `ref` to a release tag. No Terraform Registry account required for git
source. No company incorporation required.

## GitHub Action

```yaml
- uses: google-github-actions/auth@v2
  with:
    credentials_json: ${{ secrets.POLYCORE_DEPLOY_SA_KEY }}
- uses: google-github-actions/setup-gcloud@v2
- uses: polycore/runner-gcp/.github/actions/deploy-runner-gcp@v0.1.2
  with:
    mode: rollout          # or provision | teardown
    project: acme-prod
    image: europe-west1-docker.pkg.dev/acme-prod/polycore/runner:latest
    runner_id: ${{ vars.POLYCORE_RUNNER_ID }}
    project_slug: acme-prod
    integration_dir: polycore-integration
    # Optional: Secret Manager ids (defaults match the Terraform shells)
    # join_token_secret: polycore-join-token
    # signing_secret_secret: polycore-signing-secret
```

First boot: `mode: provision`. Later: `mode: rollout`.

## License

Apache-2.0 (install tooling only; the Polycore control plane and proprietary
product remain separate).
