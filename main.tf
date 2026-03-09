terraform {
  required_version = ">= 1.0"
  
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }

  # Optional: Use GCS for remote state storage
  # backend "gcs" {
  #   bucket = "neonbinder-terraform-state"
  #   prefix = "terraform/state"
  # }
}

# Configure the Google Provider
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}



# Variables are defined in variables.tf

# GCP Resources

# Service Account for the browser automation
resource "google_service_account" "neonbinder_browser" {
  account_id   = var.service_account_name
  display_name = "Neon Binder Browser Automation Runner"
  description  = "Service account for browser automation and site scraping"
}

# IAM bindings for the service account
resource "google_project_iam_member" "secretmanager_accessor" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.neonbinder_browser.email}"
}

resource "google_project_iam_member" "logging_writer" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.neonbinder_browser.email}"
}

resource "google_project_iam_member" "run_invoker" {
  project = var.gcp_project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.neonbinder_browser.email}"
}

# Cloud Run service (optional - if you want to manage it via Terraform)
resource "google_cloud_run_service" "neonbinder_browser" {
  name     = "neonbinder-browser"
  location = var.gcp_region

  template {
    spec {
      containers {
        image = "gcr.io/${var.gcp_project_id}/neonbinder-browser:latest"
        
        resources {
          limits = {
            cpu    = "1000m"
            memory = "1Gi"
          }
        }
      }
      
      service_account_name = google_service_account.neonbinder_browser.email
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }

  lifecycle {
    ignore_changes = [template[0].spec[0].containers[0].image]
  }
}

# IAM policy to allow unauthenticated access to Cloud Run
resource "google_cloud_run_service_iam_member" "public_access" {
  location = google_cloud_run_service.neonbinder_browser.location
  service  = google_cloud_run_service.neonbinder_browser.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}



# GCS Bucket for prizes
resource "google_storage_bucket" "neonbinder_prizes" {
  name     = "neonbinder-prizes"
  location = var.gcp_region
  
  uniform_bucket_level_access = true
  
  versioning {
    enabled = false
  }
  
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 365  # Delete objects older than 1 year
    }
  }
  
  labels = var.common_labels
}

# Grant neonbinder-convex service account access to the prizes bucket
resource "google_storage_bucket_iam_member" "neonbinder_convex_prizes_admin" {
  bucket = google_storage_bucket.neonbinder_prizes.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:neonbinder-convex@${var.gcp_project_id}.iam.gserviceaccount.com"
}

# Workload Identity Federation for GitHub Actions
resource "google_iam_workload_identity_pool" "github_actions" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "Identity pool for GitHub Actions CI/CD"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "assertion.repository == \"${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow GitHub Actions to impersonate the service account
resource "google_service_account_iam_member" "github_actions_wif" {
  service_account_id = google_service_account.neonbinder_browser.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${var.github_repo}"
}

# Additional IAM roles for deployment
resource "google_project_iam_member" "run_admin" {
  project = var.gcp_project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.neonbinder_browser.email}"
}

resource "google_project_iam_member" "storage_admin" {
  project = var.gcp_project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.neonbinder_browser.email}"
}

resource "google_project_iam_member" "artifactregistry_writer" {
  project = var.gcp_project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.neonbinder_browser.email}"
}

resource "google_project_iam_member" "service_account_user" {
  project = var.gcp_project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.neonbinder_browser.email}"
}

# Outputs
output "service_account_email" {
  description = "Email of the created service account"
  value       = google_service_account.neonbinder_browser.email
}

output "cloud_run_url" {
  description = "URL of the deployed Cloud Run service"
  value       = google_cloud_run_service.neonbinder_browser.status[0].url
}

output "prizes_bucket_name" {
  description = "Name of the prizes GCS bucket"
  value       = google_storage_bucket.neonbinder_prizes.name
}

output "prizes_bucket_url" {
  description = "URL of the prizes GCS bucket"
  value       = google_storage_bucket.neonbinder_prizes.url
}

output "wif_provider_name" {
  description = "Full resource name of the WIF provider (use as GCP_WIF_PROVIDER GitHub secret)"
  value       = google_iam_workload_identity_pool_provider.github.name
}
