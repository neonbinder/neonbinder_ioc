terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }

  # GCS remote state — prefix set at init time via -backend-config="prefix=terraform/state/<env>"
  backend "gcs" {
    bucket = "neonbinder-terraform-state"
  }
}

# Configure the Google Provider
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

# ──────────────────────────────────────────────
# Service Accounts — split into runtime + deployer
# ──────────────────────────────────────────────

# Runtime SA: attached to the Cloud Run service at runtime
resource "google_service_account" "runtime" {
  account_id   = "neonbinder-browser-runtime"
  display_name = "NeonBinder Browser Runtime"
  description  = "Runtime service account for the browser automation Cloud Run service"
}

# Deployer SA: used by GitHub Actions via WIF to deploy
resource "google_service_account" "deployer" {
  account_id   = "neonbinder-browser-deployer"
  display_name = "NeonBinder Browser Deployer"
  description  = "Deployer service account for GitHub Actions CI/CD"
}

# ──────────────────────────────────────────────
# Runtime SA IAM — minimal permissions
# ──────────────────────────────────────────────

# Project-level secret access is required because the browser service dynamically
# creates/reads/deletes user credential secrets (e.g. buysportscards-credentials-user_xxx)
# that aren't known at Terraform plan time. Cannot be scoped to individual secrets.
resource "google_project_iam_member" "runtime_secret_accessor" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "runtime_secret_version_manager" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.secretVersionManager"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "runtime_logging_writer" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# Runtime SA gets run.invoker scoped to the specific Cloud Run service
resource "google_cloud_run_service_iam_member" "runtime_invoker" {
  location = google_cloud_run_service.neonbinder_browser.location
  service  = google_cloud_run_service.neonbinder_browser.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.runtime.email}"
}

# ──────────────────────────────────────────────
# Deployer SA IAM — deployment permissions
# ──────────────────────────────────────────────

resource "google_project_iam_member" "deployer_run_admin" {
  project = var.gcp_project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_project_iam_member" "deployer_artifactregistry_writer" {
  project = var.gcp_project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# objectAdmin (not storage.admin) — deployer only needs to push/pull Docker images
# to GCR, not create/delete buckets
resource "google_project_iam_member" "deployer_storage_object_admin" {
  project = var.gcp_project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# Deployer can act as the runtime SA (scoped to SA-level, not project-level)
resource "google_service_account_iam_member" "deployer_act_as_runtime" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

# ──────────────────────────────────────────────
# Convex Backend SA — used by Convex for GCS operations
# ──────────────────────────────────────────────

# Import note: this SA was created manually before Terraform.
# Import with: terraform import google_service_account.convex projects/PROJECT_ID/serviceAccounts/neonbinder-convex@PROJECT_ID.iam.gserviceaccount.com
resource "google_service_account" "convex" {
  account_id   = "neonbinder-convex"
  display_name = "NeonBinder Convex Backend"
  description  = "Service account for the Convex backend (GCS, Secret Manager)"
}

# Note: Convex SA does not directly access Secret Manager.
# Credential operations are proxied through the browser service via HTTP.
# The Convex SA only needs GCS access (granted via bucket-level IAM below).

# ──────────────────────────────────────────────
# Developer SA impersonation — local dev access
# ──────────────────────────────────────────────

# Allow developers to impersonate the runtime SA (for local browser service dev)
resource "google_service_account_iam_member" "developer_impersonate_runtime" {
  for_each           = toset(var.developer_emails)
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${each.value}"
}

# Allow developers to impersonate the convex SA (for local Convex/GCS dev)
resource "google_service_account_iam_member" "developer_impersonate_convex" {
  for_each           = toset(var.developer_emails)
  service_account_id = google_service_account.convex.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${each.value}"
}

# ──────────────────────────────────────────────
# Secret Manager — INTERNAL_API_KEY
# ──────────────────────────────────────────────

resource "google_secret_manager_secret" "internal_api_key" {
  secret_id = "internal-api-key"

  replication {
    auto {}
  }

  labels = var.common_labels
}

# Runtime SA needs to read the API key secret
resource "google_secret_manager_secret_iam_member" "runtime_api_key_access" {
  secret_id = google_secret_manager_secret.internal_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

# Deployer SA needs to read the API key secret (for post-deploy smoke tests)
resource "google_secret_manager_secret_iam_member" "deployer_api_key_access" {
  secret_id = google_secret_manager_secret.internal_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.deployer.email}"
}

# ──────────────────────────────────────────────
# Cloud Run Service
# ──────────────────────────────────────────────

resource "google_cloud_run_service" "neonbinder_browser" {
  name     = var.cloud_run_service_name
  location = var.gcp_region

  template {
    spec {
      containers {
        image = var.cloud_run_image

        resources {
          limits = {
            cpu    = var.cloud_run_cpu
            memory = var.cloud_run_memory
          }
        }

        env {
          name = "INTERNAL_API_KEY"
          value_from {
            secret_key_ref {
              name = google_secret_manager_secret.internal_api_key.secret_id
              key  = "latest"
            }
          }
        }

        env {
          name  = "ENVIRONMENT"
          value = var.environment
        }
      }

      service_account_name = google_service_account.runtime.email
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

# Allow unauthenticated access to Cloud Run.
# Convex cannot perform GCP IAM auth, so we rely on the INTERNAL_API_KEY header
# (validated with timing-safe comparison + rate limiting) for authentication.
resource "google_cloud_run_service_iam_member" "public_access" {
  location = google_cloud_run_service.neonbinder_browser.location
  service  = google_cloud_run_service.neonbinder_browser.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ──────────────────────────────────────────────
# GCS Bucket for prizes (prod only)
# ──────────────────────────────────────────────

resource "google_storage_bucket" "neonbinder_prizes" {
  count    = var.create_prizes_bucket ? 1 : 0
  name     = "neonbinder-prizes-${var.gcp_project_id}"
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
  count  = var.create_prizes_bucket ? 1 : 0
  bucket = google_storage_bucket.neonbinder_prizes[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.convex.email}"
}

# ──────────────────────────────────────────────
# Workload Identity Federation for GitHub Actions
# ──────────────────────────────────────────────

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
    "attribute.ref"        = "assertion.ref"
  }

  attribute_condition = "assertion.repository == \"${var.github_repo}\" && assertion.ref == \"${var.wif_branch_ref}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow GitHub Actions to impersonate the deployer SA (not the runtime SA)
resource "google_service_account_iam_member" "github_actions_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${var.github_repo}"
}

# ──────────────────────────────────────────────
# Terraform Deployer SA — used by GitHub Actions to apply Terraform
# ──────────────────────────────────────────────

resource "google_service_account" "terraform_deployer" {
  account_id   = "neonbinder-tf-deployer"
  display_name = "NeonBinder Terraform Deployer"
  description  = "Service account for Terraform CI/CD via GitHub Actions"
}

# Terraform deployer permissions — manages all resources in the project
resource "google_project_iam_member" "tf_deployer_sa_admin" {
  project = var.gcp_project_id
  role    = "roles/iam.serviceAccountAdmin"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# projectIamAdmin allows managing project IAM bindings (needed for
# google_project_iam_member resources). More scoped than iam.securityAdmin
# which also grants org-level IAM and custom role management.
# Risk is mitigated by WIF restricting this SA to the terraform repo + branch.
resource "google_project_iam_member" "tf_deployer_project_iam_admin" {
  project = var.gcp_project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

resource "google_project_iam_member" "tf_deployer_run_admin" {
  project = var.gcp_project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

resource "google_project_iam_member" "tf_deployer_secret_admin" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.admin"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

resource "google_project_iam_member" "tf_deployer_storage_admin" {
  project = var.gcp_project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

resource "google_project_iam_member" "tf_deployer_wif_admin" {
  project = var.gcp_project_id
  role    = "roles/iam.workloadIdentityPoolAdmin"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# Scoped to specific SAs instead of project-wide to prevent impersonating arbitrary SAs
resource "google_service_account_iam_member" "tf_deployer_act_as_runtime" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

resource "google_service_account_iam_member" "tf_deployer_act_as_deployer" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

resource "google_service_account_iam_member" "tf_deployer_act_as_convex" {
  service_account_id = google_service_account.convex.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# WIF provider for the Terraform repo
resource "google_iam_workload_identity_pool_provider" "github_terraform" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-terraform"
  display_name                       = "GitHub Terraform"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  attribute_condition = "assertion.repository == \"${var.github_repo_terraform}\" && assertion.ref == \"${var.wif_branch_ref}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow GitHub Actions (terraform repo) to impersonate the terraform deployer SA
resource "google_service_account_iam_member" "github_actions_wif_terraform" {
  service_account_id = google_service_account.terraform_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${var.github_repo_terraform}"
}

# ──────────────────────────────────────────────
# Cloud Audit Logging — data access logs for security-sensitive services
# ──────────────────────────────────────────────

resource "google_project_iam_audit_config" "iam_audit" {
  project = var.gcp_project_id
  service = "iam.googleapis.com"

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

resource "google_project_iam_audit_config" "secretmanager_audit" {
  project = var.gcp_project_id
  service = "secretmanager.googleapis.com"

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# ──────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────

output "runtime_service_account_email" {
  description = "Email of the runtime service account"
  value       = google_service_account.runtime.email
}

output "deployer_service_account_email" {
  description = "Email of the deployer service account"
  value       = google_service_account.deployer.email
}

output "convex_service_account_email" {
  description = "Email of the Convex backend service account"
  value       = google_service_account.convex.email
}

output "cloud_run_url" {
  description = "URL of the deployed Cloud Run service"
  value       = google_cloud_run_service.neonbinder_browser.status[0].url
}

output "prizes_bucket_name" {
  description = "Name of the prizes GCS bucket"
  value       = var.create_prizes_bucket ? google_storage_bucket.neonbinder_prizes[0].name : ""
}

output "prizes_bucket_url" {
  description = "URL of the prizes GCS bucket"
  value       = var.create_prizes_bucket ? google_storage_bucket.neonbinder_prizes[0].url : ""
}

output "wif_provider_name" {
  description = "Full resource name of the WIF provider (use as GCP_WIF_PROVIDER GitHub secret)"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "terraform_deployer_service_account_email" {
  description = "Email of the Terraform deployer service account"
  value       = google_service_account.terraform_deployer.email
}

output "wif_provider_terraform_name" {
  description = "Full resource name of the Terraform WIF provider (use as GCP_WIF_PROVIDER_TF GitHub secret)"
  value       = google_iam_workload_identity_pool_provider.github_terraform.name
}
