moved {
  from = google_project_service.cloud_resource_manager
  to   = google_project_service.services["cloudresourcemanager.googleapis.com"]
}

moved {
  from = google_project_service.compute
  to   = google_project_service.services["compute.googleapis.com"]
}

moved {
  from = google_project_service.artifact_registry
  to   = google_project_service.services["artifactregistry.googleapis.com"]
}

moved {
  from = google_project_service.iam
  to   = google_project_service.services["iam.googleapis.com"]
}

moved {
  from = google_project_service.secret_manager
  to   = google_project_service.services["secretmanager.googleapis.com"]
}

# The default Compute Engine identity can also run backend workloads.
removed {
  from = google_project_iam_member.vm_ar_reader
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_project_iam_member.vm_datastore_user
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_project_iam_member.vm_firebase_auth_admin
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_secret_manager_secret_iam_member.vm_join_token
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_secret_manager_secret_iam_member.vm_signing_secret
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_secret_manager_secret_iam_member.vm_extra_secrets
  lifecycle {
    destroy = false
  }
}

# Keep the old VM deployable until the migration is verified.
removed {
  from = google_service_account_iam_member.deploy_act_as_vm
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_project_iam_member.deploy_ar_writer
  lifecycle {
    destroy = false
  }
}
