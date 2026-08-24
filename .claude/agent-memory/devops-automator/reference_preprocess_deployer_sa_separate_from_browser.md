---
name: reference_preprocess_deployer_sa_separate_from_browser
description: preprocess CI/CD uses its own dedicated deployer SA (neonbinder-preprocess-deployer), not the browser deployer — even though both grant repo-wide, project-level run.admin
metadata:
  type: reference
---

`services/preprocess` CI (`preprocess.yml`, `preprocess-deploy.yml`) always
authenticates via `GCP_WIF_PROVIDER_PREPROCESS_DEV` /
`GCP_SA_PREPROCESS_DEPLOYER_DEV` (`neonbinder-preprocess-deployer`), a
dedicated SA — never `GCP_WIF_PROVIDER_DEV` / `GCP_SERVICE_ACCOUNT_DEPLOYER_DEV`
(`neonbinder-browser-deployer`) that browser CI uses, even though both SAs
hold project-level `roles/run.admin` in `neonbinder_terraform/main.tf` and
either one would technically have enough IAM to `gcloud run services describe`
the other service. Keep that split when writing new preprocess-adjacent CI
steps (e.g. a job in `pr-pipeline.yml` that needs to read the preprocess Cloud
Run services) — use the preprocess deployer, not the browser one, even from a
workflow file that isn't `preprocess.yml`/`preprocess-deploy.yml`.

**Why cross-workflow use is fine:** `preprocess_deployer`'s WIF binding
(`github_actions_wif_preprocess` in main.tf) is *repo-scoped*
(`principalSet://.../attribute.repository/<repo>`), not pinned to a specific
workflow file via `job_workflow_ref` — the terraform comment says this
explicitly: "post-NEO-123 any monorepo workflow can assume this SA." So
`pr-pipeline.yml` minting a token for `neonbinder-preprocess-deployer` is
already within the granted trust boundary; no terraform change needed. (This
is a narrower posture than `secret_gc`'s SA, which IS pinned to
`job_workflow_ref` — that one destroys secret versions, higher blast radius,
different tradeoff.)

Both deployer SAs' WIF providers accept `pull_request` tokens in dev
(`*_wif_allow_pull_requests = true`), gated tighter in prod
(push-to-main-only) — check `var.preprocess_wif_allow_pull_requests` /
`browser_wif_allow_pull_requests` in variables.tf if extending this to prod.
