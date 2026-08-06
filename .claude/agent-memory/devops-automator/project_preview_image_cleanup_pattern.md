---
name: project_preview_image_cleanup_pattern
description: preview-cleanup.yml workflows must delete the pr-<N> GCR image, not just the Cloud Run traffic tag, or dev Artifact Registry balloons
metadata:
  type: project
---

There is a fourth active repo beyond the three named in CLAUDE.md's monorepo
note: `neonbinder_preprocess` (git@github.com:neonbinder/neonbinder_preprocess.git),
a standalone service deployed to Cloud Run (`neonbinder-preprocess`, dev
project `neonbinder-dev`, region `us-central1`) via WIF secrets
`GCP_WIF_PROVIDER_PREPROCESS_DEV` / `GCP_SA_PREPROCESS_DEPLOYER_DEV`. It has
its own `.github/workflows/preview-cleanup.yml`, separate from
neonbinder-mono and neonbinder_terraform.

**Recurring gap (NEO-95, fixed 2026-07-24, PR neonbinder/neonbinder_preprocess#11):**
`preview-cleanup.yml` on PR-close removed the `pr-<N>` Cloud Run traffic tag
via `gcloud run services update-traffic --remove-tags` but never deleted the
underlying `gcr.io/neonbinder-dev/<service>:pr-<N>` Docker image. Images
accumulate forever in the dev `gcr.io` Artifact Registry repo (was ~40GB).

**Why:** removing a Cloud Run tag just stops the preview URL resolving; it
does not GC the pushed container image. Only an explicit image delete does.

**How to apply:** any repo with a per-PR preview deploy + cleanup workflow
needs a companion step, placed right after the traffic-tag removal, e.g.:

```yaml
- name: Delete the pr-<N> image from dev GCR (best-effort)
  if: always()
  env:
    PR: ${{ github.event.pull_request.number }}
  run: |
    set -uo pipefail
    IMAGE="gcr.io/neonbinder-dev/<service>:pr-$PR"
    gcloud container images delete "$IMAGE" --force-delete-tags --quiet || \
      echo "image $IMAGE not deleted (absent or no delete permission) — ignoring"
```

`neonbinder-mono`'s `services/browser` preview-cleanup workflow already had
this (source of the pattern copied into neonbinder_preprocess). Worth
auditing every repo with a preview-cleanup workflow for the same gap —
check `neonbinder_web` and `neonbinder_terraform`-adjacent services too if
any grow per-PR Cloud Run previews later.
