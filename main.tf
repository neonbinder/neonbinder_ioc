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
# Browser login alerting — resources (NEO-43)
# ──────────────────────────────────────────────
#
# Alerts on marketplace (SportLots / BSC) login failures and HANGS on the
# browser service. Prod only, count-gated; the IAM and API enablement these
# depend on shipped in a prior PR (see the "IAM + APIs" section above) so the
# grants have propagated before anything here is created.
#
# Three design constraints drove this, all verified against the running code
# rather than taken from the ticket, which predates the BSC/SportLots
# browser-free HTTP conversion:
#
#   1. HANGS EMIT NO LOG LINE. logBrowserOp (services/browser/src/
#      observability.ts) writes its line only when the handler RETURNS. There
#      is no server-side timeout on the login path, so a wedged upstream fetch
#      holds the request open until Cloud Run kills it — and no
#      browser_login_call entry is ever written. A metric on success=false
#      therefore catches 100% of failures and 0% of hangs. Hangs are caught
#      instead by the Cloud Run *request* log (browser_login_http_status).
#
#   2. A BAD BSC PASSWORD RETURNS HTTP 500, while the equivalent SportLots
#      failure returns HTTP 400 (services/browser/src/index.ts). So the
#      ticket's proposed "elevated 5xx rate on /login/*" policy would page on
#      ordinary seller typos AND miss every SportLots failure. 500 is
#      excluded from the hang policy for exactly this reason.
#
#   3. run.googleapis.com/request_count HAS NO PATH LABEL — its labels are
#      response_code / response_code_class plus the cloud_run_revision
#      resource labels. Since this service also serves /health, /sites and
#      the /credentials/* CRUD routes, any built-in-metric policy is a
#      service-wide aggregate in which two slow logins a day are invisible.
#      That is why all four policies below are built on log-based metrics.
#
# Cost: log-based metrics over already-ingested logs, alert policies and
# email channels are all free. Only the canary's Cloud Run time is billable
# (~$3/mo) — relevant given NEO-95's cost posture.

resource "google_monitoring_notification_channel" "ops_email" {
  count        = var.enable_browser_login_alerts ? 1 : 0
  project      = var.gcp_project_id
  display_name = "NeonBinder ops email"
  type         = "email"
  description  = "NEO-43: operator mailbox for browser-service marketplace login alerts."

  labels = {
    email_address = var.alert_notification_email
  }

  # Unlike NEO-95's budget — which deliberately shipped with no channel and
  # falls back to emailing the billing account's admins — an alert policy has
  # NO fallback. A policy with no channel opens an incident that nobody ever
  # sees. force_delete=false makes Terraform refuse to delete a channel that
  # policies still reference rather than silently orphaning them into that
  # no-notification state.
  force_delete = false

  user_labels = merge(var.common_labels, { ticket = "neo-43" })

  depends_on = [
    google_project_iam_member.tf_deployer_monitoring_channel_editor,
    google_project_service.monitoring_api,
  ]
}

# --- Log-based metrics ------------------------------------------------------

# Counts browser_login_call lines with success=false. Catches every FAILURE
# the service actually returned; blind to hangs by construction (see note 1).
#
# Deliberately NOT pinned to logName=".../run.googleapis.com%2Fstdout": if the
# service ever switches to a logging library that writes elsewhere, a logName
# pin would silently drop this metric to zero — and a monitoring rule that
# silently reads zero is worse than no rule at all.
resource "google_logging_metric" "browser_login_failures" {
  count   = var.enable_browser_login_alerts ? 1 : 0
  project = var.gcp_project_id
  name    = "browser_login_failures"

  filter = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${var.cloud_run_service_name}"
    jsonPayload.msg="browser_login_call"
    jsonPayload.success=false
  EOT

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Browser marketplace login failures"

    labels {
      key         = "platform"
      value_type  = "STRING"
      description = "bsc | sportlots"
    }
    labels {
      key         = "error_class"
      value_type  = "STRING"
      description = "bad_key_format | timeout | invalid_credentials | challenge | oom | other | missing_key; empty when the service could not classify"
    }
    labels {
      key         = "challenge_detected"
      value_type  = "STRING"
      description = "true when the marketplace served a captcha/block page rather than authenticating — distinguishes 'they are blocking us' from 'the seller mistyped their password'"
    }
    labels {
      key         = "canary"
      value_type  = "STRING"
      description = "true for the synthetic Cloud Scheduler probe, false for real seller traffic"
    }
  }

  label_extractors = {
    "platform"           = "EXTRACT(jsonPayload.platform)"
    "error_class"        = "EXTRACT(jsonPayload.error_class)"
    "challenge_detected" = "EXTRACT(jsonPayload.challenge_detected)"
    "canary"             = "EXTRACT(jsonPayload.canary)"
  }

  depends_on = [google_project_iam_member.tf_deployer_logging_config_writer]
}

# Duration distribution for COMPLETED logins. Feeds the "slow but not yet
# hung" policy.
#
# Uses jsonPayload.duration_ms (measured from handler entry) rather than
# run.googleapis.com/request_latencies, which INCLUDES container startup.
# With min-instances=0 (NEO-95 cost control) the canary mostly runs cold and
# would otherwise dominate the service's p95 with pure cold-start time.
resource "google_logging_metric" "browser_login_duration_ms" {
  count   = var.enable_browser_login_alerts ? 1 : 0
  project = var.gcp_project_id
  name    = "browser_login_duration_ms"

  filter = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${var.cloud_run_service_name}"
    jsonPayload.msg="browser_login_call"
  EOT

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "DISTRIBUTION"
    unit         = "ms"
    display_name = "Browser marketplace login duration"

    labels {
      key         = "platform"
      value_type  = "STRING"
      description = "bsc | sportlots"
    }
    labels {
      key         = "canary"
      value_type  = "STRING"
      description = "true for the synthetic probe, false for real seller traffic"
    }
  }

  value_extractor = "EXTRACT(jsonPayload.duration_ms)"

  label_extractors = {
    "platform" = "EXTRACT(jsonPayload.platform)"
    "canary"   = "EXTRACT(jsonPayload.canary)"
  }

  # 100ms .. 100 * 1.25^40 ≈ 752s at ~25% granularity per bucket. Fine enough
  # that a p99 near the 45s threshold is accurate to ~±11s, wide enough to
  # still bucket a request that ran to Cloud Run's 300s default timeout.
  bucket_options {
    exponential_buckets {
      num_finite_buckets = 40
      growth_factor      = 1.25
      scale              = 100
    }
  }

  depends_on = [google_project_iam_member.tf_deployer_logging_config_writer]
}

# THE HANG DETECTOR. The only path-scoped source that can see a request the
# application never completed, because Cloud Run's *request* log records
# requestUrl/status/latency independently of anything the app writes:
#   499 — Convex aborted at its 60s AbortSignal (the seller saw a spinner,
#         then an error)
#   504 — Cloud Run's own request timeout (300s default; not set by terraform
#         and not set by the deploy workflow's gcloud flags)
#   503 — container died / overload mid-request
#
# Unlike the two metrics above, pinning logName IS correct here: request logs
# are emitted by Cloud Run infrastructure, not by the app, so the log stream
# cannot move under us.
resource "google_logging_metric" "browser_login_http_status" {
  count   = var.enable_browser_login_alerts ? 1 : 0
  project = var.gcp_project_id
  name    = "browser_login_http_status"

  filter = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${var.cloud_run_service_name}"
    logName="projects/${var.gcp_project_id}/logs/run.googleapis.com%2Frequests"
    httpRequest.requestUrl=~"/login/(bsc|sportlots)$"
    httpRequest.status>=499
  EOT

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Browser login request failures (Cloud Run edge)"

    labels {
      key         = "status"
      value_type  = "STRING"
      description = "499 client-cancelled | 502/503 infra | 504 request timeout | 500 app error"
    }
    labels {
      key         = "path"
      value_type  = "STRING"
      description = "/login/bsc | /login/sportlots"
    }
  }

  label_extractors = {
    "status" = "EXTRACT(httpRequest.status)"
    "path"   = "REGEXP_EXTRACT(httpRequest.requestUrl, \"(/login/[a-z]+)\")"
  }

  depends_on = [google_project_iam_member.tf_deployer_logging_config_writer]
}

# --- Runbook ----------------------------------------------------------------
#
# NOTE ON ESCAPING: Cloud Monitoring's own documentation-variable syntax
# (${metric.label.platform}) collides with Terraform interpolation, so every
# Monitoring variable below is written $${...}. Unescaped, the apply fails
# with "There is no variable named metric".

locals {
  neo43_runbook_common = <<-EOT
    ## Where to look

    **1. Structured login logs** — what the service thought happened.
    Logs Explorer, project `${var.gcp_project_id}`:

    ```
    resource.type="cloud_run_revision"
    resource.labels.service_name="${var.cloud_run_service_name}"
    jsonPayload.msg="browser_login_call"
    ```

    Fields: `platform`, `operation`, `duration_ms`, `success`, `status_code`,
    `error_class`, `challenge_detected`, `canary`.

    **A HANG EMITS NO LINE AT ALL.** If an alert fired and there is no matching
    entry, that absence IS the finding — go to (2).

    **2. Cloud Run request log** — the only place a hang is visible:

    ```
    resource.type="cloud_run_revision"
    resource.labels.service_name="${var.cloud_run_service_name}"
    logName="projects/${var.gcp_project_id}/logs/run.googleapis.com%2Frequests"
    httpRequest.requestUrl=~"/login/"
    ```

    499 = Convex gave up at 60s. 504 = Cloud Run request timeout. 503 =
    container died.

    **3. PostHog** — events `credential_test_failed` / `credential_test_succeeded`
    from apps/web/convex/credentials.ts. Filter by `platform`. NOTE the naming
    mismatch: PostHog uses `buysportscards`, the browser service uses `bsc`.
    PostHog carries the sanitized diagnostic (`challengeDetected`, url,
    snippet) — the only place you can see WHAT page the marketplace served.

    ## Check these before escalating

    - **`challenge_detected=true` or `error_class="challenge"`** — the
      marketplace is blocking us, not a credential problem. If the canary is
      running, PAUSE IT FIRST (see below) before debugging, or you will dig
      the hole deeper.
    - **Did a push to `main` just happen?** `prod-login-probe` performs a real
      BSC + SportLots login against a cold, freshly deployed revision on every
      deploy. Correlate the alert time with the latest deploy.
    - **Cold start.** min-instances=0 is intentional (NEO-95 cost control), so
      the first login after an idle period is always the slowest.

    ## Act

    - Marketplace-side outage: nothing to deploy. Note it on the ticket.
    - Our regression: `gcloud run services update-traffic ${var.cloud_run_service_name}
      --region=${var.gcp_region} --project=${var.gcp_project_id} --to-revisions=<previous>=100`
    - Pause the canary: set `login_canary_paused = true` in
      environments/prod.tfvars and merge. Break-glass is
      `gcloud scheduler jobs pause` — but the NEXT APPLY REVERTS IT, so always
      follow up with the tfvars change.
    - Silence this alert: `enable_browser_login_alerts` in prod.tfvars. Never
      by editing in the console — the next apply reverts console edits.
  EOT

  neo43_doc_failures = <<-EOT
    # Marketplace login failures — $${metric.label.platform}

    3+ login failures in 5 minutes on **$${metric.label.platform}**, excluding
    caller-side errors (invalid_credentials, bad_key_format, missing_key). A
    seller is very likely stuck right now.

    First: read `error_class` on the failing lines. `timeout` -> marketplace
    slow or wedged. `challenge` -> captcha/bot check. `oom` -> container
    memory. `other` -> read the raw message, it matched no known pattern.

    ${local.neo43_runbook_common}
  EOT

  neo43_doc_hang = <<-EOT
    # Login request died at the Cloud Run edge — $${metric.label.path}

    Status **$${metric.label.status}** on `$${metric.label.path}`: a login
    request terminated without the application ever returning.

    499 means Convex's 60s abort fired — the seller saw a failure. There will
    be NO browser_login_call log line for this request; that absence is the
    diagnosis. Check whether the upstream marketplace is reachable at all.

    500 is deliberately NOT part of this policy: an ordinary BSC credential
    rejection returns 500 (SportLots returns 400 for the same case), so
    including it would page on seller typos. Real application failures are
    covered by the login-failures policy with a far better error taxonomy.

    ${local.neo43_runbook_common}
  EOT

  neo43_doc_latency = <<-EOT
    # Login latency degrading — $${metric.label.platform}

    p99 login duration on **$${metric.label.platform}** exceeded
    ${var.browser_login_latency_threshold_ms}ms over 10 minutes. Convex hard-aborts at
    60s, so logins are close to failing outright.

    Baseline for comparison: BSC fresh ~4.4s, BSC cached-token ~1.1s,
    SportLots plus its retry budget up to ~12s. A cold start on the ~1GB image
    adds several seconds on top.

    ${local.neo43_runbook_common}
  EOT

  neo43_doc_canary_absent = <<-EOT
    # Login canary has stopped reporting

    No synthetic login probe has completed for 90 minutes (3 missed runs).

    This is the ABSENCE detector, and it is the one alert that fires when the
    service is hung rather than erroring — a hung login writes no log line, so
    the only symptom is silence. Either the browser service is wedged, the
    Cloud Scheduler jobs are paused/deleted, or the canary's credentials or
    Secret Manager access broke.

    Check, in order:
    1. `gcloud scheduler jobs list --location=${var.gcp_region} --project=${var.gcp_project_id}`
       — are the jobs present and ENABLED (not PAUSED)?
    2. The Scheduler job's own error log:
       `resource.type="cloud_scheduler_job"` — an attempt abandoned at the
       180s deadline is recorded here even when the service logs nothing.
    3. Whether anyone paused the canary during an incident and forgot to
       re-enable it.

    ${local.neo43_runbook_common}
  EOT
}

# --- Alert policies ---------------------------------------------------------
#
# Shared conventions across all four, each load-bearing at this traffic level:
#
#   evaluation_missing_data = INACTIVE — the provider default leaves a
#     condition in its LAST state when data stops. With sparse login traffic
#     that means an incident opened at 09:00 can stay open indefinitely once
#     nobody logs in, and cannot cleanly re-fire. "No data" must read as "not
#     violating", i.e. "nobody attempted a login".
#
#   auto_close = 1800s — the API minimum. These are burst counters over sparse
#     traffic; an incident that is not closed quickly is still open when the
#     next unrelated failure arrives, and that second failure then produces NO
#     new email.
#
#   duration = "0s" + trigger.count = 1 — never require N CONSECUTIVE
#     violating windows. The second window may have no data at all, so a
#     duration-based condition could sit un-fired straight through an outage.
#
#   notification_rate_limit = 3600s — caps a sustained outage at one email an
#     hour per policy.
#
# Deliberately NOT built: any ratio/rate condition. At single-digit daily
# logins, "50% error rate" is one failed login and the ratio is undefined for
# most windows. Absolute counts only.

resource "google_monitoring_alert_policy" "browser_login_failures" {
  count        = var.enable_browser_login_alerts ? 1 : 0
  project      = var.gcp_project_id
  display_name = "browser-service: marketplace login failures (NEO-43)"
  combiner     = "OR"

  conditions {
    display_name = "3+ non-user-error login failures in 5m (per platform)"

    condition_threshold {
      # The error_class exclusions are what make this alert survivable.
      # invalid_credentials / bad_key_format / missing_key are all CALLER
      # errors — a seller mistyped a password, or Convex sent a malformed
      # key. Paging on those would make this alert ignored within a week.
      # Everything else — timeout, challenge, oom, other, and the empty
      # string the service yields when it cannot classify — is a genuine
      # "the marketplace or our service is broken" signal.
      filter = join(" AND ", [
        # Interpolated rather than hardcoded so Terraform knows this policy
        # DEPENDS ON the metric. Without that edge it may create the policy
        # first, and Cloud Monitoring happily accepts a filter naming a
        # metric type that does not exist yet — producing a policy that never
        # matches anything and reports healthy forever.
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.browser_login_failures[0].name}\"",
        "resource.type=\"cloud_run_revision\"",
        "metric.label.error_class!=\"invalid_credentials\"",
        "metric.label.error_class!=\"bad_key_format\"",
        "metric.label.error_class!=\"missing_key\"",
      ])

      comparison      = "COMPARISON_GT"
      threshold_value = 2
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        # Per-platform: BSC and SportLots break independently — the incident
        # that prompted NEO-43 was SportLots hanging while BSC was healthy. A
        # summed threshold would need to be lower and would then double-fire.
        group_by_fields = ["metric.label.platform"]
      }

      trigger {
        count = 1
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = [google_monitoring_notification_channel.ops_email[0].id]

  alert_strategy {
    auto_close = "1800s"

    notification_rate_limit {
      period = "3600s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = local.neo43_doc_failures
  }

  user_labels = merge(var.common_labels, { ticket = "neo-43" })

  depends_on = [google_project_iam_member.tf_deployer_monitoring_alert_editor]
}

resource "google_monitoring_alert_policy" "browser_login_hang" {
  count        = var.enable_browser_login_alerts ? 1 : 0
  project      = var.gcp_project_id
  display_name = "browser-service: login hang / edge failure (NEO-43)"
  combiner     = "OR"

  conditions {
    display_name = "Any 499/502/503/504 on a /login/* request in 5m"

    condition_threshold {
      filter = join(" AND ", [
        # Interpolated so Terraform creates the metric first — see the note on
        # the failures policy above.
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.browser_login_http_status[0].name}\"",
        "resource.type=\"cloud_run_revision\"",
        # 500 EXCLUDED — see the note at the top of this section: an ordinary
        # BSC credential rejection is a 500. None of 499/502/503/504 can be
        # produced by user input.
        "metric.label.status=monitoring.regex.full_match(\"499|502|503|504\")",
      ])

      comparison = "COMPARISON_GT"
      # Zero legitimate baseline — every one of these is the NEO-43 incident,
      # and at this volume it will be quiet for weeks at a time.
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.path", "metric.label.status"]
      }

      trigger {
        count = 1
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = [google_monitoring_notification_channel.ops_email[0].id]

  alert_strategy {
    auto_close = "1800s"

    notification_rate_limit {
      period = "3600s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = local.neo43_doc_hang
  }

  user_labels = merge(var.common_labels, { ticket = "neo-43" })

  depends_on = [google_project_iam_member.tf_deployer_monitoring_alert_editor]
}

resource "google_monitoring_alert_policy" "browser_login_latency" {
  count        = var.enable_browser_login_alerts ? 1 : 0
  project      = var.gcp_project_id
  display_name = "browser-service: login latency degradation (NEO-43)"
  combiner     = "OR"

  conditions {
    display_name = "p99 login duration > threshold over 10m (per platform)"

    condition_threshold {
      filter = join(" AND ", [
        # Interpolated so Terraform creates the metric first — see the note on
        # the failures policy above.
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.browser_login_duration_ms[0].name}\"",
        "resource.type=\"cloud_run_revision\"",
      ])

      comparison      = "COMPARISON_GT"
      threshold_value = var.browser_login_latency_threshold_ms
      duration        = "0s"

      aggregations {
        # 10m (vs 5m elsewhere) because this is a trend signal, not an
        # incident signal.
        alignment_period = "600s"
        # ALIGN_PERCENTILE_99 precisely BECAUSE volume is low: with 1-3
        # samples in the window, p99 degenerates to "the slowest login in the
        # window", which is exactly the semantic wanted. (ALIGN_MAX is not
        # valid for DISTRIBUTION-valued metrics.)
        per_series_aligner   = "ALIGN_PERCENTILE_99"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["metric.label.platform"]
      }

      trigger {
        count = 1
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = [google_monitoring_notification_channel.ops_email[0].id]

  alert_strategy {
    auto_close = "1800s"

    notification_rate_limit {
      period = "3600s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = local.neo43_doc_latency
  }

  user_labels = merge(var.common_labels, { ticket = "neo-43" })

  depends_on = [google_project_iam_member.tf_deployer_monitoring_alert_editor]
}

# The absence detector. This is the policy that fires when the service is HUNG
# rather than erroring — and it is only meaningful because the canary
# guarantees a heartbeat. Without a synthetic probe, "no login logs" is
# indistinguishable from "no sellers logged in today".
resource "google_monitoring_alert_policy" "browser_login_canary_absent" {
  # Gated on the canary being ENABLED AND NOT PAUSED. A paused canary emits
  # nothing by design, so creating this policy alongside a paused canary would
  # guarantee a false alarm one window later — the monitoring causing the
  # incident. It also means the documented "pause the canary" incident
  # response does not itself page you an hour afterwards.
  count        = var.enable_browser_login_alerts && var.enable_login_canary && !var.login_canary_paused ? 1 : 0
  project      = var.gcp_project_id
  display_name = "browser-service: login canary stopped reporting (NEO-43)"
  combiner     = "OR"

  conditions {
    display_name = "No canary login completed within the absence window"

    condition_absent {
      filter = join(" AND ", [
        # Interpolated so Terraform creates the metric first — see the note on
        # the failures policy above. Doubly important here: an absence policy
        # pointed at a non-existent metric type sees permanent absence, so the
        # ordering bug would not fail quietly — it would page immediately.
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.browser_login_duration_ms[0].name}\"",
        "resource.type=\"cloud_run_revision\"",
        "metric.label.canary=\"true\"",
      ])

      # Must be ≳3x the canary interval, or normal jitter pages you. See the
      # variable's description — this has to be retightened in the same PR
      # that tightens the schedules.
      duration = var.login_canary_absence_duration

      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_COUNT"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.ops_email[0].id]

  alert_strategy {
    auto_close = "1800s"

    notification_rate_limit {
      period = "3600s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = local.neo43_doc_canary_absent
  }

  user_labels = merge(var.common_labels, { ticket = "neo-43" })

  depends_on = [google_project_iam_member.tf_deployer_monitoring_alert_editor]
}

# ──────────────────────────────────────────────
# Synthetic marketplace-login canary (NEO-43)
# ──────────────────────────────────────────────
#
# Cloud Scheduler drives POST /login/{bsc,sportlots} on a dedicated, non-user
# credential key. Without it, the only thing exercising marketplace login in
# prod is `prod-login-probe`, which runs at DEPLOY time — between deploys a
# break is silent until a seller reports it.
#
# The request body carries `canary: true`, which makes the browser service
# skip BOTH halves of the adapters' token cache. That flag is not a
# convenience, it is what makes the probe meaningful:
#   - SportLots caches its session cookie for 30 DAYS, so a cache-honouring
#     canary would exercise the real SportLots login roughly once a month.
#   - Each fresh login would otherwise write a new permanently-enabled Secret
#     Manager version ($0.06/version/month), costing more at this cadence
#     than the rest of this infrastructure combined.
#
# Canary failures produce ordinary browser_login_call lines and Cloud Run
# request metrics, so they feed the policies above with no extra wiring; the
# `canary` metric label is what lets those policies tell synthetic from real.

resource "google_service_account" "login_canary" {
  count        = var.enable_login_canary ? 1 : 0
  account_id   = "neonbinder-login-canary"
  display_name = "NeonBinder Login Canary"
  description  = "NEO-43: Cloud Scheduler identity for the synthetic marketplace-login canary. Sole permission is run.invoker on the browser service."
}

# Scoped to the service, never a project-level grant — same shape as
# runtime_invoker / convex_invoker / deployer_invoker above. A dedicated
# principal means revoking this ONE binding is an instant kill switch with
# zero blast radius on real traffic, and Cloud Audit Logs attribute canary
# invocations unambiguously.
#
# It needs NO Secret Manager access: the browser RUNTIME service account reads
# the credential secret, not the caller.
resource "google_cloud_run_service_iam_member" "login_canary_invoker" {
  count    = var.enable_login_canary ? 1 : 0
  location = google_cloud_run_service.neonbinder_browser.location
  service  = google_cloud_run_service.neonbinder_browser.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.login_canary[0].email}"
}

# roles/iam.serviceAccountAdmin (held project-wide by the tf-deployer) does
# NOT include serviceAccounts.actAs, which is required to reference this SA in
# a Scheduler job's oidc_token.
resource "google_service_account_iam_member" "tf_deployer_act_as_login_canary" {
  count              = var.enable_login_canary ? 1 : 0
  service_account_id = google_service_account.login_canary[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# Credential secret SHELLS only — same pattern as the internal_api_key secret
# above. The username/password are added out of band and never touch tfvars or
# Terraform state:
#
#   printf '{"username":"...","password":"..."}' | \
#     gcloud secrets versions add bsc-credentials-canary \
#       --data-file=- --project=neonbinder
#
# The JSON shape is required by SecretsManagerService.getCredentials, which
# throws "Invalid credentials format" without both fields. The names match
# KEY_PATTERN /^[a-z0-9]+-credentials-[a-zA-Z0-9_-]+$/ in
# services/browser/src/services/secrets-manager.ts.
#
# The "canary" userId segment intentionally corresponds to NO Clerk/Convex
# user — Convex builds keys from Clerk ids (user_...), so collision with a
# real seller is impossible. It is also the rate-limit bucket key, so the
# canary can never consume a real seller's 60/min budget.
resource "google_secret_manager_secret" "login_canary_bsc" {
  count     = var.enable_login_canary ? 1 : 0
  project   = var.gcp_project_id
  secret_id = "bsc-credentials-canary"

  replication {
    auto {}
  }

  labels = var.common_labels
}

resource "google_secret_manager_secret" "login_canary_sportlots" {
  count     = var.enable_login_canary ? 1 : 0
  project   = var.gcp_project_id
  secret_id = "sportlots-credentials-canary"

  replication {
    auto {}
  }

  labels = var.common_labels
}

locals {
  # Cloud Run validates the OIDC token audience against the BASE service URL.
  # It must NOT include the /login/... path or the request is rejected with
  # 401 before ever reaching Express — the same constraint apps/web/convex/
  # browserAudience.ts exists to normalize on the Convex side.
  login_canary_audience = var.enable_login_canary ? google_cloud_run_service.neonbinder_browser.status[0].url : ""
}

# retry_count = 0 is load-bearing, not a default. NEO-29: retrying a failed
# marketplace login turned a single hiccup into a sustained burst of
# serialized BSC logins that tripped bot protection — "the retry caused the
# failures it was meant to fix". A canary that retried would recreate exactly
# that shape on a schedule, forever. Flakiness is absorbed by the alert policy
# requiring repeated failures, not by retrying inside one run.
#
# attempt_deadline is deliberately SHORTER than Cloud Run's 300s request
# timeout, which gives a second, service-independent hang detector: Scheduler
# abandons the attempt and writes a non-OK AttemptFinished entry under
# resource.type="cloud_scheduler_job" even if the browser service is logging
# nothing at all.
resource "google_cloud_scheduler_job" "login_canary_bsc" {
  count            = var.enable_login_canary ? 1 : 0
  project          = var.gcp_project_id
  name             = "neonbinder-login-canary-bsc"
  region           = var.gcp_region
  description      = "NEO-43: exercises the real BSC Azure AD B2C login so a break is detected without waiting for seller traffic."
  schedule         = var.login_canary_schedule_bsc
  time_zone        = "Etc/UTC"
  attempt_deadline = var.login_canary_attempt_deadline
  paused           = var.login_canary_paused

  retry_config {
    retry_count = 0
  }

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_service.neonbinder_browser.status[0].url}/login/bsc"

    # Without this header express.json() leaves req.body empty and the service
    # returns 400 "Missing required field: key" — a permanently red canary.
    headers = {
      "Content-Type" = "application/json"
    }

    body = base64encode(jsonencode({
      key    = "bsc-credentials-canary"
      canary = true
    }))

    oidc_token {
      service_account_email = google_service_account.login_canary[0].email
      audience              = local.login_canary_audience
    }
  }

  depends_on = [
    google_project_service.cloudscheduler_api,
    google_project_iam_member.tf_deployer_cloudscheduler_admin,
    google_service_account_iam_member.tf_deployer_act_as_login_canary,
    google_cloud_run_service_iam_member.login_canary_invoker,
  ]
}

resource "google_cloud_scheduler_job" "login_canary_sportlots" {
  count            = var.enable_login_canary ? 1 : 0
  project          = var.gcp_project_id
  name             = "neonbinder-login-canary-sportlots"
  region           = var.gcp_region
  description      = "NEO-43: exercises the real SportLots signin form. Without the canary flag this would hit the adapter's 30-DAY cookie cache and never touch the login endpoint at all."
  schedule         = var.login_canary_schedule_sportlots
  time_zone        = "Etc/UTC"
  attempt_deadline = var.login_canary_attempt_deadline
  paused           = var.login_canary_paused

  retry_config {
    retry_count = 0
  }

  http_target {
    http_method = "POST"
    uri         = "${google_cloud_run_service.neonbinder_browser.status[0].url}/login/sportlots"

    headers = {
      "Content-Type" = "application/json"
    }

    body = base64encode(jsonencode({
      key    = "sportlots-credentials-canary"
      canary = true
    }))

    oidc_token {
      service_account_email = google_service_account.login_canary[0].email
      audience              = local.login_canary_audience
    }
  }

  depends_on = [
    google_project_service.cloudscheduler_api,
    google_project_iam_member.tf_deployer_cloudscheduler_admin,
    google_service_account_iam_member.tf_deployer_act_as_login_canary,
    google_cloud_run_service_iam_member.login_canary_invoker,
  ]
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

