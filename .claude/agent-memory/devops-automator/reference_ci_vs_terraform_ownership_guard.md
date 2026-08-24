---
name: reference_ci_vs_terraform_ownership_guard
description: pattern for a CI deploy step that must never create the GCP resource it deploys to, when terraform (a separate repo/pipeline) owns creation and may not have applied yet
metadata:
  type: reference
---

**Problem:** a monorepo CI workflow needs to deploy to a Cloud Run service
(or similar) that `neonbinder_terraform` owns creating, but the terraform
apply that creates it may land before, after, or never (relative to a given
CI run). The CI change and the terraform change ship from different repos on
different cadences (monorepo trunk-based vs. terraform's GitFlow), so there's
no ordering guarantee. `gcloud run deploy <service> --image=...` is NOT safe
here — passed a service name that doesn't exist yet, it happily creates one,
which races terraform for ownership of a resource terraform's state is
supposed to own exclusively (next `terraform plan` would then show it as
unexpected drift, or apply could try to "adopt" a resource it never created,
depending on how the .tf is written).

**Pattern (used for NEO-175's fast preprocess service,
[[project_neo175_preprocess_fast_heavy_split]]):** guard every deploy job
with a describe-first check, and make every subsequent step in that job
conditional on the guard, rather than ever calling the create-or-update
`deploy` command unconditionally:

```yaml
- id: guard
  name: Check whether the service exists yet
  run: |
    set -euo pipefail
    if gcloud run services describe "$SERVICE" \
        --region="$REGION" --project="$PROJECT" >/dev/null 2>&1; then
      echo "exists=true" >> "$GITHUB_OUTPUT"
    else
      echo "::notice::$SERVICE not found in $PROJECT (terraform hasn't created it yet) — skipping."
      echo "exists=false" >> "$GITHUB_OUTPUT"
    fi

- name: Deploy (no_traffic + sha tag)
  if: steps.guard.outputs.exists == 'true'
  uses: google-github-actions/deploy-cloudrun@...
  with: { ... }
```

Key properties:
- The job's own conclusion is always `success` (the guard step doesn't fail
  on a 404 — it branches, it doesn't error), so a run before terraform
  applies stays green instead of red. Only genuine deploy failures — auth,
  quota, a real gcloud error — surface as real job failures, because those
  only happen once the guard has already confirmed the service exists.
  Downstream jobs read the `exists` output to cascade the same tolerance
  (e.g. `dev-promote-fast`'s `if:` also checks
  `needs.deploy-dev-fast.outputs.exists == 'true'`, so promotion is skipped
  rather than erroring when the deploy step never ran).
- `gcloud run services describe` is read-only against Cloud Run Admin API —
  no extra IAM needed beyond what a deploy already requires.
- The alternative mentioned in the task that spawned this pattern —
  `gcloud run services update` instead of `deploy` — also refuses to create
  a missing service, but the describe-guard was chosen instead so the actual
  deploy step could stay the same `google-github-actions/deploy-cloudrun`
  action already used everywhere else in these workflows (consistent
  tagging/no_traffic/env_vars behavior), rather than introducing a second
  deploy mechanism with a slightly different flag surface.

**Companion smoke-gating pattern used alongside this:** when the thing being
guarded also needs a post-deploy check before promoting traffic, but that
check must not be allowed to fail the whole CI run (e.g. it's a
best-effort/non-critical service), put `continue-on-error: true` on the
*check step* (not the job) and thread its real pass/fail through a step
output (`steps.<id>.outputs.passed`) rather than relying on the step's
`conclusion`. The job then reports `success` regardless (so it can never trip
an unrelated failure-reporting job watching for `result == 'failure'`), but
promotion jobs downstream gate on the real `passed` output, not on the
smoke job's overall `result` — so a broken revision still can't reach 100%
traffic even though the check that caught it is non-blocking at the
workflow-status level.
