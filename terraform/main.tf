# Opinionated GCP install for a Polycore runner.
#
# Public module: https://github.com/polycore/runner-gcp
#
#   module "polycore_runner" {
#     source = "git::https://github.com/polycore/runner-gcp.git//terraform?ref=v0.1.0"
#     project_id     = "acme-prod"
#     project_number = "123456789012"
#   }

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

variable "project_id" {
  description = "GCP project that hosts the runner VM and image registry."
  type        = string
}

variable "project_number" {
  description = "Numeric GCP project number (used for the default Compute Engine SA)."
  type        = string
}

variable "region" {
  description = "Region for Artifact Registry."
  type        = string
  default     = "europe-west1"
}

variable "enable_firestore" {
  description = "Grant the VM SA roles/datastore.user for Firestore via ADC."
  type        = bool
  default     = true
}

variable "enable_firebase_auth" {
  description = "Grant the VM SA roles/firebaseauth.admin (e.g. listUsers in actions)."
  type        = bool
  default     = false
}

variable "extra_secret_ids" {
  description = "Existing Secret Manager secret ids the VM SA may read (e.g. RC_SECRET_V2_API_KEY)."
  type        = list(string)
  default     = []
}

variable "join_token_secret_id" {
  description = "Secret Manager id for the enrollment join-token shell this module creates."
  type        = string
  default     = "POLYCORE_JOIN_TOKEN"
}

variable "signing_secret_secret_id" {
  description = "Secret Manager id for the enrollment signing-secret shell this module creates."
  type        = string
  default     = "POLYCORE_SIGNING_SECRET"
}

locals {
  vm_sa = "${var.project_number}-compute@developer.gserviceaccount.com"
}

# ---------------------------------------------------------------------------
# APIs
# ---------------------------------------------------------------------------

resource "google_project_service" "cloud_resource_manager" {
  project            = var.project_id
  service            = "cloudresourcemanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false

  depends_on = [google_project_service.cloud_resource_manager]
}

resource "google_project_service" "artifact_registry" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false

  depends_on = [google_project_service.cloud_resource_manager]
}

resource "google_project_service" "secret_manager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false

  depends_on = [google_project_service.cloud_resource_manager]
}

resource "google_project_service" "iam" {
  project            = var.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false

  depends_on = [google_project_service.cloud_resource_manager]
}

# ---------------------------------------------------------------------------
# Artifact Registry
# ---------------------------------------------------------------------------

resource "google_artifact_registry_repository" "polycore" {
  project       = var.project_id
  location      = var.region
  repository_id = "polycore"
  description   = "Polycore runner images"
  format        = "DOCKER"

  depends_on = [google_project_service.artifact_registry]
}

# ---------------------------------------------------------------------------
# Deploy SA (CI only: push images + manage the VM)
# ---------------------------------------------------------------------------

resource "google_service_account" "deploy" {
  project      = var.project_id
  account_id   = "polycore-runner-deploy"
  display_name = "Polycore runner CI deploy"
  description  = "Pushes runner images and resets the runner VM (no datastore access)"

  depends_on = [google_project_service.iam]
}

resource "google_project_iam_member" "deploy_ar_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_project_iam_member" "deploy_compute_admin" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.deploy.email}"

  depends_on = [google_project_service.compute]
}

resource "google_service_account_iam_member" "deploy_act_as_vm" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${local.vm_sa}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deploy.email}"

  depends_on = [google_project_service.compute]
}

# ---------------------------------------------------------------------------
# VM SA: pull images + ADC to data (optional) + read secrets
# ---------------------------------------------------------------------------

resource "google_project_iam_member" "vm_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${local.vm_sa}"

  depends_on = [google_project_service.artifact_registry, google_project_service.compute]
}

resource "google_project_iam_member" "vm_datastore_user" {
  count   = var.enable_firestore ? 1 : 0
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${local.vm_sa}"
}

resource "google_project_iam_member" "vm_firebase_auth_admin" {
  count   = var.enable_firebase_auth ? 1 : 0
  project = var.project_id
  role    = "roles/firebaseauth.admin"
  member  = "serviceAccount:${local.vm_sa}"
}

# ---------------------------------------------------------------------------
# Enrollment secret shells (values added out-of-band after enroll)
# ---------------------------------------------------------------------------

resource "google_secret_manager_secret" "join_token" {
  project   = var.project_id
  secret_id = var.join_token_secret_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.secret_manager]
}

resource "google_secret_manager_secret" "signing_secret" {
  project   = var.project_id
  secret_id = var.signing_secret_secret_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.secret_manager]
}

resource "google_secret_manager_secret_iam_member" "vm_join_token" {
  secret_id = google_secret_manager_secret.join_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.vm_sa}"
}

resource "google_secret_manager_secret_iam_member" "vm_signing_secret" {
  secret_id = google_secret_manager_secret.signing_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.vm_sa}"
}

resource "google_secret_manager_secret_iam_member" "vm_extra_secrets" {
  for_each  = toset(var.extra_secret_ids)
  secret_id = "projects/${var.project_id}/secrets/${each.value}"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.vm_sa}"

  depends_on = [google_project_service.secret_manager]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "artifact_registry_repository" {
  description = "Artifact Registry repository id (`polycore`)."
  value       = google_artifact_registry_repository.polycore.repository_id
}

output "image_host" {
  description = "Docker host prefix for runner images."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/polycore"
}

output "deploy_service_account_email" {
  description = "CI deploy SA email (mint a key for GitHub Actions)."
  value       = google_service_account.deploy.email
}

output "vm_service_account_email" {
  description = "Default Compute Engine SA the runner VM runs as."
  value       = local.vm_sa
}

output "join_token_secret_id" {
  description = "Secret Manager id for the enrollment join token."
  value       = google_secret_manager_secret.join_token.secret_id
}

output "signing_secret_secret_id" {
  description = "Secret Manager id for the enrollment signing secret."
  value       = google_secret_manager_secret.signing_secret.secret_id
}
