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
}

# IAM policy to allow unauthenticated access to Cloud Run
resource "google_cloud_run_service_iam_member" "public_access" {
  location = google_cloud_run_service.neonbinder_browser.location
  service  = google_cloud_run_service.neonbinder_browser.name
  role     = "roles/run.invoker"
  member   = "allUsers"
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

 