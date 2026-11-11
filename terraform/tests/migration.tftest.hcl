mock_provider "google" {
  mock_data "google_compute_image" {
    defaults = {
      self_link = "projects/cos-cloud/global/images/cos-test"
    }
  }
}

variables {
  project_id   = "acme-prod"
  runner_id    = "rnr_test"
  project_slug = "acme"
}

run "stage_without_starting_a_second_runner" {
  command = plan
  variables {
    target_size = 0
  }
  assert {
    condition     = google_compute_instance_group_manager.runner.target_size == 0
    error_message = "Staging must not start a runner alongside the standalone VM."
  }
  assert {
    condition     = google_service_account.deploy.account_id == "polycore-runner-deploy"
    error_message = "The default deploy identity must remain compatible with v0.1 credentials."
  }
}

run "normal_operation" {
  command = plan
  assert {
    condition     = google_compute_instance_group_manager.runner.target_size == 1
    error_message = "Normal operation must use one runner."
  }
}

run "reject_multiple_runner_instances" {
  command = plan
  variables {
    target_size = 2
  }
  expect_failures = [var.target_size]
}
