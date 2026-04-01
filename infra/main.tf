# ==============================================================================
# Variables
# ==============================================================================
variable "hub_project" {
  description = "The GCP project ID for the centralized CI/CD infrastructure (hub)."
  default     = "global-actions-runner"
}

variable "spoke_project" {
  description = "The GCP project ID for the application environment (spoke)."
  default     = "bellhop-489500"
}

variable "region" {
  description = "The GCP region for all resources."
  default     = "us-central1"
}

# ==============================================================================
# Locals
# ==============================================================================
locals {
  required_apis = [
    "iam.googleapis.com",
    "compute.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
    "artifactregistry.googleapis.com"
  ]

  function_source_bucket_name = "${var.hub_project}-cf-source"
}

# ==============================================================================
# 1. API Services Enablement
# ==============================================================================
resource "google_project_service" "apis" {
  for_each                   = toset(local.required_apis)
  project                    = var.hub_project
  service                    = each.key
  disable_dependent_services = true
  disable_on_destroy         = false
}

# ==============================================================================
# 2. Service Accounts
# ==============================================================================
resource "google_service_account" "github_runner_sa" {
  project      = var.hub_project
  account_id   = "github-runner-sa"
  display_name = "GitHub Actions Ephemeral Runner"
}

resource "google_service_account" "gcf_trigger_sa" {
  project      = var.hub_project
  account_id   = "gcf-github-trigger-sa"
  display_name = "Cloud Function GitHub Trigger SA"
}

# ==============================================================================
# 3. IAM Bindings
# ==============================================================================
# Spoke project access for deployments
resource "google_project_iam_member" "spoke_project_access" {
  project = var.spoke_project
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.github_runner_sa.email}"
}

# Hub project permissions for Cloud Function
resource "google_secret_manager_secret_iam_member" "gcf_pat_accessor" {
  project    = var.hub_project
  secret_id  = "github-pat"
  role       = "roles/secretmanager.secretAccessor"
  member     = "serviceAccount:${google_service_account.gcf_trigger_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "gcf_webhook_secret_accessor" {
  project    = var.hub_project
  secret_id  = "github-webhook-secret"
  role       = "roles/secretmanager.secretAccessor"
  member     = "serviceAccount:${google_service_account.gcf_trigger_sa.email}"
}

resource "google_project_iam_member" "gcf_compute_admin" {
  project    = var.hub_project
  role       = "roles/compute.instanceAdmin.v1"
  member     = "serviceAccount:${google_service_account.gcf_trigger_sa.email}"
}

resource "google_service_account_iam_member" "gcf_sa_user" {
  service_account_id = google_service_account.github_runner_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.gcf_trigger_sa.email}"
}

# ==============================================================================
# 4. Cloud Function Source Code
# ==============================================================================
resource "google_storage_bucket" "function_source_bucket" {
  project                     = var.hub_project
  name                        = local.function_source_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
}

data "archive_file" "function_source_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../cloud_function"
  output_path = "/tmp/function_source.zip"
}

resource "google_storage_bucket_object" "function_source_object" {
  name   = "source-${data.archive_file.function_source_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_source_bucket.name
  source = data.archive_file.function_source_zip.output_path
}

# ==============================================================================
# 5. Cloud Function Resource
# ==============================================================================
resource "google_cloudfunctions2_function" "github_trigger_function" {
  project    = var.hub_project
  name       = "github-actions-trigger"
  location   = var.region

  build_config {
    runtime     = "python311"
    entry_point = "github_webhook_handler"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source_bucket.name
        object = google_storage_bucket_object.function_source_object.name
      }
    }
  }

  service_config {
    max_instance_count = 5
    min_instance_count = 0
    available_memory   = "512Mi"
    timeout_seconds    = 60
    service_account_email = google_service_account.gcf_trigger_sa.email
    environment_variables = {
      GCP_PROJECT       = var.hub_project
      GCP_ZONE          = "${var.region}-a"
      PAT_SECRET_ID     = "github-pat"
      WEBHOOK_SECRET_ID = "github-webhook-secret"
      TEMPLATE_PREFIX   = "github-spot-runner-"
      LOG_EXECUTION_ID  = "true" # Matches current GCP setting
    }
    ingress_settings               = "ALLOW_ALL"
    all_traffic_on_latest_revision = true
  }
}

resource "google_cloud_run_service_iam_member" "public_invoker" {
  location = google_cloudfunctions2_function.github_trigger_function.location
  project  = google_cloudfunctions2_function.github_trigger_function.project
  service  = google_cloudfunctions2_function.github_trigger_function.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ==============================================================================
# 6. Artifact Registry Pull-Through Cache
# ==============================================================================
resource "google_artifact_registry_repository" "docker_hub_cache" {
  project       = var.hub_project
  location      = var.region
  repository_id = "docker-hub-cache"
  description   = "Docker Hub Pull-Through Cache"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    description = "Docker Hub Mirror"
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }
}

# ==============================================================================
# 7. Runner VM Instance Template
# ==============================================================================
resource "google_compute_instance_template" "ephemeral_runner_template" {
  project      = var.hub_project
  name_prefix  = "github-spot-runner-"
  machine_type = "e2-standard-2"
  region       = var.region

  scheduling {
    preemptible       = false
    automatic_restart = false
    provisioning_model = "STANDARD"
  }

  disk {
    # Points to the optimized image with pre-pulled Docker layers
    source_image = "projects/${var.hub_project}/global/images/github-runner-base-v3"
    disk_size_gb = 50
    auto_delete  = true
  }

  network_interface {
    network = "default"
    access_config {
      network_tier = "STANDARD"
    }
  }

  service_account {
    email  = google_service_account.github_runner_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    serial-port-logging-enable = "true"
    startup-script             = file("${path.module}/runner_startup.sh")
  }

  labels = {
    goog-terraform-provisioned = "true"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ==============================================================================
# 8. Outputs
# ==============================================================================
output "cloud_function_trigger_url" {
  description = "The HTTPS trigger URL for the Cloud Function."
  value       = google_cloudfunctions2_function.github_trigger_function.service_config[0].uri
}
