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

# Service Account Configuration
variable "service_account_name" {
  description = "Name for the service account"
  type        = string
  default     = "neonbinder-browser-runner"
}

variable "service_account_display_name" {
  description = "Display name for the service account"
  type        = string
  default     = "Neon Binder Browser Automation Runner"
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