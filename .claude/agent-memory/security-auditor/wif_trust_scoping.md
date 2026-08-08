---
name: WIF Trust Scoping Posture
description: Deployer SA WIF principalSets are repo-scoped, so "workflow X now uses SA Y" is not a new privilege boundary in the monorepo — audit heuristic for CI PRs
metadata:
  type: project
---

All GitHub Actions deployer SAs bind `roles/iam.workloadIdentityUser` on
`attribute.repository/<owner/repo>`, not on `attribute.job_workflow_ref`. The
one exception is the secret-GC SA (`secret_gc_workflow_ref`), which is
workflow-ref pinned.

`github_repo_monorepo` and `github_repo_preprocess` both resolve to
`neonbinder/neonbinder` post-NEO-123, so the browser and preprocess deployer SAs
are reachable from *any* workflow in the monorepo, in both prod and dev.

**Why:** it means a CI PR that wires an existing deployer SA into an additional
workflow in the same repo does **not** widen the trust boundary — the SA was
already assumable there. Reporting that as a new finding is a false positive.

**How to apply:** when auditing a workflow change that adds `secrets[...]` WIF
auth for an SA, first check `main.tf` for that SA's `google_service_account_iam_member`
member string. If it is `attribute.repository/...`, the exposure is pre-existing;
the only real finding would be that the *narrowing* to `job_workflow_ref` is
still untracked. If it is `attribute.job_workflow_ref/...`, then adding a new
workflow genuinely requires a terraform change and is worth flagging.

Related: [[terraform_iam_findings]], [[credential_architecture]]
