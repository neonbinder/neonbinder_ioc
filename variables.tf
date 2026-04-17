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
  default     = "1000m"
}

variable "cloud_run_memory" {
  description = "Memory allocation for Cloud Run service"
  type        = string
  default     = "2Gi"
}

# GitHub Actions
variable "github_repo" {
  description = "GitHub repository (owner/repo) allowed to authenticate via WIF"
  type        = string
  default     = "neonbinder/neonbinder_browser"
}

variable "github_repo_terraform" {
  description = "GitHub repository (owner/repo) for Terraform CI/CD via WIF"
  type        = string
  default     = "neonbinder/neonbinder_ioc"
}

variable "github_repo_preprocess" {
  description = "GitHub repository (owner/repo) for the preprocess service CI/CD via WIF"
  type        = string
  default     = "neonbinder/neonbinder_preprocess"
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
  description = "Memory allocation for the preprocess Cloud Run service"
  type        = string
  default     = "4Gi"
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
  description = "Git branch ref allowed for WIF authentication (e.g. refs/heads/main)"
  type        = string
  default     = "refs/heads/main"
}

# Conditional resources
variable "create_prizes_bucket" {
  description = "Whether to create the prizes GCS bucket (prod only)"
  type        = bool
  default     = true
}

variable "cross_env_tf_deployer_emails" {
  description = "TF-deployer SA emails from OTHER environments that need access to this environment's shared state bucket. Set in prod.tfvars to grant the dev tf-deployer access to the prod-hosted state bucket; empty in dev."
  type        = list(string)
  default     = []
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
