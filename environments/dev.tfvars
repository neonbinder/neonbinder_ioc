gcp_project_id         = "neonbinder-dev"
environment            = "dev"
cloud_run_service_name = "neonbinder-browser"
cloud_run_image        = "gcr.io/neonbinder-dev/neonbinder-browser:latest"
preprocess_image       = "gcr.io/neonbinder-dev/neonbinder-preprocess:latest"
# NEO-299: single source of truth is apps/web/convex/preprocessCapacity.json
# (heavy.dev, fast.dev) — the terraform.yml parity check compares this file
# against it on every plan/apply. See variables.tf for the quota arithmetic.
heavy_preprocess_max_instances    = 6
preprocess_max_instances          = 3
create_prizes_bucket              = false
create_preprocess_fixtures_bucket = true
create_placeholder_bucket         = true
wif_branch_ref                    = "refs/heads/develop"
# Dev-only: accept PR OIDC tokens so per-PR browser + preprocess previews can
# deploy. Keep disabled in prod (default false).
browser_wif_allow_pull_requests    = true
preprocess_wif_allow_pull_requests = true
developer_emails = [
  "neonbinder@neonbinder.io",
]
common_labels = {
  project     = "neonbinder"
  environment = "development"
  managed_by  = "terraform"
}
