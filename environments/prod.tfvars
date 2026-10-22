gcp_project_id         = "neonbinder"
environment            = "prod"
cloud_run_service_name = "neonbinder-browser"
cloud_run_image        = "gcr.io/neonbinder/neonbinder-browser:latest"
preprocess_image       = "gcr.io/neonbinder/neonbinder-preprocess:latest"
# NEO-299: single source of truth is apps/web/convex/preprocessCapacity.json
# (heavy.prod, fast.prod) — the terraform.yml parity check compares this file
# against it on every plan/apply. See variables.tf for the quota arithmetic.
heavy_preprocess_max_instances = 12
preprocess_max_instances       = 20
create_prizes_bucket           = true
create_placeholder_bucket      = true
wif_branch_ref                 = "refs/heads/main"
# NEO-95: billing budget is billing-account-scoped, not project-scoped — only
# enable it here (prod apply) so it's created exactly once, not once per env.
enable_billing_budget = true
# NEO-43: browser-service login alerting — prod only. Dev's E2E suites fail
# logins deliberately, so dev alerting would be a false-positive generator.
enable_browser_login_alerts = true
cross_env_tf_deployer_emails = [
  "neonbinder-tf-deployer@neonbinder-dev.iam.gserviceaccount.com",
]
common_labels = {
  project     = "neonbinder"
  environment = "production"
  managed_by  = "terraform"
}
# NEO-43 item 4: synthetic login canary — prod only.
# Credential secrets seeded 2026-07-27 (one enabled version each), so the
# canary is live. Unpausing also brings up the canary-absence alert policy,
# which is gated on the canary actually running — a paused canary emits
# nothing, so that policy alongside a paused job would be a guaranteed false
# alarm.
enable_login_canary = true
login_canary_paused = false
# SportLots is down again (2026-10-20): pause just its canary, as NEO-287 did
# on 2026-09-17. BSC's job and its absence detector keep running. Unpause by
# setting this back to [] once SportLots is back and a manual login has been
# re-verified. See browser_login_canary_absent in main.tf.
login_canary_paused_platforms = ["sportlots"]
