# Neon Binder Terraform Infrastructure

This repository contains Terraform configuration for provisioning the infrastructure for the Neon Binder project, including GCP resources for browser automation and site scraping.

## Architecture

- **GCP Resources**: Service accounts, Cloud Run service, IAM permissions
- **Browser Automation**: Cloud Run service for running browser automation tasks
- **Security**: Service account with minimal required permissions

## Prerequisites

1. **Terraform** (v1.0+)
2. **Google Cloud SDK** with authentication

### Installing Prerequisites

```bash
# Install Terraform (macOS)
brew install terraform

# Install Google Cloud SDK
# Follow instructions at: https://cloud.google.com/sdk/docs/install

# Authenticate with Google Cloud
gcloud auth application-default login
```

## Setup

1. **Clone the repository**:
   ```bash
   git clone <repository-url>
   cd neonbinder_terraform
   ```

2. **Configure variables** (optional - defaults are provided):
   ```bash
   # Edit variables.tf or set environment variables
   export TF_VAR_gcp_project_id="your-project-id"
   ```

3. **Initialize Terraform**:
   ```bash
   terraform init
   ```

4. **Plan the deployment**:
   ```bash
   terraform plan
   ```

5. **Apply the configuration**:
   ```bash
   terraform apply
   ```

## How It Works

### GCP Resources

- **Service Account**: `neonbinder-browser-runner` with appropriate IAM roles for:
  - Secret Manager access
  - Cloud Run invocation
  - Logging
- **Cloud Run Service**: `neonbinder-browser` for running browser automation tasks
- **IAM Permissions**: Proper role bindings for secure access

## Files

- `main.tf` - Main Terraform configuration
- `variables.tf` - Variable definitions
- `.gitignore` - Excludes Terraform state and output files

## Outputs

After successful deployment, Terraform will output:

- `service_account_email` - Email of the created service account
- `cloud_run_url` - URL of the Cloud Run service

## Security

- Service account has minimal required permissions
- Cloud Run service is publicly accessible (can be restricted if needed)
- IAM roles follow principle of least privilege

## Troubleshooting

### Terraform Issues

1. Ensure you have the correct GCP project set: `gcloud config get-value project`
2. Verify authentication: `gcloud auth list`
3. Check Terraform version: `terraform version`

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

**Note**: This will delete all GCP resources including the service account and Cloud Run service.

## 🔧 Common Commands

```bash
# Initialize Terraform
terraform init

# Plan changes
terraform plan

# Apply changes
terraform apply

# Show current state
terraform show

# List resources
terraform state list

# Import existing resources
terraform import google_service_account.neonbinder_browser projects/neonbinder/serviceAccounts/neonbinder-browser-runner@neonbinder.iam.gserviceaccount.com

# Refresh state
terraform refresh

# Validate configuration
terraform validate
```

## 🚨 Troubleshooting

### Common Issues

1. **Permission Denied**
   ```bash
   # Ensure you have the right roles
   gcloud projects add-iam-policy-binding neonbinder \
     --member="user:your-email@domain.com" \
     --role="roles/editor"
   ```

2. **Convex API Key Issues**
   ```bash
   # Verify your API key
   convex whoami
   ```

3. **Service Account Already Exists**
   ```bash
   # Import existing service account
   terraform import google_service_account.neonbinder_browser projects/neonbinder/serviceAccounts/neonbinder-browser-runner@neonbinder.iam.gserviceaccount.com
   ```

## 📚 Next Steps

After running Terraform:

1. **Deploy your application**:
   ```bash
   npm run deploy
   ```

2. **Set up your Convex functions**:
   ```bash
   cd ../convex
   convex dev
   ```

3. **Create site-specific secrets**:
   ```bash
   # Create secrets for your card sites
   gcloud secrets create bsc-credentials --data-file=credentials.json
   gcloud secrets create sportlots-credentials --data-file=credentials.json
   ```

## 🤝 Contributing

When making changes to the Terraform configuration:

1. Always run `terraform plan` first
2. Test changes in a development environment
3. Update this README if adding new resources
4. Use meaningful variable names and descriptions 