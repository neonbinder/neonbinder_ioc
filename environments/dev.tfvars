gcp_project_id         = "neonbinder-dev"
environment            = "dev"
cloud_run_service_name = "neonbinder-browser"
cloud_run_image        = "gcr.io/neonbinder-dev/neonbinder-browser:latest"
preprocess_image       = "gcr.io/neonbinder-dev/neonbinder-preprocess:latest"
create_prizes_bucket              = false
create_preprocess_fixtures_bucket = true
# Dev-only: read-only Cloud Run reader SA + WIF provider so the neonbinder_web
# e2e workflow can discover per-PR browser previews (NEO-35). Never in prod.
create_convex_e2e_reader          = true
wif_branch_ref         = "refs/heads/develop"
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
