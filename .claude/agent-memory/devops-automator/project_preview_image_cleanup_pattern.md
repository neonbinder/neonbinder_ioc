---
name: project_preview_image_cleanup_pattern
description: preview-cleanup workflows must GC the pr-<N> preview image, not just the Cloud Run traffic tag, or dev Artifact Registry balloons — history + where it's handled now that preprocess lives in the monorepo
metadata:
  type: project
---

**STALE as of NEO-123 (2026-08-ish) — corrected 2026-08-20:** this note
originally described `neonbinder_preprocess` as a standalone 4th repo with
its own `preview-cleanup.yml`. That repo is now **archived** (per the
monorepo wrapper's CLAUDE.md) — `services/preprocess` moved into
`neonbinder-mono` in NEO-123, deploying to the same `neonbinder-preprocess`
(heavy) Cloud Run service plus a new `neonbinder-preprocess-fast` (NEO-175),
both dev project `neonbinder-dev`, region `us-central1`, via WIF secrets
`GCP_WIF_PROVIDER_PREPROCESS_DEV` / `GCP_SA_PREPROCESS_DEPLOYER_DEV` — see
[[reference_preprocess_deployer_sa_separate_from_browser]]. Do not cite the
standalone-repo framing again; there are only 3 active repos now (see
CLAUDE.md's Public vs private table): the monorepo, terraform, and this
private wrapper.

**The underlying lesson still holds and is now handled inside the monorepo's
own `.github/workflows/preview-cleanup.yml`:** a `pr-<N>` Cloud Run traffic
tag removal alone does not GC the pushed container image — only an explicit
image delete (or a retention/cleanup policy) does. As of 2026-08-20 the
monorepo's `preview-cleanup.yml` has a `preprocess-cleanup` job that tears
down both the heavy and fast tagged revisions (the fast half is
describe-guarded — `neonbinder-preprocess-fast` may not exist yet, same
pattern as [[reference_ci_vs_terraform_ownership_guard]]). Image GC itself is
NOT an explicit per-PR delete step here — `preprocess.yml`'s comments note
NEO-123 added Artifact Registry cleanup *policies*
(`delete-tagged-preprocess`, `keep-recent-preprocess` at 10) that apply
project-wide, plus previews live in a separate `DEV_PREVIEW_IMAGE` package
(`neonbinder-preprocess-preview`, NEO-130) specifically so preview churn can't
consume the keep-window that protects real deploys. So the *goal* (previews
must not accumulate untracked storage) is the same; the *mechanism* moved
from an explicit `gcloud container images delete` step (still what
`services/browser`'s preview-cleanup does) to AR retention policies for
preprocess.

**How to apply:** when auditing a NEW per-PR preview + cleanup workflow,
check for EITHER an explicit tag-scoped image delete step (browser's
pattern) OR an Artifact Registry cleanup policy covering the preview image's
package/tag prefix (preprocess's pattern) — a bare traffic-tag removal alone
is the gap, regardless of which GC mechanism closes it.
