---
name: project_neo175_preprocess_fast_heavy_split
description: NEO-175 split services/preprocess into two Cloud Run services (heavy + fast) from ONE image; CI deploy pattern for a service terraform may not have created yet
metadata:
  type: project
---

**What NEO-175 built:** `services/preprocess` (monorepo) now runs as TWO
Cloud Run services from the SAME container image, role-selected by a
`PREPROCESS_ROLE` env var terraform sets per-service (never CI):

- `neonbinder-preprocess` (heavy) — no `PREPROCESS_ROLE` set, defaults to
  heavy; runs the full BiRefNet/SAM cascade; `/process`, `/process-entry`
  without escalation-only behavior.
- `neonbinder-preprocess-fast` (fast) — `PREPROCESS_ROLE=fast`; classical-CV
  only, never loads BiRefNet/SAM (skips the ~191s cold-start model load);
  `/process-entry` returns `needs_escalation=true` when the classical path
  can't settle a card, and Convex re-routes that entry to heavy.
  `/warmup` short-circuits to `was_cold=false` without touching the model
  loader. `/process` (the older, non-role-aware endpoint) is NOT
  role-branched — it always runs the full cascade regardless of which
  service it's hit on. This matters for smoke-test design (below).

Terraform (`neonbinder_terraform/main.tf`) defines
`google_cloud_run_service.neonbinder_preprocess_fast` fully, including its
own runtime SA (`preprocess_fast_runtime`), convex-invoker IAM binding, and a
**pre-provisioned** `preprocess_fast_deployer_invoker` binding for the same
`neonbinder-preprocess-deployer` SA heavy already uses (one deploy pipeline,
same image, both services — no separate deployer SA needed). The
`preprocess_deployer` SA's `roles/run.admin` grant is **project-level**, so
it already covers the fast service too; no new IAM was needed to let CI
deploy to it. Fast service env vars set by terraform: `PREPROCESS_ROLE=fast`,
`ENVIRONMENT`, `GOOGLE_CLOUD_PROJECT`, plus the two secret-backed vars
(`INTERNAL_API_KEY`, `ANTHROPIC_API_KEY`). Notably it does **NOT** get
`GCS_PLACEHOLDER_BUCKET` (heavy does) — the fast role doesn't touch that
pipeline stage.

**Phase D (2026-08-19/20, this session):** extended
`.github/workflows/preprocess-deploy.yml` and `preprocess.yml` to also
deploy to the fast service (previously CI only ever touched heavy), plus
`preview-cleanup.yml` to tear down the fast preview tag. See
[[reference_ci_vs_terraform_ownership_guard]] for the reusable
existence-guard pattern this needed, and
[[project_preview_image_cleanup_pattern]] for how the teardown step was kept
consistent with the repo's tag-only cleanup convention.

**Smoke-test trap to remember:** `tests/smoke/test_deployed.py`'s happy-path
test posts to `/process`. Because `/process` is NOT role-aware, pointing that
suite at the fast service would run the full heavy cascade on a container
sized for classical-CV-only work (smaller CPU/memory per
`preprocess_fast_cpu`/`preprocess_fast_memory` in terraform) — slow at best,
OOM at worst. Fast-service CI checks use a bare `/health` ping instead, not
the shared smoke suite. If a role-aware smoke path is ever wanted, it needs a
NEW test hitting `/process-entry` and asserting on `needs_escalation`, not a
reuse of the existing `/process` suite.
