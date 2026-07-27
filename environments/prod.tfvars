gcp_project_id         = "neonbinder"
environment            = "prod"
cloud_run_service_name = "neonbinder-browser"
cloud_run_image        = "gcr.io/neonbinder/neonbinder-browser:latest"
preprocess_image       = "gcr.io/neonbinder/neonbinder-preprocess:latest"
create_prizes_bucket   = true
wif_branch_ref         = "refs/heads/main"
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
