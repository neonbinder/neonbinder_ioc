---
name: reference_import_recovery_after_inconsistent_apply
description: recovery procedure when a terraform apply hits "Provider produced inconsistent result after apply" (GCP eventual consistency) on a create, and the re-run then 409s because the resource exists in GCP but not in state
metadata:
  type: reference
---

**Symptom sequence (seen on NEO-175's dev apply, run 32413113693, 2026-08-19):**
1. Apply #1 creates a `google_service_account` (or similar eventually-consistent
   GCP resource), then fails with "Provider produced inconsistent result after
   apply: ... Root resource was present, but now absent" — terraform's
   post-create read-back raced GCP's propagation and lost, so the resource
   was created in GCP but never written to state.
2. Apply #2 (the natural retry) then fails with `Error 409: ... already
   exists` on the same resource, because terraform's plan still shows it as
   "to create" (state has nothing) but GCP now refuses the create.

**Fix — state-only, no apply:**
```bash
terraform init -reconfigure -backend-config="prefix=terraform/state/<env>"
terraform import -var-file=environments/<env>.tfvars <resource_address> "<GCP self-link/import ID>"
terraform plan -var-file=environments/<env>.tfvars   # confirm: 0 destroy, imported resource absent from the create list
```
Then hand back to CI (or the normal apply path) to create the *remaining*
dependent resources (IAM bindings, the Cloud Run service that references the
SA, etc.) — those never got far enough to hit the same race, so a normal
apply from here is safe.

**Verification checklist before calling it safe to re-apply:**
- `terraform state show <resource_address>` attributes match the `.tf`
  declaration exactly (account_id/display_name/description or equivalent) —
  confirms no drift snuck in from manual/partial creation.
- `terraform plan` shows the imported resource in neither the create nor the
  change list.
- Plan's destroy count is 0 and nothing outside the new feature's blast
  radius appears — especially double-check any adjacent lock-down/IAM
  resources from a *previous* phase of the same feature aren't touched.

**Backend hygiene while doing this:** the local `.terraform/terraform.tfstate`
cache remembers whatever prefix was last used (see
[[reference_terraform_gcs_backend_prefix_required]]) — check it before
importing anything; a stale prod-prefix cache plus a plain `terraform init`
either silently targets the wrong environment or triggers an interactive
"migrate state between backends" prompt. Always use `-reconfigure` with the
explicit `-backend-config="prefix=..."` when switching, never plain `init`.

**Git branch note:** this kind of state surgery targets the GCS remote
backend, not local git — the terraform repo's branch/worktree you happen to
be on doesn't matter beyond having the right `main.tf` checked out (import
needs the resource address to exist in the current `.tf` files). Safe to
checkout the applied branch (e.g. `develop`), do the import, then switch back
to whatever branch you were on before — the import itself already landed in
GCS by the time you switch back.
