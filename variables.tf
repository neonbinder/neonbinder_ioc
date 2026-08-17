# GCP Configuration
variable "gcp_project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "neonbinder"
}

variable "gcp_region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

# Environment
variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be 'dev' or 'prod'."
  }
}

# Cloud Run Configuration
variable "cloud_run_service_name" {
  description = "Name for the Cloud Run service"
  type        = string
  default     = "neonbinder-browser"
}

variable "cloud_run_image" {
  description = "Docker image for Cloud Run service"
  type        = string
  default     = "gcr.io/neonbinder/neonbinder-browser:latest"
}

variable "cloud_run_cpu" {
  description = "CPU allocation for Cloud Run service"
  type        = string
  default     = "2000m"
}

variable "cloud_run_memory" {
  description = "Memory allocation for Cloud Run service"
  type        = string
  default     = "4Gi"
}

variable "cloud_run_container_concurrency" {
  description = "Max concurrent requests per browser container. Puppeteer spawns one Chromium process per request; keep low to bound per-instance memory."
  type        = number
  default     = 3
}

variable "cloud_run_min_instances" {
  description = "Minimum warm instances for the browser service. Set to 1 in both dev and prod to eliminate Puppeteer/Chromium cold-start (a recurring source of 30–60s latency in BSC token fetches and the variantType auto-sync). Costs ~$10/mo per environment to keep one 4Gi/2CPU instance warm."
  type        = number
  default     = 1
}

variable "cloud_run_max_instances" {
  description = "Maximum Cloud Run instances for the browser service. Capped to bound memory/cost during traffic bursts; raise if legitimate concurrency exceeds this."
  type        = number
  default     = 20
}

# GitHub Actions
# NEO-18 cutover: the old neonbinder_browser repo was archived and this is now
# the sole repo trusted for browser deploy / per-PR Cloud Run preview WIF auth.
variable "github_repo_monorepo" {
  description = "Consolidated monorepo (owner/repo) allowed to authenticate via WIF for browser deploy / per-PR Cloud Run preview"
  type        = string
  default     = "neonbinder/neonbinder"
}

variable "github_repo_terraform" {
  description = "GitHub repository (owner/repo) for Terraform CI/CD via WIF"
  type        = string
  default     = "neonbinder/neonbinder_ioc"
}

# NEO-123 cutover: the preprocess service moves into the monorepo as
# services/preprocess, and neonbinder_preprocess is archived once the monorepo
# deploy is proven green. This value is repo-scoped and feeds BOTH
# the provider attribute_condition (token minting) and the deployer SA's
# principalSet binding (impersonation) — they must always agree, which is why
# they read one variable rather than two literals.
#
# Kept as a distinct variable from github_repo_monorepo even though both now
# hold "neonbinder/neonbinder": the github-preprocess provider stays separate
# from the github provider so the two deploy lanes can be trusted, scoped, or
# revoked independently.
variable "github_repo_preprocess" {
  description = "GitHub repository (owner/repo) for the preprocess service CI/CD via WIF"
  type        = string
  default     = "neonbinder/neonbinder"
}

# Preprocess Cloud Run configuration
variable "preprocess_service_name" {
  description = "Name for the preprocess Cloud Run service"
  type        = string
  default     = "neonbinder-preprocess"
}

variable "preprocess_image" {
  description = "Docker image for the preprocess Cloud Run service (first-apply placeholder; CI manages image tags thereafter)"
  type        = string
  default     = "gcr.io/neonbinder/neonbinder-preprocess:latest"
}

variable "preprocess_cpu" {
  description = "CPU allocation for the preprocess Cloud Run service"
  type        = string
  default     = "4000m"
}

variable "preprocess_memory" {
  # 8Gi since NEO-161: the tiered crop strategy holds a ~930MB BiRefNet ONNX
  # session (~2.5GB resident with ORT arenas) alongside torch, and startup
  # warm-up OOMed the previous 4Gi limit (4601MiB used at boot).
  description = "Memory allocation for the preprocess Cloud Run service"
  type        = string
  default     = "8Gi"
}

variable "preprocess_container_concurrency" {
  description = "Max concurrent requests per preprocess container"
  type        = number
  default     = 3
}

variable "preprocess_max_instances" {
  description = "Max Cloud Run instances for the preprocess service"
  type        = number
  default     = 3
}

variable "wif_branch_ref" {
  description = "Git branch ref allowed for WIF authentication on the TERRAFORM provider only (e.g. refs/heads/main). Set per-env: refs/heads/develop in dev, refs/heads/main in prod, because this repo is GitFlow. The browser and preprocess providers each use their own `*_wif_branch_ref` because both deploy from the trunk-based monorepo — main is the only deploy ref regardless of env."
  type        = string
  default     = "refs/heads/main"
}

variable "browser_wif_branch_ref" {
  description = "Git branch ref allowed for WIF authentication on the browser WIF provider. Always `refs/heads/main` in both envs because the browser repo is trunk-based: the same push-to-main workflow auths to dev WIF (build-push pushes to dev GCR + deploy-dev) and then prod WIF (retag/push + blue/green deploy-prod)."
  type        = string
  default     = "refs/heads/main"
}

variable "secret_gc_workflow_ref" {
  description = "GitHub `job_workflow_ref` claim allowed to impersonate the neonbinder-secret-gc SA (NEO-115). Format is `owner/repo/.github/workflows/<file>@<ref>`. The ref is the branch the workflow FILE is loaded from — the default branch for both `schedule` and `workflow_dispatch` — not the branch a deploy is allowed from."
  type        = string
  default     = "neonbinder/neonbinder/.github/workflows/secret-version-gc.yml@refs/heads/main"
}

variable "browser_wif_allow_pull_requests" {
  description = "If true, the neonbinder_browser WIF provider also accepts pull_request OIDC tokens (in addition to push to wif_branch_ref). Enable in dev so per-PR preview deployments can authenticate; keep disabled in prod. Workflow-level guards must still restrict PR previews to same-repo branches."
  type        = bool
  default     = false
}

variable "preprocess_wif_branch_ref" {
  description = "Git branch ref allowed for WIF authentication on the preprocess WIF provider. Always `refs/heads/main` in both envs because preprocess now deploys from the trunk-based monorepo (NEO-123), same as browser: a single push-to-main workflow auths to dev WIF (build+push to dev GCR + deploy-dev) and then prod WIF (retag/push + blue/green deploy-prod)."
  type        = string
  default     = "refs/heads/main"
}

variable "preprocess_wif_allow_pull_requests" {
  description = "If true, the preprocess WIF provider also accepts pull_request OIDC tokens (in addition to push to preprocess_wif_branch_ref). Enable in dev so per-PR preview deployments can authenticate; keep disabled in prod. Workflow-level guards must still restrict PR previews to same-repo branches."
  type        = bool
  default     = false
}

# Conditional resources
variable "create_prizes_bucket" {
  description = "Whether to create the prizes GCS bucket (prod only)"
  type        = bool
  default     = true
}

variable "create_preprocess_fixtures_bucket" {
  description = "Whether to create the preprocess test-fixture GCS bucket (dev only). Test images for the `services/preprocess` integration tests live here — too large to commit to git. Not needed in prod."
  type        = bool
  default     = false
}

# NEO-148: unlike create_prizes_bucket (prod only), this is set true in BOTH
# dev.tfvars and prod.tfvars — the placeholder pairing-review feature must be
# developable in dev, not just live in prod. Default is false (matching
# create_prizes_bucket / create_preprocess_fixtures_bucket's convention of
# defaulting off and opting each environment in explicitly via .tfvars)
# rather than true — both tfvars files already set it explicitly, so this
# only changes what a THIRD, not-yet-existing environment would get by
# default: nothing, until someone deliberately opts it in.
variable "create_placeholder_bucket" {
  description = "Whether to create the placeholder-uploads GCS bucket (dev + prod)."
  type        = bool
  default     = false
}

# NEO-95: the google_billing_budget resource is scoped to the BILLING ACCOUNT,
# not a project — it must be created exactly once, not once per environment
# apply. Gate it behind this flag and only set it true in prod.tfvars, so the
# prod apply is the single apply that creates it (it still covers spend across
# both the neonbinder and neonbinder-dev projects via budget_filter.projects).
variable "enable_billing_budget" {
  description = "Whether to create the billing-account-scoped budget/alert resource. Must be true in exactly one environment (prod) since google_billing_budget is not project-scoped."
  type        = bool
  default     = false
}

variable "cross_env_tf_deployer_emails" {
  description = "TF-deployer SA emails from OTHER environments that need access to this environment's shared state bucket. Set in prod.tfvars to grant the dev tf-deployer access to the prod-hosted state bucket; empty in dev."
  type        = list(string)
  default     = []
}

# NEO-43: production alerting for browser-service marketplace login failures
# and hangs. Today nothing notifies anyone when SportLots/BSC login breaks —
# a seller reports it, or we notice while running E2E (which is literally how
# the ~10-minute SportLots login hang that prompted this ticket was found).
#
# Prod only. Dev deliberately gets neither the alert policies nor the IAM:
# dev's E2E suites exercise bad credentials on purpose, so dev would be a
# permanent false-positive generator, and the whole point is a channel that
# stays quiet until something is genuinely wrong.
variable "enable_browser_login_alerts" {
  description = "Whether to create the NEO-43 browser-service login alerting stack (notification channel, log-based metrics, alert policies) and the tf-deployer IAM it requires. True only in environments/prod.tfvars — dev intentionally has no login alerting because its E2E suites fail logins deliberately."
  type        = bool
  default     = false
}

variable "alert_notification_email" {
  description = "Destination for NEO-43 browser-service login alerts. NeonBinder is a single-operator project, so this is the operator mailbox rather than a rotation. Note this address will receive alert bodies containing marketplace/platform names and error classes — no credentials or page content (see the redaction rules in services/browser/src/services/login-diagnostic.ts)."
  type        = string
  default     = "neonbinder@neonbinder.io"
}

# Ceiling, not a target. MEASURED from prod browser_login_call logs
# (2026-07-26, 30-day window): BSC 2.5-3.3s, SportLots 1.2-1.5s — comfortably
# faster than the estimates this was first drafted against. But
# prod-login-probe does a REAL login against a cold, freshly deployed revision
# on every push to main, and the repo's own test helper documents that at
# 20-30s — so a 30s threshold would false-positive on every deploy. The upper
# bound is Convex's 60s hard abort, past which the login is already a
# user-visible failure caught by the hang policy. 45s sits above every
# legitimate case and below the user-visible cliff.
variable "browser_login_latency_threshold_ms" {
  description = "p99 login duration (ms) above which the NEO-43 latency policy fires. 45000 by default: above the worst legitimate case (a cold-start deploy probe at 20-30s) and below Convex's 60s abort, so it fires while the system is degrading rather than after it has already failed."
  type        = number
  default     = 45000
}

# NEO-43 item 4 — synthetic login canary.
#
# Prod only, and separately gated from the alert policies so the canary can be
# rolled out (or rolled back) without touching the alerting itself. Dev is
# excluded because its per-PR and per-push login probes already exercise this
# code on every change — a dev canary would add cost and log noise for no new
# signal.
#
# NOTE: neither BSC nor SportLots rate-limits or "bot protects" logins. Do not
# reintroduce that rationale here — it has been raised and disproven
# repeatedly on this project, and it drives needlessly timid design.
variable "enable_login_canary" {
  description = "Whether to create the NEO-43 synthetic marketplace-login canary (dedicated invoker SA, credential secret shells, and two Cloud Scheduler jobs). Prod only — dev's existing per-PR and per-push login probes already cover dev, so a dev canary would add cost and noise without new signal."
  type        = bool
  default     = false
}

# Kill switch #1 of 3 (the runbook lists all three). Flipping this true and
# merging stops the canary within one apply without destroying the SA, IAM or
# secrets, so re-enabling is a one-line revert. The break-glass lever is
# `gcloud scheduler jobs pause` — but note the NEXT APPLY REVERTS IT, so a
# pause must always be followed by this flag.
variable "login_canary_paused" {
  description = "Pause the NEO-43 login canary jobs without destroying them. Set true to stop the synthetic logins immediately — e.g. while debugging a marketplace-side outage, or when the canary itself is generating noise during an incident, so its failures don't drown the real signal."
  type        = bool
  default     = false
}

# Every 30 minutes per platform, staggered 15 minutes apart. With ~65 min
# worst-case detection (the policy needs repeated failures) this is the right
# trade for a service with no on-call rotation, at ~$3/mo.
#
# The stagger is NOT about marketplace throttling — neither site throttles.
# It is about OUR side: concurrent SportLots logins from the same egress IP
# have produced "Not a valid Email Address" / zero-cookie failures in this
# project before (a shared HTTP-state bug on our end). Keeping the two
# platforms — and the canary vs. CI's deploy-time login probes — from
# overlapping avoids reproducing that, and keeps a canary failure meaning
# "the marketplace broke" rather than "we raced ourselves".
variable "login_canary_schedule_bsc" {
  description = "Cron schedule (UTC) for the NEO-43 BSC login canary. Offset from the SportLots schedule so the two never log in concurrently — concurrent logins have previously exposed a shared-HTTP-state bug on our side, not any marketplace throttling."
  type        = string
  default     = "7,37 * * * *"
}

variable "login_canary_schedule_sportlots" {
  description = "Cron schedule (UTC) for the NEO-43 SportLots login canary. Offset 15 minutes from the BSC schedule so the two never log in concurrently."
  type        = string
  default     = "22,52 * * * *"
}

# MUST stay ≳3x the canary interval or ordinary jitter pages you. Default
# 10800s (3h) matches the hourly ramp-up cadence above; when the schedules are
# tightened to every 30 minutes, tighten this to 5400s (90m) IN THE SAME PR —
# they are one setting expressed in two places.
variable "login_canary_absence_duration" {
  description = "How long the NEO-43 canary may go silent before the absence policy fires. This is the alert that catches a HUNG service — a hung login writes no log line, so silence is the only symptom — but it is meaningless unless the canary is actually running, which is why the policy is also gated on login_canary_paused being false. Keep at roughly 3x the canary interval; 5400s = 3 missed runs at the 30-minute cadence."
  type        = string
  default     = "5400s"
}

variable "login_canary_attempt_deadline" {
  description = "Cloud Scheduler attempt deadline for the NEO-43 canary jobs. Deliberately shorter than the browser service's 300s Cloud Run request timeout so a HUNG login is recorded as a Scheduler failure — a hang detector that does not depend on the service logging anything, since a hung request never writes a browser_login_call line."
  type        = string
  default     = "180s"
}

variable "terraform_state_bucket" {
  description = "GCS bucket holding Terraform state. Lives in prod; dev's tf-deployer needs cross-project access."
  type        = string
  default     = "neonbinder-terraform-state-prod"
}

# Developer access
variable "developer_emails" {
  description = "List of developer emails allowed to impersonate service accounts for local dev"
  type        = list(string)
  default     = []
}

# Tags and Labels
variable "common_labels" {
  description = "Common labels to apply to all resources"
  type        = map(string)
  default = {
    project     = "neonbinder"
    environment = "production"
    managed_by  = "terraform"
  }
}
