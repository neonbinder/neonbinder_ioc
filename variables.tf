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

variable "gcp_zone" {
  description = "GCP Zone (for resources that need it)"
  type        = string
  default     = "us-central1-a"
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
  default     = "1Gi"
}

variable "cloud_run_max_instances" {
  description = "Maximum number of instances for Cloud Run service"
  type        = number
  default     = 10
}

# GitHub Actions
variable "github_repo" {
  description = "GitHub repository (owner/repo) allowed to authenticate via WIF"
  type        = string
  default     = "neonbinder/neonbinder_browser"
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
