---
name: Terraform IAM Over-Provisioning Findings
description: Critical and high severity IAM issues in neonbinder_terraform main.tf - TF deployer has securityAdmin, runtime SA has project-level secret access, deployer has project-level storage.admin
type: project
---

## Terraform IAM Audit (2026-03-18)

**Status:** NOT APPROVED - requires remediation

### Critical Issues
1. TF deployer SA (`neonbinder-tf-deployer`) has `roles/iam.securityAdmin` at project level (main.tf:319-323). Can setIamPolicy on all resources, full privilege escalation path.
2. TF deployer also has project-level `roles/iam.serviceAccountUser` (main.tf:349-353) -- can impersonate any SA in the project.

### High Issues
3. Runtime SA has project-level `roles/secretmanager.secretAccessor` AND `secretVersionManager` (main.tf:45-55) despite having resource-level binding on internal-api-key (main.tf:159-163). Project-level is redundant and over-broad.
4. Runtime SA should NOT have `secretVersionManager` -- browser service should only read secrets, not write.
5. Convex SA has project-level `secretVersionManager` (main.tf:118-122) -- evaluate if write access is needed.
6. Browser deployer SA has project-level `roles/storage.admin` (main.tf:87-91) -- over-broad for container pushes.

### CI/CD Issue
7. PR comment in terraform.yml uses direct interpolation of plan output (`${{ steps.plan.outputs.stdout }}`), creating a script injection vector.

### Cloud Run
8. `cloud_run_max_instances` variable defined but never used in the Cloud Run resource -- no max scale protection.
9. Public access + static API key is single-factor auth for a service handling user credentials.

**Why:** This infrastructure manages access to marketplace credentials (eBay, SportLots, etc). Over-broad IAM means a single compromise can access all user credentials.

**How to apply:** Any PR modifying IAM in this repo must be checked against these findings. Verify project-level roles are being narrowed, not expanded.
