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
#
# NEO-148 security-audit note (2026-08-13, NOT scoped by this change): this
# grant is project-level `storage.objectAdmin`, so it applies to EVERY bucket
# in the project — including the new `placeholder_uploads` bucket added
# above, which holds end-user-uploaded content for the first time. Until this
# grant existed alongside only build-artifact buckets (GCR's legacy
# `artifacts.<project>.appspot.com` backing bucket), that breadth was benign;
# now it means the browser deployer SA can also read/overwrite/delete any
# user's placeholder upload. In dev, `browser_wif_allow_pull_requests = true`
# widens who can mint a token for this SA (any same-repo PR), so the exposure
# isn't purely theoretical there.
#
# Recommended follow-up: scope this to the GCR backing bucket(s) via an IAM
# condition (e.g. `resource.name.startsWith("projects/_/buckets/artifacts.")`)
# — NOT applied here. This repo's CI/CD deploy pipeline (browser-deploy.yml)
# depends on this grant for every `docker push gcr.io/...`, and confirming
# the condition is correctly scoped requires observing a real `terraform
# plan`/`apply` and a live deploy against it — this worktree has no GCP
# credentials and is explicitly barred from `terraform apply`. Landing an
# unverified condition on a project-wide grant a live deploy pipeline depends
# on risks a silent 403 on the next push, which is worse than the current
# over-broad-but-working grant. Scope this in a follow-up PR that can
# actually apply + verify against dev first.
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
# cleaned up. NEO-95 added two cleanup policies to cap that.
#
# NEO-117: only ONE of those two ever did anything, and the repo kept growing
# to 117.8 GB (dev) / 41.7 GB (prod) — ~$15/month.
#
#   - "delete-old-untagged" WORKS. Verified: zero untagged images older than
#     14 days in either project. Left exactly as-is; do not touch it.
#
#   - "keep-recent-tagged" was a NO-OP. In Artifact Registry a KEEP policy only
#     protects versions *from a DELETE policy* — it never deletes anything on
#     its own. With no DELETE matching tagged images, nothing tagged was ever
#     collected. Proof rather than doc-reading: dev `neonbinder-browser` held
#     112 tagged versions, the oldest 109 days, when `keep_count` was 15. If
#     KEEP meant "delete beyond 15" there would have been 15.
#
# So the KEEP is now paired with DELETE policies that give it something to
# protect against, and split per-package because the two images have opposite
# characteristics.
#
# WHY keep_count = 10 FOR BROWSER
#
# The floor is not "how many rollbacks do we want" — it is "how many images are
# referenced by a revision that still exists". Delete an image a retained
# revision points at and that revision cannot start at all; it is not merely
# un-rollback-to-able. That hazard is already real: prod revision
# `neonbinder-browser-00001-47f` references sha256:445410f3… which is ALREADY
# absent from the registry (pre-existing, not caused by this change).
#
# Measured 2026-08-06 by ranking every AR version newest-first and locating
# every digest referenced by a live Cloud Run revision:
#
#   dev  browser: 112 versions,  8 pinned, deepest live-pinned rank =  7
#   prod browser:  40 versions,  5 pinned, deepest live-pinned rank =  4
#
# Product direction is "we only need to roll back one version", and
# `revision-gc.yml` is set to --keep 2 to match. It is tempting to set
# keep_count to 2 as well. That is still wrong, but SINCE NEO-130 the reason has
# changed — the original one no longer applies and should not be repeated:
#
#   * WAS (pre-NEO-130): keep_count ranked by PUSH VOLUME and PR previews pushed
#     into this same package, so a keep_count of 2 survived only until the next
#     busy PR day (13 dev pushes in one day, measured) — at which point the live
#     serving image fell outside the window and was collected. Previews now push
#     to `<service>-preview`, so that confound is gone: one merge produces one
#     version here (`:<sha>` is new, moving `:latest` only retags), and rank now
#     genuinely means "deploys deep".
#
#   * STILL TRUE: images and revisions remain different axes. `revision-gc`'s
#     keep 2 counts REVISIONS; this counts IMAGE VERSIONS, and a retained
#     revision whose image was collected cannot start at all — it is not merely
#     un-rollback-to-able. That hazard is real, not theoretical: prod revision
#     `neonbinder-browser-00001-47f` references sha256:445410f3… which is
#     already absent. `revision-image-check.yml` in the monorepo now watches for
#     exactly this, weekly, one hour after the GC sweep.
#
# 10 is therefore "10 deploys deep" for both services now, which is a real
# rollback depth rather than a hedge against preview churn. Prod browser pushes
# ~0.4/day, so it is still ~25 days there — deliberately more than the 14-day
# age gate below, so a slow-moving image is never left unprotected by both
# guards at once.
#
# PREPROCESS — the sweep this block used to wait on has now happened (NEO-123).
#
# The previous note here said preprocess was protective-only at keep 30 because
# all 24 dev versions were pinned by live revisions, and that "unpinning that
# storage needs a revision sweep FIRST; only then is lowering this keep_count
# safe." Both halves of that are now resolved:
#
#   * The cause is fixed at source. Preprocess accumulated pinned revisions
#     because its promote deliberately RETAINED the sha-<short> tag, keeping
#     each revision addressable forever (the NEO-114 shape). Since NEO-123 the
#     pipeline lives at .github/workflows/preprocess.yml in the monorepo and
#     promotes with a single atomic
#     `update-traffic --to-revisions=X=100 --remove-tags=sha-<short>`.
#     Verified on the first push-lane run: sha-88a3ebd exists in neither env.
#
#   * The backlog is gone. The sweep removed 42 revisions, 37 images and 9
#     traffic tags; dev and prod each now hold exactly 1 revision and 1 image.
#
# Preprocess previously had NO DELETE policy matching it at all: main-line images
# are tagged `<full-sha>` + `latest`, so `delete-old-untagged` never reaps them
# and `delete-stale-pr-images` only matches the `pr-` prefix. They accumulated
# without bound. `delete-tagged-preprocess` below closes that.
#
# PREPROCESS NOW MATCHES BROWSER (keep 10 + 14d) — NEO-130 removed the reason
# they diverged. Keeping the history here because the divergence looked
# arbitrary without it, and someone will otherwise "simplify" it back:
#
# NEO-123 shipped preprocess at keep 30 + 180d, deliberately NOT browser's
# numbers. Browser is safe on 10 + 14d because its two guards fail in OPPOSITE
# conditions — dev deploys often so the serving image is always young (age gate
# holds), prod deploys rarely so it is always near rank 1 (rank holds). That
# redundancy did not survive being copied to preprocess:
#
#   * The age gate was inert. Preprocess merge gaps are 15 and 92 days, so for
#     most of the calendar BOTH envs served an image older than 14 days and only
#     rank protected it.
#   * Rank was not driven by deploys. `deploy-preview` pushed `pr-<N>` into this
#     SAME package on every PR synchronize, and `most_recent_versions` has no
#     tag_state filter so untagged predecessors held slots too. Measured on
#     browser-dev at the time: 6 of 10 protected slots were `pr-*`/untagged,
#     the whole window spanning 9 days.
#
# Both guards false at once ⇒ the policy collects the image the live revision
# pins ⇒ at minScale=0 every request cold-starts against a missing digest and
# fails, unrecoverably.
#
# NEO-130 fixed the cause rather than the symptom: previews now push to
# `<service>-preview`, so rank in THIS package is driven only by merges. The
# second bullet no longer holds, the first stops mattering (a low-cadence
# service is exactly one whose serving image sits at rank 1), and 10 + 14d is
# sound here for the same reason it is for browser.
#
# Prerequisites, both satisfied before this landed:
#   * previews are out of this package (NEO-130, monorepo b1834e2)
#   * the historical backlog was swept, so nothing pre-split is left consuming
#     the window — dev and prod each held exactly 1 image
#
# Backstop: `revision-image-check.yml` in the monorepo asserts weekly that every
# serving revision's digest still exists, one hour after the GC sweep.
#
# Repo cap is 10 cleanup policies; this uses 6.
#
# DO NOT set cleanup_policy_dry_run = true to "preview" this. That flag is
# repo-wide and would silently disable the working untagged policy too.
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

  # Protects the 10 newest browser builds from delete-tagged-browser below.
  # Package-scoped so the count is unambiguously per-image rather than
  # repo-wide — the old unscoped policy left that in doubt.
  cleanup_policies {
    id     = "keep-recent-browser"
    action = "KEEP"

    most_recent_versions {
      package_name_prefixes = ["neonbinder-browser"]
      keep_count            = 10
    }
  }

  # Purely protective: no DELETE policy targets preprocess by package, so this
  # only guards against delete-stale-pr-images catching a pr-tagged preprocess
  # image that a live revision still needs.
  cleanup_policies {
    id     = "keep-recent-preprocess"
    action = "KEEP"

    most_recent_versions {
      # Matches browser since NEO-130 — previews no longer share this package,
      # so 10 means 10 DEPLOYS deep rather than 10 pushes of mixed provenance.
      package_name_prefixes = ["neonbinder-preprocess"]
      keep_count            = 10
    }
  }

  # The actual reclaim. Unbounded by age on purpose — keep-recent-browser above
  # is the guard, so retention is expressed as "the last 10 builds" rather than
  # as a date. An age gate would leave unpinned 30-90 day old main-branch builds
  # accumulating indefinitely, which is most of what filled the repo.
  # TWO independent guards, because rank alone is not safe here.
  #
  # An image is collected only if it is BOTH older than 14 days AND outside the
  # newest 10 (keep-recent-browser above). Either condition on its own protects
  # it. That redundancy is load-bearing, not belt-and-braces:
  #
  # PR previews push to THIS SAME package (`neonbinder-browser:pr-<N>`), so
  # version rank is driven by total push volume, not by deploy count. Measured
  # 2026-08-06: dev averages 1.8 pushes/day but spiked to 13 IN ONE DAY. With a
  # rank-only guard, one busy PR day pushes the live serving image past the keep
  # window and deletes it — and since every revision is minScale=0, the next
  # request cold-starts against a missing image and every request fails. The age
  # gate makes that impossible: nothing under 14 days old is ever collected,
  # whatever the preview churn does to its rank.
  #
  # Conversely the rank guard is what protects PROD, whose risk is the opposite
  # shape: prod pushes only ~0.4/day, so an image 10 builds deep is ~25 days old
  # and the age gate alone would have collected it. Prod's LOW deploy frequency
  # is what forces keep_count as high as 10.
  cleanup_policies {
    id     = "delete-tagged-browser"
    action = "DELETE"

    condition {
      tag_state             = "TAGGED"
      package_name_prefixes = ["neonbinder-browser"]
      older_than            = "1209600s" # 14 days
    }
  }

  # Same intent AND same numbers as delete-tagged-browser since NEO-130. Until
  # NEO-123 nothing matched preprocess main-line images (`<full-sha>` + `latest`
  # are TAGGED, so delete-old-untagged skips them and delete-stale-pr-images only
  # matches `pr-`), so they grew without bound. This collects them.
  #
  # Shipped at 180d under NEO-123 because previews then shared this package and
  # could bury the serving image past the keep window while the age gate was
  # inert — see the rationale block above. NEO-130 moved previews out, so the
  # 14-day gate is now backed by a rank guard that only merges advance, exactly
  # as it is for browser.
  #
  # Reclaim matters more here than for browser: preprocess images carry torch
  # plus ~375MB of baked SAM weights, so each collected version frees far more.
  cleanup_policies {
    id     = "delete-tagged-preprocess"
    action = "DELETE"

    condition {
      tag_state             = "TAGGED"
      package_name_prefixes = ["neonbinder-preprocess"]
      older_than            = "1209600s" # 14 days
    }
  }

  # Per-PR preview images. `preview-cleanup.yml` in the monorepo tries to delete
  # these from CI and has silently 403'd since it was written — the deployer SAs
  # hold artifactregistry.writer + createOnPushWriter, neither of which contains
  # versions.delete, and the step ends in `|| echo "... — ignoring"` so it exits
  # 0. Dev accumulated 43 pr-* tagged images against 1 open PR.
  #
  # Fixed here rather than by granting the CI SA repoAdmin: a server-side
  # retention policy is least-privilege, whereas blanket registry delete from CI
  # is a supply-chain risk for no benefit.
  #
  # 30 days rather than unbounded because a long-lived PR branch can legitimately
  # keep redeploying the same preview.
  cleanup_policies {
    id     = "delete-stale-pr-images"
    action = "DELETE"

    condition {
      tag_state    = "TAGGED"
      tag_prefixes = ["pr-"]
      older_than   = "2592000s" # 30 days
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
  # Deploy workflows (gcloud) name revisions; terraform refreshes those names
  # into state. Without autogeneration, terraform's next template change
  # replays the existing revision name with a different config and Cloud Run
  # 409s ("revision with different configuration already exists") - hit on
  # the NEO-161 preprocess memory bump, same latent bug here.
  autogenerate_revision_name = true

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
# GCS Bucket for placeholder-upload direct uploads (NEO-148, dev + prod)
# ──────────────────────────────────────────────
# Client uploads a zip of scanned placeholder card fronts/backs directly to
# this bucket via a Convex-minted v4 signed POST policy (see
# apps/web/convex/adapters/placeholderUploads.ts in the monorepo), then the
# preprocess service crops it into a pairing-review grid. NEVER public — the
# signed policy is the sole authorization mechanism.

resource "google_storage_bucket" "placeholder_uploads" {
  count    = var.create_placeholder_bucket ? 1 : 0
  name     = "neonbinder-placeholder-uploads-${var.gcp_project_id}"
  location = var.gcp_region

  uniform_bucket_level_access = true

  # Belt-and-suspenders alongside "NEVER public" above: UBLA already makes a
  # per-object ACL (the classic way a bucket accidentally goes public)
  # impossible, but it doesn't stop a future bucket-level `allUsers` IAM
  # binding. `enforced` makes that binding itself rejected by GCS, so the
  # policy is that no one on this repo's review can make this bucket public
  # even by mistake, not just that no one currently has.
  public_access_prevention = "enforced"

  versioning {
    enabled = false
  }

  # Soft delete would otherwise keep a "deleted" object's bytes billable for
  # its own retention window (defaults to 7 days) ON TOP OF the 7-day
  # lifecycle-Delete age below — i.e. ~14 days billed, not 7. Zeroing it
  # makes the Delete lifecycle rule's "7 days" promise actually mean 7 days
  # of storage cost, not a doubled tail.
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      # 7 days, not the "consumed in minutes" lifetime of the raw zip: the
      # cropped outputs back a human pairing-review grid that a user may
      # leave open overnight. 7 days comfortably covers a weekend while still
      # bounding cost on 200-500MB uploads.
      age = 7
    }
  }

  lifecycle_rule {
    action {
      type = "AbortIncompleteMultipartUpload"
    }
    condition {
      age = 1
    }
  }

  # GCS CORS origins must be exact strings — no subdomain wildcard is
  # supported — and Vercel preview URLs are per-deployment and cannot be
  # enumerated in advance. The signed policy itself is the authorization;
  # CORS is a browser-enforced same-origin convenience, not a security
  # boundary, so permitting any origin to *attempt* a POST grants nothing
  # without a valid signature on that exact object path.
  #
  # POST, not PUT: the client uploads via a signed POST policy
  # (bucket.generateSignedPostPolicyV4, multipart/form-data) rather than a
  # signed PUT URL, because a POST policy's `content-length-range` condition
  # is enforced by GCS server-side — the only real way to cap upload size.
  #
  # `x-goog-if-generation-match` (the write-once condition the POST policy
  # sets — see placeholderUploads.ts) is deliberately NOT added to
  # `response_header` here: it travels as a multipart FORM FIELD in the POST
  # body, not as a request header, so it is never subject to a CORS
  # preflight in the first place, and `response_header` controls which
  # RESPONSE headers this bucket exposes to browser JS
  # (Access-Control-Expose-Headers) — a request-side field wouldn't be
  # affected by it either way. Adding it here would be a no-op that misstates
  # what this list does.
  cors {
    origin          = ["*"]
    method          = ["POST", "OPTIONS"]
    response_header = ["Content-Type"]
    max_age_seconds = 3600
  }

  labels = var.common_labels
}

# neonbinder-convex mints the signed URL and needs to write the initial
# object; objectViewer lets it (or downstream Convex logic) read back what
# was uploaded. It never deletes — the 7-day lifecycle rule above handles
# cleanup — so objectAdmin is deliberately NOT granted.
resource "google_storage_bucket_iam_member" "placeholder_uploads_convex_creator" {
  count  = var.create_placeholder_bucket ? 1 : 0
  bucket = google_storage_bucket.placeholder_uploads[0].name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.convex.email}"
}

resource "google_storage_bucket_iam_member" "placeholder_uploads_convex_viewer" {
  count  = var.create_placeholder_bucket ? 1 : 0
  bucket = google_storage_bucket.placeholder_uploads[0].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.convex.email}"
}

# preprocess runtime reads the uploaded zip and writes the cropped outputs
# back into the same prefix. No delete — lifecycle handles cleanup.
resource "google_storage_bucket_iam_member" "placeholder_uploads_preprocess_viewer" {
  count  = var.create_placeholder_bucket ? 1 : 0
  bucket = google_storage_bucket.placeholder_uploads[0].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.preprocess_runtime.email}"
}

resource "google_storage_bucket_iam_member" "placeholder_uploads_preprocess_creator" {
  count  = var.create_placeholder_bucket ? 1 : 0
  bucket = google_storage_bucket.placeholder_uploads[0].name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.preprocess_runtime.email}"
}

# NEO-175: fast runtime gets the same viewer+creator pair as heavy's runtime
# SA above — it reads the uploaded zip and writes cropped outputs for every
# image that settles on the fast path, same objectViewer+objectCreator-only
# (never objectAdmin) shape as heavy (security control #2).
resource "google_storage_bucket_iam_member" "placeholder_uploads_preprocess_fast_viewer" {
  count  = var.create_placeholder_bucket ? 1 : 0
  bucket = google_storage_bucket.placeholder_uploads[0].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.preprocess_fast_runtime.email}"
}

resource "google_storage_bucket_iam_member" "placeholder_uploads_preprocess_fast_creator" {
  count  = var.create_placeholder_bucket ? 1 : 0
  bucket = google_storage_bucket.placeholder_uploads[0].name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.preprocess_fast_runtime.email}"
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
    # NEO-115: `job_workflow_ref` is the workflow FILE that minted the token
    # (e.g. "neonbinder/neonbinder/.github/workflows/secret-version-gc.yml@refs/heads/main"),
    # which `repository` and `ref` cannot express — they identify the repo and
    # the branch, not which of its workflows is running. Mapping it here is
    # inert for every existing binding; only the secret-gc SA binds on it. See
    # google_service_account_iam_member.secret_gc_wif for why that matters.
    "attribute.job_workflow_ref" = "assertion.job_workflow_ref"
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
# Secret Version GC SA (NEO-115)
# ──────────────────────────────────────────────
#
# The weekly Secret Manager version sweep
# (.github/workflows/secret-version-gc.yml in the monorepo) reclaims superseded
# credential secret versions. `neonbinder-dev` had accumulated 1,326 ENABLED
# versions across 33 secrets (~$70/month, +~25/day) because nothing had ever
# pruned them.
#
# WHY A DEDICATED SA rather than reusing neonbinder-browser-deployer, which the
# monorepo's other workflows already impersonate:
#
# The sweep needs `secretmanager.versions.destroy` project-wide — secret names
# are `${site}-credentials-${userId}`, not knowable at plan time, so the grant
# cannot be scoped to individual secrets (same constraint documented above
# runtime_secret_admin). Hanging that off the deployer SA would mean every
# identity that can reach the deployer SA can also destroy or overwrite every
# secret version in the project. In dev that set is wide: the deployer's
# workloadIdentityUser binding above is scoped to
# `attribute.repository/<monorepo>`, and dev's provider condition accepts
# `event_name == "pull_request"` (that is how per-PR Cloud Run previews
# authenticate). So ANY pull request in the monorepo can mint a deployer token.
# A destroy is irreversible and these are real users' marketplace credentials.
#
# This SA instead binds workloadIdentityUser on `attribute.job_workflow_ref`,
# which pins impersonation to one workflow FILE on one ref. A PR preview, a
# compromised unrelated workflow, or a hand-run `gh workflow run` on another
# workflow all fail to mint this token. Conversely this SA holds nothing else —
# no Cloud Run deploy, no actAs on the runtime SA, no GCS — so a fault in the
# sweep cannot reach anything but secret version metadata.
#
# ROLES — exactly three permissions, split across two predefined roles:
#
#   secretmanager.secrets.list    ┐ enumerate the credential secrets and
#   secretmanager.versions.list   ┘ their versions              → viewer
#   secretmanager.versions.destroy  reclaim superseded versions → secretVersionManager
#
# NEITHER role contains `secretmanager.versions.access`, the permission that
# returns secret material, so this identity can count and destroy versions but
# never read a payload:
#
#   roles/secretmanager.viewer               → secrets.{get,getIamPolicy,list,
#     listEffectiveTags,listTagBindings}, versions.{get,list}, locations.{get,
#     list}, resourcemanager.projects.{get,list}. versions.get is METADATA only
#     (name/state/createTime); the payload comes from versions.access.
#   roles/secretmanager.secretVersionManager → versions.{add,destroy,disable,
#     enable,get,list}, secrets.rotate, resourcemanager.projects.{get,list}.
#
# roles/secretmanager.admin was REJECTED — it is what the browser RUNTIME SA
# holds (runtime_secret_admin above) precisely because that service must read
# payloads, and it additionally grants secrets.create/delete plus setIamPolicy.
#
# DISCLOSURE — secretVersionManager is still wider than the sweep needs: it is
# the narrowest PREDEFINED role containing versions.destroy, but it also carries
# versions.add/disable/enable and secrets.rotate. So this identity could write a
# new version over a secret or disable an in-use one (integrity/availability),
# though it still cannot read one (confidentiality). A custom role limited to
# secrets.list + versions.list + versions.destroy would be exactly minimal, but
# creating one requires granting the tf-deployer roles/iam.roleAdmin
# (iam.roles.create) — the same larger-escalation trade already rejected for
# logging.configWriter further down this file. Same call here, for the same
# reason. Pinning WHO can assume the SA is the mitigation that does not require
# that escalation.
#
# ORDERING (NEO-95 lesson, see the note above tf_deployer_monitoring_alert_editor):
# project-level IAM propagation takes minutes and `depends_on` does not fix it,
# so a grant and its first consumer must not ship in the same apply. That holds:
# these bindings land via terraform (develop → dev, main → prod) strictly ahead
# of the GC workflow's first run in the monorepo — separate repo, separate
# pipeline, and no resource in THIS apply depends on them.
resource "google_service_account" "secret_gc" {
  account_id   = "neonbinder-secret-gc"
  display_name = "NeonBinder Secret Version GC"
  description  = "Scheduled Secret Manager version sweep (NEO-115). Destroy-only: holds no accessor, cannot read secret payloads."
}

resource "google_project_iam_member" "secret_gc_viewer" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.viewer"
  member  = "serviceAccount:${google_service_account.secret_gc.email}"
}

resource "google_project_iam_member" "secret_gc_version_manager" {
  project = var.gcp_project_id
  role    = "roles/secretmanager.secretVersionManager"
  member  = "serviceAccount:${google_service_account.secret_gc.email}"
}

# The narrowing that makes the project-level destroy grant above acceptable.
#
# `attribute.job_workflow_ref` is GitHub's `job_workflow_ref` OIDC claim: the
# workflow file plus the ref it was loaded from. Binding on it means only
# secret-version-gc.yml, running from `secret_gc_workflow_ref`, can impersonate
# this SA — not the repo at large, and not a pull_request token.
#
# Note the ref in `secret_gc_workflow_ref` is the branch the workflow FILE is
# loaded from, which for both `schedule` and `workflow_dispatch` is the default
# branch (refs/heads/main) in both environments — including dev, whose Cloud Run
# previews run from PR refs but whose GC sweep does not. It is deliberately NOT
# `browser_wif_branch_ref`: that variable happens to be refs/heads/main too, but
# it means "the branch browser deploys are allowed from", a different fact that
# could diverge later.
#
# This binding also has to satisfy the provider's own attribute_condition, which
# it does in both envs: a scheduled or dispatched run on the default branch
# carries assertion.ref == "refs/heads/main", matching prod's push-to-main-only
# condition without relying on dev's looser pull_request clause.
resource "google_service_account_iam_member" "secret_gc_wif" {
  service_account_id = google_service_account.secret_gc.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.job_workflow_ref/${var.secret_gc_workflow_ref}"
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
#
# NEO-148 security-audit note (2026-08-13, NOT scoped by this change): same
# exposure as google_project_iam_member.deployer_storage_object_admin above
# — this is project-level `storage.objectAdmin`, so it now also covers the
# new `placeholder_uploads` bucket, not just GCR's backing bucket. Left
# unscoped for the same reason: this worktree has no GCP credentials and is
# barred from `terraform apply`, so an IAM-condition change here can't be
# verified against the real preprocess deploy pipeline before landing. See
# the sibling comment on the browser deployer's grant for the recommended
# follow-up (an IAM condition scoping this to the `artifacts.*` bucket,
# applied and verified in its own PR).
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

# ──────────────────────────────────────────────
# Preprocess FAST runtime SA (NEO-175, security control #2) — dedicated, not
# shared with heavy's preprocess_runtime. Least-privilege reasons this is its
# own SA rather than reusing preprocess_runtime: the fast role never touches
# BiRefNet/SAM and this SA's grant set reflects that (no broader than heavy's,
# but kept independently auditable — a future tightening of one can never
# silently affect the other since they share no IAM bindings at all).
# ──────────────────────────────────────────────

resource "google_service_account" "preprocess_fast_runtime" {
  # "fast-run", not "-runtime": GCP's account_id has a hard 30-char cap and
  # "neonbinder-preprocess-fast-runtime" is 34. This is exactly 30.
  account_id   = "neonbinder-preprocess-fast-run"
  display_name = "NeonBinder Preprocess Fast Runtime"
  description  = "Runtime service account for the fast-role preprocess Cloud Run service"
}

resource "google_project_iam_member" "preprocess_fast_runtime_logging_writer" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.preprocess_fast_runtime.email}"
}

# Same secrets as heavy's runtime SA — the fast role's container still gets
# both INTERNAL_API_KEY and ANTHROPIC_API_KEY via --set-secrets (see the
# neonbinder_preprocess_fast container block below): INTERNAL_API_KEY for the
# app-layer header check that runs alongside Cloud Run IAM on every request
# (both services, unchanged by the T1/T2 lock-down below), ANTHROPIC_API_KEY
# because the fast role still calls classify_card on an accepted crop.
resource "google_secret_manager_secret_iam_member" "preprocess_fast_runtime_api_key_access" {
  secret_id = google_secret_manager_secret.internal_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.preprocess_fast_runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "preprocess_fast_runtime_anthropic_access" {
  secret_id = google_secret_manager_secret.anthropic_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.preprocess_fast_runtime.email}"
}

# Allow developers to impersonate the fast runtime SA (local dev parity),
# mirroring developer_impersonate_preprocess_runtime.
resource "google_service_account_iam_member" "developer_impersonate_preprocess_fast_runtime" {
  for_each           = toset(var.developer_emails)
  service_account_id = google_service_account.preprocess_fast_runtime.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${each.value}"
}

# Allow the terraform-deployer SA to act as the fast runtime SA during apply
# (spec.service_account_name on the Cloud Run resource below requires it).
resource "google_service_account_iam_member" "tf_deployer_act_as_preprocess_fast_runtime" {
  service_account_id = google_service_account.preprocess_fast_runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.terraform_deployer.email}"
}

# Allow the preprocess deployer SA to act as the fast runtime SA — same
# `gcloud run deploy --service-account=...` need as
# preprocess_deployer_act_as_runtime, for the second service the same
# pipeline will deploy.
resource "google_service_account_iam_member" "preprocess_deployer_act_as_fast_runtime" {
  service_account_id = google_service_account.preprocess_fast_runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.preprocess_deployer.email}"
}

# Cloud Run service — 4 CPU / 16Gi / concurrency=1 / max-instances=3 / scale-to-zero
resource "google_cloud_run_service" "neonbinder_preprocess" {
  # See neonbinder_browser: gcloud-named revisions + a terraform template
  # change 409 without autogeneration. This unblocked the NEO-161 8Gi apply.
  autogenerate_revision_name = true

  name     = var.preprocess_service_name
  location = var.gcp_region

  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/minScale" = "0"
        # NEO-175 Phase 3: repointed from var.preprocess_max_instances (which
        # now sizes the FAST service — see its variable comment) to the
        # dedicated heavy variable.
        "autoscaling.knative.dev/maxScale" = tostring(var.heavy_preprocess_max_instances)
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

# NEO-175 Phase 3 (heavy lock-down, NEO-170 T1+T2): this service used to be
# reachable by anyone (`allUsers` below) with the app layer's INTERNAL_API_KEY
# header check as the only real gate — NOT "matching the browser service's
# pattern" as the comment here previously (and inaccurately) claimed. Browser
# has been IAM-only since NEO-20 (see google_cloud_run_service_iam_member.
# convex_invoker's comment near the top of this file): no allUsers binding,
# Cloud Run IAM is the sole gate, Convex authenticates with a Google OIDC ID
# token. This block brings heavy to the same posture:
#
#   T1 — grant roles/run.invoker to every real caller (below): the
#        neonbinder-convex SA and the preprocess-deployer SA (CI's post-deploy
#        smoke tests already mint an OIDC ID token for this SA and expect the
#        binding to exist — see .github/workflows/preprocess-deploy.yml and
#        preprocess.yml's "NEO-170 Phase D" smoke-test steps in the monorepo,
#        which this terraform change is the other half of).
#   T2 — remove the allUsers binding that follows.
#
# CRITICAL ORDERING: T1 must exist before/with T2, or BOTH Convex and CI
# deploys lose access the moment allUsers is gone. This file lands both in the
# same change (one PR, one apply) rather than across two — see the deploy
# runbook for why that is sufficient without an explicit terraform
# `depends_on` (none is expressible here: T2 is a resource *removed* from
# config, not one with a lifecycle hook to hang a dependency on).
resource "google_cloud_run_service_iam_member" "preprocess_convex_invoker" {
  location = google_cloud_run_service.neonbinder_preprocess.location
  service  = google_cloud_run_service.neonbinder_preprocess.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.convex.email}"
}

# See preprocess_convex_invoker's comment directly above — this is T1's other
# required grant. Mirrors the browser service's deployer_invoker (NEO-20):
# run.admin (granted elsewhere) covers *managing* the service but not the
# per-service invoke check CI's smoke test performs against the tagged,
# not-yet-promoted revision.
resource "google_cloud_run_service_iam_member" "preprocess_deployer_invoker" {
  location = google_cloud_run_service.neonbinder_preprocess.location
  service  = google_cloud_run_service.neonbinder_preprocess.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.preprocess_deployer.email}"
}

# T2 (see preprocess_convex_invoker's comment above): allUsers invoker
# REMOVED. Was here pre-NEO-175 as the sole practical gate alongside the app's
# INTERNAL_API_KEY header check; T1 above supplies every real caller with its
# own scoped invoker grant instead.

# ──────────────────────────────────────────────
# Preprocess FAST service — same image, classical-CV-only role (NEO-175)
# ──────────────────────────────────────────────
# SAME container image as neonbinder_preprocess above, selected into the fast
# role by the PREPROCESS_ROLE=fast env var (services/preprocess/app/main.py):
# it never loads BiRefNet/SAM, so it skips the ~191s startup model-load heavy
# pays on every cold start. Handles every image first; anything the classical
# path can't settle comes back with needs_escalation=true and Convex re-routes
# it to the heavy service above. See apps/web/convex/preprocessCapacity.ts and
# adapters/preprocess.ts for the Convex-side half of this contract.
#
# IAM-only from creation (security control #1) — unlike heavy, this service
# never had a legacy allUsers caller to transition away from, so it skips
# heavy's transitional T1-then-T2 shape entirely and goes straight to the end
# state: no allUsers binding anywhere below.
resource "google_cloud_run_service" "neonbinder_preprocess_fast" {
  # See neonbinder_preprocess / neonbinder_browser: gcloud-named revisions +
  # a terraform template change 409s without autogeneration.
  autogenerate_revision_name = true

  name     = var.preprocess_fast_service_name
  location = var.gcp_region

  template {
    metadata {
      annotations = {
        "autoscaling.knative.dev/minScale" = "0"
        "autoscaling.knative.dev/maxScale" = tostring(var.preprocess_max_instances)
      }
    }

    spec {
      container_concurrency = var.preprocess_fast_container_concurrency
      timeout_seconds       = 300
      service_account_name  = google_service_account.preprocess_fast_runtime.email

      containers {
        # Same image as heavy — the role split is entirely env-var-driven
        # (PREPROCESS_ROLE below), not a separate build or Dockerfile. CI
        # manages the tag thereafter, same as preprocess_image's own comment.
        image = var.preprocess_image

        resources {
          limits = {
            cpu    = var.preprocess_fast_cpu
            memory = var.preprocess_fast_memory
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

        # The whole reason this is a separate service: selects the fast role
        # in services/preprocess/app/main.py (_preprocess_role()). Heavy sets
        # nothing and gets the default ("heavy") — see that service's
        # container block above.
        env {
          name  = "PREPROCESS_ROLE"
          value = "fast"
        }
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }

  # Vision API dependency mirrors heavy: no bespoke IAM role exists for Cloud
  # Vision (classic vision.googleapis.com has no narrow predefined role in
  # this provider's IAM surface — heavy's runtime SA has never held one
  # either, confirmed by grep across this file), so enabling the API is the
  # only prerequisite either service needs.
  depends_on = [google_project_service.vision_api]

  lifecycle {
    # Mirrors neonbinder_preprocess's lifecycle block above — same deploy-
    # workflow-owns-traffic / gcloud-annotation-churn rationale.
    ignore_changes = [
      template[0].spec[0].containers[0].image,
      traffic,
      template[0].metadata[0].annotations["run.googleapis.com/client-name"],
      template[0].metadata[0].annotations["run.googleapis.com/client-version"],
      template[0].metadata[0].labels,
    ]
  }
}

# Security control #1: convex SA only, no allUsers. See the service comment
# above for why this service skips heavy's transitional shape.
resource "google_cloud_run_service_iam_member" "preprocess_fast_convex_invoker" {
  location = google_cloud_run_service.neonbinder_preprocess_fast.location
  service  = google_cloud_run_service.neonbinder_preprocess_fast.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.convex.email}"
}

# Pre-provisions for the fast-service CI deploy lane (not yet built — the
# monorepo's preprocess.yml / preprocess-deploy.yml only deploy to the heavy
# service today; see the deploy runbook). Granted now, alongside the service
# itself, rather than deferred: unlike heavy's deployer_invoker (a transitional
# grant paired with removing allUsers), fast has no allUsers to transition
# away from, so ANY future smoke test against it needs this from the start.
# Same SA as heavy's deployer_invoker — one deploy pipeline, same image,
# both services.
resource "google_cloud_run_service_iam_member" "preprocess_fast_deployer_invoker" {
  location = google_cloud_run_service.neonbinder_preprocess_fast.location
  service  = google_cloud_run_service.neonbinder_preprocess_fast.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.preprocess_deployer.email}"
}

# Security control #4: deliberately NO run.invoker grant here for
# preprocess_fast_runtime on ANY service (this one or heavy) — do not
# replicate preprocess_runtime_invoker's self-invoker pattern for fast. The
# fast runtime SA has no reason to call any Cloud Run service: Vision API and
# GCS are not Cloud Run, and it never calls heavy directly — escalation is a
# Convex-side re-enqueue (apps/web/convex/placeholderHeavyPool.ts), not a
# fast-to-heavy service call. Zero fast-to-heavy (or fast-to-self) invoker
# grants exist anywhere in this file; keep it that way.

# WIF provider dedicated to the preprocess deploy lane. Since NEO-123 that lane
# lives in the monorepo, so this provider and `github` above trust the SAME repo.
# They stay two separate providers deliberately, so either lane can be scoped or
# revoked without touching the other.
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

# Allow GitHub Actions (monorepo, preprocess lane) to impersonate the preprocess
# deployer SA. NOTE: this principalSet is repo-scoped, not workflow-scoped, so
# post-NEO-123 any monorepo workflow can assume this SA. That matches the
# browser deployer's existing posture; narrowing both via job_workflow_ref (as
# secret_gc_wif does) is tracked separately.
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
# expectation sidecars live in the monorepo at services/preprocess/; images
# live here and are fetched on demand via
# `services/preprocess/scripts/fetch_fixtures.py`. No prod mirror:
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
#   2. LOGIN STATUS CODES CARRY MEANING (as of NEO-98). Both login routes in
#      services/browser/src/index.ts now answer:
#         422 — the marketplace processed the credentials and refused them,
#               or the stored secret was incomplete. The seller's problem.
#               4xx, so no policy here matches it. NEVER pages.
#         502 — we could not complete the exchange: the marketplace returned
#               something unusable, was unreachable, or served a block page.
#         500 — an uncaught throw in our own code.
#      Previously a bad BSC password returned 500 and the equivalent SportLots
#      failure returned 400, which is why the hang policy below used to filter
#      to 499|502|503|504 and EXCLUDE 500 — leaving it with no crash coverage,
#      since a container dying mid-request was indistinguishable from a typo.
#      With 500 now meaning only "our code broke", the policy matches all 5xx.
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
#
# WHY THE FILTER IS >=400 AND NOT >=499: an audit of 30 days of prod request
# logs (2026-07-26) found 19 requests to /login/*, ALL of them HTTP 200 — not
# one non-2xx. So the status set the hang policy matches (499 + 5xx) is still
# an UNVERIFIED HYPOTHESIS: there is no observed example of what Cloud Run
# records when Convex aborts at 60s, and if it turns out to be something else
# the policy would silently never fire.
#
# Capturing from 400 costs nothing (log-based metrics over already-ingested
# logs are free) and builds the evidence base to tune against. It is also now
# the only place the 422 rejection volume shows up, which is worth having:
# a sudden collapse in 422s is itself a signal that logins stopped reaching
# the marketplace at all. The policy never matches 4xx, so this stays
# observability-only and adds no pages. Revisit once real non-2xx data exists.
resource "google_logging_metric" "browser_login_http_status" {
  count   = var.enable_browser_login_alerts ? 1 : 0
  project = var.gcp_project_id
  name    = "browser_login_http_status"

  filter = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${var.cloud_run_service_name}"
    logName="projects/${var.gcp_project_id}/logs/run.googleapis.com%2Frequests"
    httpRequest.requestUrl=~"/login/(bsc|sportlots)$"
    httpRequest.status>=400
  EOT

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Browser login request failures (Cloud Run edge)"

    labels {
      key        = "status"
      value_type = "STRING"
      # ⚠️ DO NOT EDIT THIS DESCRIPTION.
      #
      # Any change inside a `labels` block is ForceNew on
      # google_logging_metric — including the description text alone, with
      # `key` and `value_type` untouched. Terraform destroys and recreates the
      # metric. Log-based metrics do NOT backfill, so the recreated series
      # starts empty and every alert policy built on it goes quiet until new
      # data accumulates. At current volumes (19 /login/* requests in 30 days)
      # that is a long blind window for a one-line doc tweak.
      #
      # NEO-98 tried to update this wording and the prod plan came back
      # "1 to destroy" — reverted, deliberately.
      #
      # The text below therefore predates NEO-98 and is knowingly stale. Since
      # NEO-98: a credential rejection is 422 (4xx — never matched by any
      # policy here), 500 means only an uncaught throw in our own code, and
      # 502 means an upstream marketplace fault. Correct the wording only when
      # the metric is being recreated for some independent reason.
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
    container died. 502 = the marketplace returned something we could not
    use (outage, block page, changed login flow). 500 = an uncaught throw in
    our own code. 422 = the seller's credentials were refused — expected
    traffic, not an incident, and no policy matches it.

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

    502 means we reached the marketplace but could not complete the login
    exchange — an outage, a block page, or a changed login flow on their
    side. Check the browser_login_call line's `error_class` and the PostHog
    diagnostic to see what page was actually served.

    500 means an uncaught throw in our own code, or a container that died
    mid-request. Since NEO-98 a rejected password returns 422 and never
    reaches this policy, so a 500 here is always ours — start with the
    revision's stderr rather than assuming a seller mistyped something.

    ${local.neo43_runbook_common}
  EOT

  neo43_doc_latency = <<-EOT
    # Login latency degrading — $${metric.label.platform}

    p99 login duration on **$${metric.label.platform}** exceeded
    ${var.browser_login_latency_threshold_ms}ms over 10 minutes. Convex hard-aborts at
    60s, so logins are close to failing outright.

    Measured baseline from prod logs (2026-07-26, 30d): BSC 2.5-3.3s,
    SportLots 1.2-1.5s. A cold start on the ~1GB image adds several seconds on
    top (min-instances=0 is intentional, NEO-95). Anything in the tens of
    seconds is far outside normal.

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
    1. Did the canary actually stop, or is only ONE SERIES quiet? Confirm with
       the metric grouped by platform:
       `logging.googleapis.com/user/browser_login_duration_ms`,
       `metric.label.canary="true"`. If canary logins are still landing every
       30 minutes, this alert is lying — see the note below.
    2. `gcloud scheduler jobs list --location=${var.gcp_region} --project=${var.gcp_project_id}`
       — are the jobs present and ENABLED (not PAUSED)?
    3. The Scheduler job's own error log:
       `resource.type="cloud_scheduler_job"` — an attempt abandoned at the
       180s deadline is recorded here even when the service logs nothing.
    4. Whether anyone paused the canary during an incident and forgot to
       re-enable it.

    If this alert names a `revision_name` that is NOT the revision currently
    serving traffic, treat it as a false positive and check the condition's
    aggregation. Before NEO-153 this condition had no `group_by_fields`, so
    Monitoring kept one series PER CLOUD RUN REVISION: every deploy left the
    outgoing revision permanently silent and fired this alert 90 minutes later,
    several times a day, while the canary was perfectly healthy. The fix groups
    on `metric.label.platform` so absence means "no canary login on ANY
    revision". If revision-scoped alerts reappear, that grouping has regressed.

    ${local.neo43_runbook_common}
  EOT
}

# --- Alert policies ---------------------------------------------------------
#
# Shared conventions across all four, each load-bearing at this traffic level:
#
#   duration = "0s" + trigger.count = 1 — never require N CONSECUTIVE
#     violating windows. The second window may have no data at all, so a
#     duration-based condition could sit un-fired straight through an outage.
#
#   NO evaluation_missing_data — and this is FORCED, not a preference. The
#     Monitoring API rejects the combination outright:
#       "Conditions setting evaluation_missing_data must have a non-zero
#        duration."
#     (Learned the hard way: a prod apply failed on exactly this. Note that
#     `terraform validate` cannot catch it — it is a server-side semantic
#     rule, not a schema rule, so it passes plan and fails apply.)
#
#     Given the forced choice, duration="0s" wins. With alignment_period=300s
#     a non-zero duration means "violating across consecutive 5-minute
#     windows", and at this traffic level the next window routinely has no
#     data at all — so a genuine burst would open no incident. Failing to fire
#     during an outage is far worse than an incident lingering.
#
#     What we give up is the explicit "no data ⇒ not violating" declaration;
#     the default is that missing data does not change the condition state.
#     auto_close (below) covers the resulting stuck-incident risk.
#
#   auto_close = 1800s — the API minimum, and now doing double duty: it both
#     keeps burst counters from holding an incident open (a still-open
#     incident swallows the next burst's notification entirely) AND closes
#     incidents once data stops, which is what evaluation_missing_data would
#     otherwise have handled.
#
#   NO notification_rate_limit — also FORCED. The API rejects it:
#     "only log-based alert policies may specify a notification rate limit."
#     "Log-based" there means a condition_matched_log policy; these are
#     metric-threshold policies over log-BASED METRICS, which is a different
#     thing. Another apply-time-only failure (see the note above).
#
#     Little is lost. A metric-threshold policy notifies on incident OPEN and
#     on CLOSE — it does not re-notify on a loop while an incident stays open,
#     which is what a rate limit would have guarded against. With
#     auto_close=1800s the worst case during a sustained outage is roughly one
#     open/close pair per 30 minutes, which is about what the 1h cap was
#     approximating anyway.
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
    }
  }

  notification_channels = [google_monitoring_notification_channel.ops_email[0].id]

  alert_strategy {
    auto_close = "1800s"
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
    display_name = "Any 499 or 5xx on a /login/* request in 5m"

    condition_threshold {
      filter = join(" AND ", [
        # Interpolated so Terraform creates the metric first — see the note on
        # the failures policy above.
        "metric.type=\"logging.googleapis.com/user/${google_logging_metric.browser_login_http_status[0].name}\"",
        "resource.type=\"cloud_run_revision\"",
        # 499 + ALL 5xx. NEO-98 moved credential rejections to 422, so no 5xx
        # on this path can be produced by user input any more and 500 is safe
        # to include — which is the whole point: it is the status a container
        # crash or an uncaught throw actually returns, and excluding it left
        # this policy with no crash coverage at all.
        "metric.label.status=monitoring.regex.full_match(\"499|5[0-9][0-9]\")",
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
    }
  }

  notification_channels = [google_monitoring_notification_channel.ops_email[0].id]

  alert_strategy {
    auto_close = "1800s"
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
    }
  }

  notification_channels = [google_monitoring_notification_channel.ops_email[0].id]

  alert_strategy {
    auto_close = "1800s"
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

      # NEO-153: group_by_fields here is LOAD-BEARING, not tidiness.
      #
      # Without a cross_series_reducer + group_by_fields, Monitoring keys the
      # series on the FULL label set — which includes
      # resource.labels.revision_name. Every browser deploy creates a new Cloud
      # Run revision; the outgoing revision stops emitting canary logs the
      # moment traffic moves; 90 minutes later this detector fires for a
      # revision that is dead by design. Alert frequency therefore tracked
      # DEPLOY frequency rather than service health — it was firing several
      # times a day while the canary sat at 48/48 success on both platforms.
      #
      # Grouping on platform alone collapses every revision into one series per
      # platform, so absence means what it is supposed to mean: no canary login
      # completed for that marketplace on ANY revision.
      #
      # The other three NEO-43 policies already do this (failures, HTTP status,
      # latency). This one was the sole omission, and absence is the one
      # condition type where omitting it produces FALSE POSITIVES rather than a
      # harmless split — a series going quiet IS the entire signal.
      #
      # ALIGN_PERCENTILE_99 + REDUCE_MAX rather than ALIGN_DELTA + REDUCE_SUM:
      # this is the exact aggregation the latency policy above already applies
      # to THIS metric, so it is proven API-valid in this project. That matters
      # because provider-valid is not API-valid here — ALIGN_COUNT on
      # DELTA/DISTRIBUTION was rejected at apply time, which is why the aligner
      # was ALIGN_DELTA to begin with, and summing distributions across series
      # is not proven. A percentile aligner still emits NO point when the series
      # has no data, which is all absence detection needs; the aligned value
      # itself is never compared against anything.
      aggregations {
        alignment_period     = "600s"
        per_series_aligner   = "ALIGN_PERCENTILE_99"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["metric.label.platform"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.ops_email[0].id]

  alert_strategy {
    auto_close = "1800s"
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

# retry_count = 0 is load-bearing, not a default — but NOT for rate-limit or
# anti-abuse reasons. Neither BSC nor SportLots throttles logins, and there is
# no such thing as BSC "bot protection"; that belief has been raised and
# disproven repeatedly on this project, and anywhere it survives in a comment
# it should be treated as wrong.
#
# The real reason is monitoring correctness. Scheduler retries would hide an
# intermittently-failing marketplace behind a green canary — the canary would
# quietly succeed on attempt 2 and report nothing, which is the exact opposite
# of what a probe is for. One attempt per run means every failure is visible;
# genuine one-off blips are absorbed by the alert policy, which needs repeated
# failures before it fires.
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

output "secret_gc_service_account_email" {
  description = "Email of the Secret Manager version GC service account (NEO-115). Hardcoded in the monorepo's secret-version-gc.yml matrix rather than stored as a GitHub secret — an SA email is not sensitive, and the workflow already carries the project IDs in plaintext."
  value       = google_service_account.secret_gc.email
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

output "placeholder_uploads_bucket_name" {
  description = "Name of the placeholder-uploads GCS bucket (NEO-148; set as GCS_PLACEHOLDER_BUCKET Convex env var)"
  value       = var.create_placeholder_bucket ? google_storage_bucket.placeholder_uploads[0].name : ""
}

output "preprocess_fast_runtime_service_account_email" {
  description = "Email of the preprocess FAST runtime service account (NEO-175)"
  value       = google_service_account.preprocess_fast_runtime.email
}

output "preprocess_fast_cloud_run_url" {
  description = "URL of the deployed preprocess FAST Cloud Run service (NEO-175; set as NEONBINDER_PREPROCESS_FAST_URL Convex env var)"
  value       = google_cloud_run_service.neonbinder_preprocess_fast.status[0].url
}

