gcp_project_id         = "neonbinder-dev"
environment            = "dev"
cloud_run_service_name = "neonbinder-browser"
cloud_run_image        = "gcr.io/neonbinder-dev/neonbinder-browser:latest"
preprocess_image       = "gcr.io/neonbinder-dev/neonbinder-preprocess:latest"
create_prizes_bucket   = false
wif_branch_ref         = "refs/heads/develop"
# Dev-only: accept PR OIDC tokens so per-PR browser previews can deploy.
browser_wif_allow_pull_requests = true
developer_emails = [
  "neonbinder@neonbinder.io",
]
common_labels = {
  project     = "neonbinder"
  environment = "development"
  managed_by  = "terraform"
}
