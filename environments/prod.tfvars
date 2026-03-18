gcp_project_id         = "neonbinder-484017"
environment            = "prod"
cloud_run_service_name = "neonbinder-browser"
cloud_run_image        = "gcr.io/neonbinder-484017/neonbinder-browser:latest"
create_prizes_bucket   = true
wif_branch_ref         = "refs/heads/main"
common_labels = {
  project     = "neonbinder"
  environment = "production"
  managed_by  = "terraform"
}
