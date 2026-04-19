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
    bucket = "neonbinder-terraform-state-prod"
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

# Project-level secret admin is required because the browser service dynamically
# creates/reads/updates/deletes user credential secrets (e.g. buysportscards-credentials-user_xxx)
# that aren't known at Terraform plan time. Cannot be scoped to individual secrets.
# Includes: secrets.create, secrets.delete, secrets.get, secretVersions.add, secretVersions.access
resource "google_project_iam_member" "runtime_secret_admin" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.admin"
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
# Artifact Registry — gcr.io-compatible Docker registry
# ──────────────────────────────────────────────

# Prod has this pre-existing from Google's GCR-to-AR migration; dev's was
# manually created on 2026-04-16 when CI needed it for its first Docker push.
# Both are now tracked by Terraform.
resource "google_artifact_registry_repository" "gcr_io" {
  project       = var.gcp_project_id
  location      = "us"
  repository_id = "gcr.io"
  format        = "DOCKER"
  description   = "Legacy gcr.io-compatible Docker image registry"
}

# createOnPushWriter lets the browser deployer push to a repo path that doesn't
# exist yet (the AR repo is static here, but the <image> path inside can be new).
resource "google_artifact_registry_repository_iam_member" "deployer_create_on_push" {
  project    = var.gcp_project_id
  location   = google_artifact_registry_repository.gcr_io.location
  repository = google_artifact_registry_repository.gcr_io.name
  role       = "roles/artifactregistry.createOnPushWriter"
  member     = "serviceAccount:${google_service_account.deployer.email}"
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

# Browser runtime SA manages per-user marketplace credential secrets dynamically
# (PUT/GET/DELETE /credentials/:key). Needs project-level admin to create secrets
# it doesn't know about in advance.
resource "google_project_iam_member" "runtime_secretmanager_admin" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.admin"
  member  = "serviceAccount:${google_service_account.runtime.email}"
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

        env {
          name  = "GOOGLE_CLOUD_PROJECT"
          value = var.gcp_project_id
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
    # `traffic` is owned by the deploy workflow: dev pins the new revision
    # at 100% on push; prod's blue/green gate carves out tagged no-traffic
    # PR previews + a tagged no-traffic prod candidate. Terraform flipping
    # back to latest_revision=true on every plan would fight both.
    ignore_changes = [
      template[0].spec[0].containers[0].image,
      traffic,
    ]
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
      age = 365 # Delete objects older than 1 year
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
    "attribute.event_name" = "assertion.event_name"
  }

  # Browser repo is trunk-based: `browser_wif_branch_ref` is
  # `refs/heads/main` in both envs, separate from the terraform+preprocess
  # providers' `wif_branch_ref` which still rides dev's `develop` branch.
  # When browser_wif_allow_pull_requests is true (dev), also accept
  # pull_request OIDC tokens (ref == refs/pull/<N>/merge) so per-PR Cloud
  # Run previews can deploy. Prod keeps the tight push-to-main-only
  # condition. Workflow-level guards
  # (head.repo.full_name == github.repository) still prevent fork-
  # originated previews from acquiring this token.
  attribute_condition = var.browser_wif_allow_pull_requests ? "assertion.repository == \"${var.github_repo}\" && (assertion.ref == \"${var.browser_wif_branch_ref}\" || assertion.event_name == \"pull_request\")" : "assertion.repository == \"${var.github_repo}\" && assertion.ref == \"${var.browser_wif_branch_ref}\""

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

resource "google_project_iam_member" "tf_deployer_artifactregistry_admin" {
  # `admin` (vs `reader`) is required so terraform can read and modify IAM
  # policy on individual AR repositories (e.g. the `gcr.io` repo's
  # `createOnPushWriter` binding for the browser deployer). Observed:
  # push-to-develop applies failing on
  # `artifactregistry.repositories.getIamPolicy denied`.
  project = var.gcp_project_id
  role    = "roles/artifactregistry.admin"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

resource "google_project_iam_member" "tf_deployer_wif_admin" {
  project = var.gcp_project_id
  role    = "roles/iam.workloadIdentityPoolAdmin"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# Needed so terraform plan can read `google_project_service` state (which APIs
# are enabled) and apply changes to enablement.
resource "google_project_iam_member" "tf_deployer_serviceusage_admin" {
  project = var.gcp_project_id
  role    = "roles/serviceusage.serviceUsageAdmin"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# Cross-project state bucket access: dev CI uses the prod-hosted state bucket.
# This runs only in the env whose project owns the bucket (prod) and grants
# other envs' tf-deployer SAs read/write on it.
resource "google_storage_bucket_iam_member" "cross_env_tf_deployer_state_access" {
  for_each = toset(var.cross_env_tf_deployer_emails)
  bucket   = var.terraform_state_bucket
  role     = "roles/storage.objectAdmin"
  member   = "serviceAccount:${each.value}"
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

# WIF provider for the Terraform repo. Accepts both push-to-wif_branch_ref
# (applies) and any pull_request event from the terraform repo (plans). The
# workflow is specifically designed around `plan on PR` + `apply on push`;
# rejecting PR tokens here leaves the plan step permanently broken.
resource "google_iam_workload_identity_pool_provider" "github_terraform" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-terraform"
  display_name                       = "GitHub Terraform"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.event_name" = "assertion.event_name"
  }

  attribute_condition = "assertion.repository == \"${var.github_repo_terraform}\" && (assertion.ref == \"${var.wif_branch_ref}\" || assertion.event_name == \"pull_request\")"

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
# Preprocess Service — Python/FastAPI image preprocessing on Cloud Run
# ──────────────────────────────────────────────

# Enable Cloud Vision API (used by /process for DOCUMENT_TEXT_DETECTION)
resource "google_project_service" "vision_api" {
  project            = var.gcp_project_id
  service            = "vision.googleapis.com"
  disable_on_destroy = false
}

# Runtime SA — attached to the preprocess Cloud Run service
resource "google_service_account" "preprocess_runtime" {
  account_id   = "neonbinder-preprocess-runtime"
  display_name = "NeonBinder Preprocess Runtime"
  description  = "Runtime service account for the preprocess Cloud Run service"
}

# Deployer SA — used by GitHub Actions via WIF to deploy the preprocess service
resource "google_service_account" "preprocess_deployer" {
  account_id   = "neonbinder-preprocess-deployer"
  display_name = "NeonBinder Preprocess Deployer"
  description  = "Deployer service account for preprocess GitHub Actions CI/CD"
}

resource "google_project_iam_member" "preprocess_runtime_logging_writer" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.preprocess_runtime.email}"
}

# Runtime SA uses its own ADC for Vision API calls — no API key needed.
resource "google_cloud_run_service_iam_member" "preprocess_runtime_invoker" {
  location = google_cloud_run_service.neonbinder_preprocess.location
  service  = google_cloud_run_service.neonbinder_preprocess.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.preprocess_runtime.email}"
}

resource "google_project_iam_member" "preprocess_deployer_run_admin" {
  project = var.gcp_project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.preprocess_deployer.email}"
}

resource "google_project_iam_member" "preprocess_deployer_artifactregistry_writer" {
  project = var.gcp_project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.preprocess_deployer.email}"
}

# Deployer needs objectAdmin to push/pull Docker images via GCR's backing GCS.
resource "google_project_iam_member" "preprocess_deployer_storage_object_admin" {
  project = var.gcp_project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.preprocess_deployer.email}"
}

# createOnPushWriter lets the preprocess deployer push to a repo path that
# doesn't exist yet on first deploy.
resource "google_artifact_registry_repository_iam_member" "preprocess_deployer_create_on_push" {
  project    = var.gcp_project_id
  location   = google_artifact_registry_repository.gcr_io.location
  repository = google_artifact_registry_repository.gcr_io.name
  role       = "roles/artifactregistry.createOnPushWriter"
  member     = "serviceAccount:${google_service_account.preprocess_deployer.email}"
}

resource "google_service_account_iam_member" "preprocess_deployer_act_as_runtime" {
  service_account_id = google_service_account.preprocess_runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.preprocess_deployer.email}"
}

# Allow developers to impersonate the preprocess runtime SA (local dev parity)
resource "google_service_account_iam_member" "developer_impersonate_preprocess_runtime" {
  for_each           = toset(var.developer_emails)
  service_account_id = google_service_account.preprocess_runtime.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${each.value}"
}

# Preprocess service shares the internal-api-key (watcher sends the same header)
resource "google_secret_manager_secret_iam_member" "preprocess_runtime_api_key_access" {
  secret_id = google_secret_manager_secret.internal_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.preprocess_runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "preprocess_deployer_api_key_access" {
  secret_id = google_secret_manager_secret.internal_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.preprocess_deployer.email}"
}

# Dedicated Anthropic API key for the preprocess service.
# Secret VALUE must be populated out-of-band (gcloud secrets versions add) — Terraform only
# manages the secret resource and IAM so the key never appears in state/tfvars.
resource "google_secret_manager_secret" "anthropic_api_key" {
  secret_id = "anthropic-api-key"

  replication {
    auto {}
  }

  labels = var.common_labels
}

resource "google_secret_manager_secret_iam_member" "preprocess_runtime_anthropic_access" {
  secret_id = google_secret_manager_secret.anthropic_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.preprocess_runtime.email}"
}

# Cloud Run service — 4 CPU / 4Gi / concurrency=3 / max-instances=3 / scale-to-zero
resource "google_cloud_run_service" "neonbinder_preprocess" {
  name     = var.preprocess_service_name
  location = var.gcp_region

  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/minScale" = "0"
        "autoscaling.knative.dev/maxScale" = tostring(var.preprocess_max_instances)
      }
    }

    spec {
      container_concurrency = var.preprocess_container_concurrency
      timeout_seconds       = 300
      service_account_name  = google_service_account.preprocess_runtime.email

      containers {
        image = var.preprocess_image

        resources {
          limits = {
            cpu    = var.preprocess_cpu
            memory = var.preprocess_memory
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
          name = "ANTHROPIC_API_KEY"
          value_from {
            secret_key_ref {
              name = google_secret_manager_secret.anthropic_api_key.secret_id
              key  = "latest"
            }
          }
        }

        env {
          name  = "ENVIRONMENT"
          value = var.environment
        }

        env {
          name  = "GOOGLE_CLOUD_PROJECT"
          value = var.gcp_project_id
        }
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }

  depends_on = [google_project_service.vision_api]

  lifecycle {
    # See `neonbinder_browser.lifecycle`: the deploy workflow owns traffic.
    # The client-name/client-version annotations are auto-set by gcloud on
    # every deploy and show as drift on the next terraform plan; ignoring
    # only those specific keys keeps terraform in control of minScale/
    # maxScale but stops the churn.
    ignore_changes = [
      template[0].spec[0].containers[0].image,
      traffic,
      template[0].metadata[0].annotations["run.googleapis.com/client-name"],
      template[0].metadata[0].annotations["run.googleapis.com/client-version"],
      # Knative auto-sets a per-revision nonce label; terraform doesn't
      # manage any labels on this template, so ignore the whole map.
      template[0].metadata[0].labels,
    ]
  }
}

# Public access gated by INTERNAL_API_KEY header check inside the service,
# matching the browser service's pattern.
resource "google_cloud_run_service_iam_member" "preprocess_public_access" {
  location = google_cloud_run_service.neonbinder_preprocess.location
  service  = google_cloud_run_service.neonbinder_preprocess.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# WIF provider dedicated to the preprocess repo
resource "google_iam_workload_identity_pool_provider" "github_preprocess" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-preprocess"
  display_name                       = "GitHub Preprocess"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.event_name" = "assertion.event_name"
  }

  # Preprocess repo is trunk-based: `preprocess_wif_branch_ref` is
  # `refs/heads/main` in both envs. When preprocess_wif_allow_pull_requests
  # is true (dev), also accept pull_request OIDC tokens (ref ==
  # refs/pull/<N>/merge) so per-PR Cloud Run previews can deploy. Prod keeps
  # the tight push-to-main-only condition. Workflow-level guards
  # (head.repo.full_name == github.repository) still prevent fork-originated
  # previews from acquiring this token. Mirrors the browser provider above.
  attribute_condition = var.preprocess_wif_allow_pull_requests ? "assertion.repository == \"${var.github_repo_preprocess}\" && (assertion.ref == \"${var.preprocess_wif_branch_ref}\" || assertion.event_name == \"pull_request\")" : "assertion.repository == \"${var.github_repo_preprocess}\" && assertion.ref == \"${var.preprocess_wif_branch_ref}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow GitHub Actions (preprocess repo) to impersonate the preprocess deployer SA
resource "google_service_account_iam_member" "github_actions_wif_preprocess" {
  service_account_id = google_service_account.preprocess_deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${var.github_repo_preprocess}"
}

# Allow the terraform-deployer SA to act as the preprocess SAs during apply
resource "google_service_account_iam_member" "tf_deployer_act_as_preprocess_runtime" {
  service_account_id = google_service_account.preprocess_runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

resource "google_service_account_iam_member" "tf_deployer_act_as_preprocess_deployer" {
  service_account_id = google_service_account.preprocess_deployer.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.terraform_deployer.email}"
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

output "preprocess_runtime_service_account_email" {
  description = "Email of the preprocess runtime service account"
  value       = google_service_account.preprocess_runtime.email
}

output "preprocess_deployer_service_account_email" {
  description = "Email of the preprocess deployer service account (set as GCP_SA_PREPROCESS_DEPLOYER[_DEV] GitHub secret)"
  value       = google_service_account.preprocess_deployer.email
}

output "preprocess_cloud_run_url" {
  description = "URL of the deployed preprocess Cloud Run service"
  value       = google_cloud_run_service.neonbinder_preprocess.status[0].url
}

output "wif_provider_preprocess_name" {
  description = "Full resource name of the preprocess WIF provider (set as GCP_WIF_PROVIDER_PREPROCESS[_DEV] GitHub secret)"
  value       = google_iam_workload_identity_pool_provider.github_preprocess.name
}
