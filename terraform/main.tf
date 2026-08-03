terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

variable "project_id" {
  description = "GCP project that hosts the runner."
  type        = string
}

variable "region" {
  description = "Artifact Registry and VM region."
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "Zone for the runner MIG. Defaults to the region's b zone."
  type        = string
  default     = null
  nullable    = true
}

variable "runner_name" {
  description = "Stable prefix for runner resources."
  type        = string
  default     = "polycore-runner"

  validation {
    condition     = length(var.runner_name) >= 3 && length(var.runner_name) <= 23 && can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.runner_name))
    error_message = "runner_name must be a valid 3 to 23 character GCE name."
  }
}

variable "image_name" {
  description = "Docker image name inside the module-managed Artifact Registry repository."
  type        = string
  default     = "runner"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]*$", var.image_name))
    error_message = "image_name must be a valid Docker image name without a tag."
  }
}

variable "runner_id" {
  description = "Control-plane runner id returned by enrollment."
  type        = string
}

variable "project_slug" {
  description = "Polycore project slug served by this runner."
  type        = string
}

variable "network" {
  description = "VPC network used by the runner VM."
  type        = string
  default     = "default"
}

variable "machine_type" {
  description = "Compute Engine machine type."
  type        = string
  default     = "e2-micro"
}

variable "enable_firestore" {
  description = "Grant the runner VM service account roles/datastore.user."
  type        = bool
  default     = true
}

variable "enable_firebase_auth" {
  description = "Grant the runner VM service account roles/firebaseauth.admin."
  type        = bool
  default     = false
}

variable "join_token_secret_id" {
  description = "Secret Manager id for the enrollment join-token shell."
  type        = string
  default     = "POLYCORE_JOIN_TOKEN"
}

variable "signing_secret_secret_id" {
  description = "Secret Manager id for the enrollment signing-secret shell."
  type        = string
  default     = "POLYCORE_SIGNING_SECRET"
}

variable "extra_secrets" {
  description = "Additional container environment variable to Secret Manager id mappings."
  type        = map(string)
  default     = {}
}

variable "extra_env" {
  description = "Additional non-secret container environment variables."
  type        = map(string)
  default     = {}
}

locals {
  zone                  = coalesce(var.zone, "${var.region}-b")
  vm_service_account_id = "${var.runner_name}-vm"
  deploy_account_id     = "${var.runner_name}-deploy"
  health_check_port     = 8080
  health_check_tag      = "${var.runner_name}-health-check"

  image_repository = "${var.region}-docker.pkg.dev/${var.project_id}/polycore/${var.image_name}"
  live_image       = "${local.image_repository}:live"

  encoded_extra_secrets = join("\n", [
    for env_name, secret_id in var.extra_secrets :
    "${base64encode(secret_id)} ${base64encode(env_name)}"
  ])
  encoded_extra_env = join("\n", [
    for env_name, value in var.extra_env :
    "${base64encode(env_name)} ${base64encode(value)}"
  ])
}

resource "google_project_service" "services" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "polycore" {
  project       = var.project_id
  location      = var.region
  repository_id = "polycore"
  description   = "Polycore runner images"
  format        = "DOCKER"

  docker_config {
    immutable_tags = false
  }

  depends_on = [google_project_service.services["artifactregistry.googleapis.com"]]
}

resource "google_service_account" "runner" {
  project      = var.project_id
  account_id   = local.vm_service_account_id
  display_name = "Polycore runner VM"
  description  = "Runtime identity for the customer-hosted Polycore runner"

  depends_on = [google_project_service.services["iam.googleapis.com"]]
}

resource "google_service_account" "deploy" {
  project      = var.project_id
  account_id   = local.deploy_account_id
  display_name = "Polycore runner CI deploy"
  description  = "Publishes runner images and rolls the runner MIG"

  depends_on = [google_project_service.services["iam.googleapis.com"]]
}

resource "google_artifact_registry_repository_iam_member" "deploy" {
  project    = var.project_id
  location   = google_artifact_registry_repository.polycore.location
  repository = google_artifact_registry_repository.polycore.repository_id
  role       = "roles/artifactregistry.repoAdmin"
  member     = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_project_iam_member" "deploy_compute_admin" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.deploy.email}"

  depends_on = [google_project_service.services["compute.googleapis.com"]]
}

resource "google_project_iam_custom_role" "deploy_health_check_user" {
  project     = var.project_id
  role_id     = "${replace(var.runner_name, "-", "_")}_health_check_user"
  title       = "Polycore runner deploy health check user"
  description = "Allows runner deployment CI to roll a health-checked MIG"
  permissions = ["compute.healthChecks.use"]

  depends_on = [google_project_service.services["iam.googleapis.com"]]
}

resource "google_project_iam_member" "deploy_health_check_user" {
  project = var.project_id
  role    = google_project_iam_custom_role.deploy_health_check_user.name
  member  = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_service_account_iam_member" "deploy_act_as_runner" {
  service_account_id = google_service_account.runner.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deploy.email}"
}

resource "google_project_iam_member" "runner_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.runner.email}"

  depends_on = [google_artifact_registry_repository.polycore]
}

resource "google_project_iam_member" "runner_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runner.email}"

  depends_on = [google_project_service.services["logging.googleapis.com"]]
}

resource "google_project_iam_member" "runner_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.runner.email}"

  depends_on = [google_project_service.services["monitoring.googleapis.com"]]
}

resource "google_project_iam_member" "runner_datastore_user" {
  count   = var.enable_firestore ? 1 : 0
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_project_iam_member" "runner_firebase_auth_admin" {
  count   = var.enable_firebase_auth ? 1 : 0
  project = var.project_id
  role    = "roles/firebaseauth.admin"
  member  = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_secret_manager_secret" "join_token" {
  project   = var.project_id
  secret_id = var.join_token_secret_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.services["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret" "signing_secret" {
  project   = var.project_id
  secret_id = var.signing_secret_secret_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.services["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_iam_member" "runner_join_token" {
  secret_id = google_secret_manager_secret.join_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_secret_manager_secret_iam_member" "runner_signing_secret" {
  secret_id = google_secret_manager_secret.signing_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runner.email}"
}

resource "google_secret_manager_secret_iam_member" "runner_extra_secrets" {
  for_each  = toset(values(var.extra_secrets))
  secret_id = "projects/${var.project_id}/secrets/${each.value}"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runner.email}"

  depends_on = [google_project_service.services["secretmanager.googleapis.com"]]
}

resource "google_compute_health_check" "runner" {
  project = var.project_id
  name    = "${var.runner_name}-health"

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 6

  http_health_check {
    port         = local.health_check_port
    request_path = "/health"
  }

  depends_on = [google_project_service.services["compute.googleapis.com"]]
}

resource "google_compute_firewall" "runner_health_check" {
  project = var.project_id
  name    = "${var.runner_name}-allow-health-check"
  network = var.network

  direction     = "INGRESS"
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = [local.health_check_tag]

  allow {
    protocol = "tcp"
    ports    = [tostring(local.health_check_port)]
  }

  depends_on = [google_project_service.services["compute.googleapis.com"]]
}

data "google_compute_image" "cos" {
  family  = "cos-stable"
  project = "cos-cloud"
}

resource "google_compute_instance_template" "runner" {
  project      = var.project_id
  name_prefix  = "${var.runner_name}-"
  description  = "Polycore runner on Container-Optimized OS"
  machine_type = var.machine_type
  tags         = [local.health_check_tag]

  labels = {
    polycore-runner = var.runner_name
  }

  disk {
    source_image = data.google_compute_image.cos.self_link
    auto_delete  = true
    boot         = true
    disk_size_gb = 20
  }

  network_interface {
    network = var.network
    access_config {}
  }

  service_account {
    email  = google_service_account.runner.email
    scopes = ["cloud-platform"]
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  metadata = {
    host-project              = var.project_id
    runner-image              = local.live_image
    control-plane-ws          = "wss://cp.polycore.ai/runner"
    runner-id                 = var.runner_id
    polycore-project-slug     = var.project_slug
    google-cloud-project      = var.project_id
    container-name            = var.runner_name
    health-check-port         = tostring(local.health_check_port)
    secret-join-token         = var.join_token_secret_id
    secret-signing-secret     = var.signing_secret_secret_id
    extra-secrets             = local.encoded_extra_secrets
    extra-env                 = local.encoded_extra_env
    google-logging-enabled    = "true"
    google-monitoring-enabled = "true"
  }

  metadata_startup_script = file("${path.module}/vm-startup.sh")

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    google_project_iam_member.runner_ar_reader,
    google_secret_manager_secret_iam_member.runner_join_token,
    google_secret_manager_secret_iam_member.runner_signing_secret,
  ]
}

resource "google_compute_instance_group_manager" "runner" {
  project            = var.project_id
  zone               = local.zone
  name               = var.runner_name
  base_instance_name = var.runner_name
  target_size        = 1

  version {
    instance_template = google_compute_instance_template.runner.id
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.runner.id
    initial_delay_sec = 300
  }

  instance_lifecycle_policy {
    on_failed_health_check = "DO_NOTHING"
  }

  update_policy {
    type                           = "PROACTIVE"
    minimal_action                 = "REPLACE"
    most_disruptive_allowed_action = "REPLACE"
    replacement_method             = "SUBSTITUTE"
    max_surge_fixed                = 1
    max_unavailable_fixed          = 0
  }

  wait_for_instances = false

  lifecycle {
    ignore_changes = [version[0].name]
  }

  depends_on = [google_compute_firewall.runner_health_check]
}

output "image_repository" {
  description = "Docker image repository without a tag."
  value       = local.image_repository
}

output "live_image" {
  description = "Mutable image reference pulled by runner VMs."
  value       = local.live_image
}

output "managed_instance_group_name" {
  description = "Runner managed instance group name."
  value       = google_compute_instance_group_manager.runner.name
}

output "deploy_service_account_email" {
  description = "Service account used by deployment CI."
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
