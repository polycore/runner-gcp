# Opinionated GCP install for a Polycore runner.
#
# Public module: https://github.com/polycore/runner-gcp
#
#   module "polycore_runner" {
#     source = "git::https://github.com/polycore/runner-gcp.git//terraform?ref=v0.2.0"
#     project_id = "acme-prod"
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
  description = "GCP project that hosts the runner MIG and image registry."
  type        = string
}

variable "region" {
  description = "Region for Artifact Registry."
  type        = string
  default     = "europe-west1"
}

variable "runner_name" {
  description = "Stable name shared by the runner MIG, health check, and network tag."
  type        = string
  default     = "polycore-runner"

  validation {
    condition     = length(var.runner_name) <= 40 && can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.runner_name))
    error_message = "runner_name must be a valid GCE name of at most 40 characters."
  }
}

variable "network" {
  description = "VPC network where the runner MIG is created."
  type        = string
  default     = "default"
}

variable "vm_service_account_id" {
  description = "Account id for the dedicated runner VM service account."
  type        = string
  default     = "polycore-runner-vm"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.vm_service_account_id))
    error_message = "vm_service_account_id must be a valid 6 to 30 character service-account id."
  }
}

variable "health_check_port" {
  description = "Port exposed only to Google Cloud health check probes."
  type        = number
  default     = 8080

  validation {
    condition     = floor(var.health_check_port) == var.health_check_port && var.health_check_port >= 1 && var.health_check_port <= 65535
    error_message = "health_check_port must be an integer between 1 and 65535."
  }
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

resource "google_project_service" "logging" {
  project            = var.project_id
  service            = "logging.googleapis.com"
  disable_on_destroy = false

  depends_on = [google_project_service.cloud_resource_manager]
}

resource "google_project_service" "monitoring" {
  project            = var.project_id
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false

  depends_on = [google_project_service.cloud_resource_manager]
}

# ---------------------------------------------------------------------------
# Runner health check
# ---------------------------------------------------------------------------

resource "google_compute_health_check" "runner" {
  project = var.project_id
  name    = "${var.runner_name}-health"

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 6

  http_health_check {
    port         = var.health_check_port
    request_path = "/health"
  }

  depends_on = [google_project_service.compute]
}

resource "google_compute_firewall" "runner_health_check" {
  project = var.project_id
  name    = "${var.runner_name}-allow-health-check"
  network = var.network

  direction     = "INGRESS"
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["${var.runner_name}-health-check"]

  allow {
    protocol = "tcp"
    ports    = [tostring(var.health_check_port)]
  }

  depends_on = [google_project_service.compute]
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
# Service accounts
# ---------------------------------------------------------------------------

resource "google_service_account" "runner" {
  project      = var.project_id
  account_id   = var.vm_service_account_id
  display_name = "Polycore runner VM"
  description  = "Runtime identity for the customer-hosted Polycore runner"

  depends_on = [google_project_service.iam]
}

# CI only: push images and manage the MIG. It has no datastore access.
resource "google_service_account" "deploy" {
  project      = var.project_id
  account_id   = "polycore-runner-deploy"
  display_name = "Polycore runner CI deploy"
  description  = "Pushes runner images and rolls the runner MIG (no datastore access)"

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
  service_account_id = google_service_account.runner.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deploy.email}"

  depends_on = [google_project_service.compute]
}

# ---------------------------------------------------------------------------
# Runner VM SA: pull images + ADC to data (optional) + read secrets
# ---------------------------------------------------------------------------

resource "google_project_iam_member" "vm_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.runner.email}"

  depends_on = [google_project_service.artifact_registry, google_project_service.compute]
}

resource "google_project_iam_member" "vm_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runner.email}"

  depends_on = [google_project_service.logging]
}

resource "google_project_iam_member" "vm_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.runner.email}"

  depends_on = [google_project_service.monitoring]
}

resource "google_project_iam_member" "vm_datastore_user" {
  count   = var.enable_firestore ? 1 : 0
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_project_iam_member" "vm_firebase_auth_admin" {
  count   = var.enable_firebase_auth ? 1 : 0
  project = var.project_id
  role    = "roles/firebaseauth.admin"
  member  = "serviceAccount:${google_service_account.runner.email}"
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
  member    = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_secret_manager_secret_iam_member" "vm_signing_secret" {
  secret_id = google_secret_manager_secret.signing_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_secret_manager_secret_iam_member" "vm_extra_secrets" {
  for_each  = toset(var.extra_secret_ids)
  secret_id = "projects/${var.project_id}/secrets/${each.value}"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runner.email}"

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
  description = "Dedicated service account used by runner VMs."
  value       = google_service_account.runner.email
}

output "join_token_secret_id" {
  description = "Secret Manager id for the enrollment join token."
  value       = google_secret_manager_secret.join_token.secret_id
}

output "signing_secret_secret_id" {
  description = "Secret Manager id for the enrollment signing secret."
  value       = google_secret_manager_secret.signing_secret.secret_id
}

output "health_check_name" {
  description = "Health check attached to the runner MIG."
  value       = google_compute_health_check.runner.name
}

output "health_check_port" {
  description = "Runner health endpoint port."
  value       = var.health_check_port
}
