---
name: Credential Architecture Overview
description: How marketplace credentials flow through NeonBinder infrastructure - GCP Secret Manager, Cloud Run browser service, Convex backend, encryption patterns
type: project
---

## Credential Flow Architecture

### Service Accounts
- **neonbinder-browser-runtime**: Cloud Run browser service. Accesses Secret Manager for internal-api-key. Should be read-only.
- **neonbinder-browser-deployer**: GitHub Actions CI/CD for browser repo. Deploys to Cloud Run, pushes images.
- **neonbinder-convex**: Convex backend. Accesses GCS (prizes bucket) and Secret Manager (marketplace credentials).
- **neonbinder-tf-deployer**: Terraform CI/CD. Manages all above resources.

### Secret Manager
- `internal-api-key`: Authenticates Convex -> browser service requests. Static, needs rotation procedure.
- Marketplace credentials stored by Convex SA (per CLAUDE.md, via `convex/adapters/secret_manager.ts`).

### Cloud Run Browser Service
- Publicly accessible (`allUsers` invoker) due to Convex limitation (cannot do GCP IAM auth).
- Protected by `INTERNAL_API_KEY` header (timing-safe comparison per comment in main.tf).
- Handles user marketplace credentials during Puppeteer automation sessions.
- Service account: `neonbinder-browser-runtime`.

### Projects
- Dev: `neonbinder-dev-io` (project number 874494136386)
- Prod: `neonbinder-484017` (project number 211831470630)

### WIF Configuration
- Pool: `github-actions` (shared between browser and terraform repos)
- Providers: `github` (browser repo, branch-restricted), `github-terraform` (terraform repo, branch-restricted)
- Dev allows `refs/heads/develop`, prod allows `refs/heads/main`.

**Why:** Understanding this architecture is essential for evaluating any change that touches credential handling or IAM.

**How to apply:** Reference this when reviewing any PR that modifies service accounts, Secret Manager access, or the browser service authentication flow.
