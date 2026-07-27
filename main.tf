terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
    # NEO-95: `google-beta` only, needed for `cleanup_policies` /
    # `cleanup_policy_dry_run` on google_artifact_registry_repository.gcr_io.
    # Verified against the actual provider source at v4.85.0 (the latest,
    # and last, 4.x release — there is no newer 4.x to pin to instead): the
    # GA `google` provider's resource_artifact_registry_repository.go has no
    # "cleanup" fields at all, while `google-beta`'s does. The feature was
    # never promoted out of beta within the 4.x line. Everything else in this
    # file stays on the GA `google` provider; only that one resource opts in
    # to `google-beta` via `provider = google-beta`. Auth/permissions are
    # identical to the GA provider (same credentials, same APIs) — this is
    # purely a schema-availability workaround, not a new trust boundary.
    google-beta = {
      source  = "hashicorp/google-beta"
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

# NEO-95: see required_providers comment above — used only by
# google_artifact_registry_repository.gcr_io for cleanup_policies support.
provider "google-beta" {
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
#
# NEO-95: dev's repo hit 107GB and was growing forever — every CI push (browser
# + preprocess services) adds a new commit-sha-tagged image that was never
# cleaned up. cleanup_policies below cap growth in both envs:
#   - "delete-old-untagged": untagged images (superseded manifests, failed
#     pushes) older than 14 days are deleted.
#   - "keep-recent-tagged": the most recent 15 tagged versions are always
#     retained, regardless of age — protects rollback candidates and any live
#     `pr-<N>` preview tags.
# Anything not matched by either policy (i.e. a tagged image older than the 15
# most recent) is left alone; there's no "delete old tagged" rule, since tags
# are the only durable pointer to a deployable image.
resource "google_artifact_registry_repository" "gcr_io" {
  provider               = google-beta
  project                = var.gcp_project_id
  location               = "us"
  repository_id          = "gcr.io"
  format                 = "DOCKER"
  description            = "Legacy gcr.io-compatible Docker image registry"
  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"

    condition {
      tag_state  = "UNTAGGED"
      older_than = "1209600s" # 14 days
    }
  }

  cleanup_policies {
    id     = "keep-recent-tagged"
    action = "KEEP"

    most_recent_versions {
      keep_count = 15
    }
  }
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

# NEO-20: the browser service no longer reads INTERNAL_API_KEY (auth moved
# to Cloud Run IAM). The secret itself is retained because the preprocess
# service still consumes it, but the browser runtime SA's accessor grant
# is gone.

# Deployer SA needs to read the API key secret (for post-deploy smoke tests
# of services that still use it — preprocess).
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
    metadata {
      annotations = {
        # minScale=1 keeps one warm Puppeteer-Chromium container alive at
        # all times. Without it, every cold call (BSC token fetch, marketplace
        # scrape) pays a 5–15s container boot, which cascades into the 60s+
        # variantType-sync test failures tracked in NEO-12. The tradeoff is
        # ~$10/mo per environment to keep one 4Gi/2CPU container warm.
        "autoscaling.knative.dev/minScale" = tostring(var.cloud_run_min_instances)
        "autoscaling.knative.dev/maxScale" = tostring(var.cloud_run_max_instances)
      }
    }

    spec {
      container_concurrency = var.cloud_run_container_concurrency

      containers {
        image = var.cloud_run_image

        resources {
          limits = {
            cpu    = var.cloud_run_cpu
            memory = var.cloud_run_memory
          }
        }

        # NEO-20: INTERNAL_API_KEY env var removed — authentication is
        # now enforced by Cloud Run IAM rather than an app-layer header
        # check inside the service.

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
    # The client-name/client-version annotations are auto-set by gcloud on
    # every deploy and show as drift on the next plan; ignoring only those
    # specific keys keeps terraform in control of minScale/maxScale but
    # stops the churn (mirrors the preprocess service's pattern below).
    ignore_changes = [
      template[0].spec[0].containers[0].image,
      traffic,
      template[0].metadata[0].annotations["run.googleapis.com/client-name"],
      template[0].metadata[0].annotations["run.googleapis.com/client-version"],
      # Knative auto-sets a per-revision nonce label; terraform doesn't
      # manage any labels on this template, so ignore the whole map.
      template[0].metadata[0].labels,
      # The deploy workflow (gcloud run deploy) re-asserts these on every
      # push and normalizes the cpu format from "2000m" → "2". Without
      # ignoring them, every terraform apply attempts to flip them back
      # and Cloud Run rejects the resulting revision update with 409
      # ("Revision named <NNN-XXX> with different configuration already
      # exists"). The cloudbuild workflow is the source of truth for these
      # values — terraform should not race the deploy.
      template[0].spec[0].containers[0].resources,
      template[0].metadata[0].annotations["autoscaling.knative.dev/minScale"],
      template[0].metadata[0].annotations["autoscaling.knative.dev/maxScale"],
      # NEO-20: the live container still carries the now-unused
      # INTERNAL_API_KEY env binding (the deploy workflow propagates it on
      # every revision via the previous main.tf). Code in the browser
      # service no longer reads the value; it is dead weight. Removing it
      # via terraform triggers the same 409 revision-naming conflict as
      # other in-place spec edits, so we let it bleed out of live state
      # naturally on the next deploy that doesn't re-add it. Ignore env
      # changes here so future plans stay quiet.
      template[0].spec[0].containers[0].env,
      # Prod's live container_concurrency drifted to 80 (set externally at
      # some point); terraform code says 3 (var default). Any attempt to
      # flip it triggers the same 409 revision-naming conflict on a
      # spec-update. Ignore so plans/applies stay clean. Effective
      # concurrency is whatever the live revision has — to re-set it
      # explicitly, run gcloud run services update --concurrency=N out of
      # band and update the var if you want terraform code to reflect it.
      template[0].spec[0].container_concurrency,
    ]
  }
}

# NEO-20: allUsers invoker removed. Authentication is now enforced solely
# by Cloud Run IAM, with the neonbinder-convex SA holding the invoker role
# (resource below). The Convex web layer authenticates by minting a Google
# OIDC ID token whose audience equals this Cloud Run service URL; anything
# anonymous is rejected at the Cloud Run edge with 403 before reaching
# Express. The browser PR's cloudbuild deploy stripped allUsers from the
# live IAM via `--no-allow-unauthenticated`; this PR brings terraform state
# in line so future plans don't try to re-add it.
resource "google_cloud_run_service_iam_member" "convex_invoker" {
  location = google_cloud_run_service.neonbinder_browser.location
  service  = google_cloud_run_service.neonbinder_browser.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.convex.email}"
}

# NEO-20 follow-up: the CI deploy gate's login-probe jobs (in
# neonbinder_browser/.github/workflows/browser-deploy.yml) call the freshly
# deployed-but-not-yet-promoted tagged revision over HTTP before shifting
# traffic. Since #31 removed the app-layer x-internal-key check, those probes
# must present a Google OIDC ID token, and the identity behind that token
# needs roles/run.invoker on the service or Cloud Run rejects it with 403.
# The probes authenticate as the deployer SA (via WIF), so the deployer needs
# the invoker role here — same scoped pattern as runtime_invoker/convex_invoker,
# NOT a broad project grant. run.admin (granted elsewhere) covers *managing*
# the service but does not by itself satisfy the per-service invoke check.
resource "google_cloud_run_service_iam_member" "deployer_invoker" {
  location = google_cloud_run_service.neonbinder_browser.location
  service  = google_cloud_run_service.neonbinder_browser.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.deployer.email}"
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
  # NEO-18 cutover: the old neonbinder_browser repo is archived; the
  # consolidated monorepo is now the sole trusted repo.
  attribute_condition = var.browser_wif_allow_pull_requests ? "assertion.repository == \"${var.github_repo_monorepo}\" && (assertion.ref == \"${var.browser_wif_branch_ref}\" || assertion.event_name == \"pull_request\")" : "assertion.repository == \"${var.github_repo_monorepo}\" && assertion.ref == \"${var.browser_wif_branch_ref}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow GitHub Actions (consolidated monorepo) to impersonate the deployer SA
# (not the runtime SA). NEO-18 cutover: the old neonbinder_browser repo's
# equivalent binding was removed once that repo was archived.
resource "google_service_account_iam_member" "github_actions_wif_monorepo" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${var.github_repo_monorepo}"
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

# NEO-95: prod apply of google_bigquery_dataset.billing_export failed with
# "Access Denied: ... does not have bigquery.datasets.create permission" —
# unlike the other tf_deployer_*_admin grants above, BigQuery was never
# needed here before. dataEditor (not the broader bigquery.admin) is enough
# for dataset create/manage; it doesn't grant job/model/routine admin.
resource "google_project_iam_member" "tf_deployer_bigquery_data_editor" {
  project = var.gcp_project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# Needed so terraform plan can read `google_project_service` state (which APIs
# are enabled) and apply changes to enablement.
resource "google_project_iam_member" "tf_deployer_serviceusage_admin" {
  project = var.gcp_project_id
  role    = "roles/serviceusage.serviceUsageAdmin"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# ──────────────────────────────────────────────
# Browser login alerting — IAM + APIs (NEO-43)
# ──────────────────────────────────────────────
#
# These four grants and two API enablements ship in their OWN PR, ahead of the
# alert policies / log metrics / scheduler jobs that need them. That split is
# deliberate and is the direct lesson of NEO-95: the prod apply that created
# google_bigquery_dataset.billing_export failed on a missing permission granted
# in the SAME apply (see tf_deployer_bigquery_data_editor above), and needed a
# follow-up commit. `depends_on` fixes graph ordering but NOT project-IAM
# propagation delay, which is measured in minutes. Two applies is the only
# reliable fix.
#
# All are count-gated on the same prod-only flag as the resources they enable,
# so the dev tf-deployer's permissions are unchanged by this ticket.

resource "google_project_iam_member" "tf_deployer_monitoring_alert_editor" {
  count   = var.enable_browser_login_alerts ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/monitoring.alertPolicyEditor"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# Separate from alertPolicyEditor on purpose: that role cannot create
# notification channels, and roles/monitoring.editor (which covers both) also
# grants uptime checks, metric descriptors, groups, services and dashboards —
# strictly more than this ticket needs.
resource "google_project_iam_member" "tf_deployer_monitoring_channel_editor" {
  count   = var.enable_browser_login_alerts ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/monitoring.notificationChannelEditor"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# SECURITY NOTE — this is the widest grant in this ticket; disclosing it here
# per .claude/agent-memory/security-auditor/terraform_iam_findings.md.
#
# roles/logging.configWriter is the ONLY predefined role that contains
# logging.logMetrics.create/update/delete. There is no logMetricEditor role.
# It also permits creating/modifying log SINKS, EXCLUSIONS, BUCKETS and VIEWS,
# which is both exfiltration-relevant (a sink can route logs to an
# attacker-controlled destination) and availability-relevant (an exclusion can
# silently blackhole the very logs these alerts read).
#
# A custom role scoped to logMetrics.* would be genuinely narrower, but
# creating one requires granting the tf-deployer roles/iam.roleAdmin
# (iam.roles.create) — a LARGER escalation that also reintroduces the same
# bootstrap-ordering problem one layer up. Rejected on net risk.
#
# Mitigations: (a) this SA is only assumable via Workload Identity Federation
# from this repo on the configured branch ref (see the WIF block below);
# (b) google_project_iam_audit_config.iam_audit records admin activity;
# (c) count-gated, so dev never receives it.
resource "google_project_iam_member" "tf_deployer_logging_config_writer" {
  count   = var.enable_browser_login_alerts ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/logging.configWriter"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# For the NEO-43 synthetic login canary (Cloud Scheduler jobs). `admin` rather
# than `editor` is the narrowest role that can create/update/delete jobs.
resource "google_project_iam_member" "tf_deployer_cloudscheduler_admin" {
  count   = var.enable_browser_login_alerts ? 1 : 0
  project = var.gcp_project_id
  role    = "roles/cloudscheduler.admin"
  member  = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# Monitoring is on by default for most GCP projects, but nothing in this repo
# guaranteed it — and an alert policy apply against a disabled API fails in a
# way that reads like a permissions problem. Declare it explicitly.
#
# logging.googleapis.com is deliberately NOT declared: it is always-on and
# cannot be disabled, so a google_project_service for it is pure noise.
resource "google_project_service" "monitoring_api" {
  count              = var.enable_browser_login_alerts ? 1 : 0
  project            = var.gcp_project_id
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudscheduler_api" {
  count              = var.enable_browser_login_alerts ? 1 : 0
  project            = var.gcp_project_id
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
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
# Preprocess test-fixture bucket — dev only
# ──────────────────────────────────────────────
# Home for the real-card integration-test fixtures that are too large to
# commit to git (phone-camera shots at 22-26 MB each). Only the YAML
# expectation sidecars live in the preprocess repo; images live here and
# are fetched on demand via `scripts/fetch_fixtures.py`. No prod mirror:
# these are test data that dev services consume during integration runs.

resource "google_storage_bucket" "preprocess_fixtures" {
  count    = var.create_preprocess_fixtures_bucket ? 1 : 0
  name     = "neonbinder-dev-preprocess-fixtures"
  location = var.gcp_region

  uniform_bucket_level_access = true

  versioning {
    # Keep a history of fixture versions so a test regression can be traced
    # to an image replacement.
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      # Prune old non-current versions at 1 year; live objects retained forever.
      age                = 365
      with_state         = "ARCHIVED"
      num_newer_versions = 3
    }
  }

  labels = var.common_labels
}

# Developers upload + fetch fixtures. objectAdmin gives read/write/delete.
resource "google_storage_bucket_iam_member" "preprocess_fixtures_developer_admin" {
  for_each = var.create_preprocess_fixtures_bucket ? toset(var.developer_emails) : toset([])
  bucket   = google_storage_bucket.preprocess_fixtures[0].name
  role     = "roles/storage.objectAdmin"
  member   = "user:${each.value}"
}

# Preprocess runtime + deployer SAs can read fixtures so a future CI
# integration-test job can fetch them before running pytest tests/integration.
resource "google_storage_bucket_iam_member" "preprocess_fixtures_runtime_reader" {
  count  = var.create_preprocess_fixtures_bucket ? 1 : 0
  bucket = google_storage_bucket.preprocess_fixtures[0].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.preprocess_runtime.email}"
}

resource "google_storage_bucket_iam_member" "preprocess_fixtures_deployer_reader" {
  count  = var.create_preprocess_fixtures_bucket ? 1 : 0
  bucket = google_storage_bucket.preprocess_fixtures[0].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.preprocess_deployer.email}"
}

# ──────────────────────────────────────────────
# Billing Budget / Cost Alerts (NEO-95)
# ──────────────────────────────────────────────
# There was no billing budget or spend alert at all on the "Neon Binder
# Billing" account (01C86C-DBCAE6-406609) — confirmed via
# `gcloud billing budgets list --billing-account=01C86C-DBCAE6-406609`
# returning zero results, and the Billing Budget API not yet enabled.
#
# google_billing_budget is scoped to the BILLING ACCOUNT, not a project, so
# it must only be created once — this whole section is gated behind
# var.enable_billing_budget, which is only true in environments/prod.tfvars.
# It still covers spend across BOTH projects on this billing account via
# budget_filter.projects (there are only two: neonbinder + neonbinder-dev).

# Required to call the Budgets API at all; enabled on whichever project
# performs the apply (prod, since that's the only apply with the flag on).
resource "google_project_service" "billingbudgets_api" {
  count              = var.enable_billing_budget ? 1 : 0
  project            = var.gcp_project_id
  service            = "billingbudgets.googleapis.com"
  disable_on_destroy = false
}

resource "google_billing_budget" "gcp_spend" {
  count           = var.enable_billing_budget ? 1 : 0
  billing_account = "01C86C-DBCAE6-406609"
  display_name    = "NeonBinder monthly GCP spend"

  budget_filter {
    # Only projects on this billing account today; scoping explicitly rather
    # than leaving unfiltered so a future third project doesn't silently
    # start contributing to (or diluting) these alerts.
    projects = [
      "projects/117170654588", # neonbinder (prod)
      "projects/339836466983", # neonbinder-dev (dev)
    ]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = "500"
    }
  }

  # Actual-spend thresholds at 20/50/80/100% of the $500/mo budget amount.
  threshold_rules {
    threshold_percent = 0.2
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 0.8
    spend_basis       = "CURRENT_SPEND"
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  # No all_updates_rule / pubsub_topic wired up: with no notification channels
  # or pubsub topic configured, GCP falls back to emailing the billing
  # account's Billing Admins/Users — sufficient for now. Revisit if we want
  # Slack/PagerDuty routing later.

  depends_on = [google_project_service.billingbudgets_api]
}

# ──────────────────────────────────────────────
# Billing Export destination dataset (NEO-95)
# ──────────────────────────────────────────────
# GCP's "Billing export to BigQuery" toggle (Billing console → Billing export)
# has no Terraform resource — it can only be wired up manually in the console.
# But the BigQuery dataset it exports *into* is an ordinary project resource,
# so that part is created here. Gated behind the same var.enable_billing_budget
# flag (true only in environments/prod.tfvars) since, like the budget, this
# only needs to exist once for the whole billing account, and prod is where
# billing-account-level resources for NEO-95 live.
#
# No expiration is set on the dataset or its tables — billing export data
# must never auto-delete.
resource "google_bigquery_dataset" "billing_export" {
  count       = var.enable_billing_budget ? 1 : 0
  project     = var.gcp_project_id
  dataset_id  = "billing_export"
  location    = "US"
  description = "Destination for GCP detailed billing export (NEO-95) — wired up manually in the Billing console, this dataset is just the target."

  depends_on = [google_project_iam_member.tf_deployer_bigquery_data_editor]
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

