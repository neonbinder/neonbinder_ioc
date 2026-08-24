---
name: reference_workflow_no_checkout_cwd_crash
description: a GHA job with no actions/checkout step inherits the workflow-level defaults.run.working-directory and crashes ("No such file or directory") on its first run step if that path doesn't exist on the runner
metadata:
  type: reference
---

**Symptom:** a job's first `run:` step goes red almost instantly (~13s), with
no useful output from the script itself — the log shows
`##[error]An error occurred trying to start process '/usr/bin/bash' with
working directory '/home/runner/work/<repo>/<repo>/<subdir>'. No such file or
directory`. This looks like a script bug (e.g. a `set -e` tripping on a
command's non-zero exit) but is NOT one — bash never even started.

**Root cause:** the workflow sets a top-level `defaults: run: working-directory:
<subdir>` (common in this repo — `preprocess.yml` and `preprocess-deploy.yml`
both default to `services/preprocess`, `browser.yml` to `services/browser`).
Every job inherits that default unless it overrides it. A job whose steps are
ALL `gcloud`/`curl`/API calls (no repo file needed) often skips
`actions/checkout` entirely — but skipping checkout means `<subdir>` never
gets created on the runner, so the inherited working-directory points at a
path that doesn't exist, and bash fails to launch for ANY `run:` step in that
job, unconditionally (not just on failure paths).

**Fix:** either add `actions/checkout`, or — the pattern this repo actually
uses for gcloud-only jobs — override the default at the job level:
```yaml
defaults:
  run:
    working-directory: ${{ github.workspace }}
```
`preprocess-deploy.yml`'s `deploy-dev-fast` job has this override correctly.
Its sibling `dev-smoke-fast` (same file) and `preprocess.yml`'s
`deploy-preview-fast` / `preview-smoke-fast` did NOT — found via
`gh run view <id> --log` after `deploy-preview-fast` failed on every
services/preprocess PR (fixed in commit 9066416 on the NEO-170 branch,
2026-08-20; `preview-smoke-fast` fixed proactively in the same commit since it
has the identical shape and would have failed the moment `deploy-preview-fast`
started succeeding).

**Known unresolved instance:** `preprocess-deploy.yml`'s `dev-smoke-fast` job
still lacks this override as of 2026-08-20. It hasn't been observed failing
yet because it only runs on `push` to main with `neonbinder-preprocess-fast`
already existing in dev, a combination that hasn't happened yet — but it has
the exact same shape (no checkout, no override) and will crash the same way
the moment it does. Flagged to the user, not fixed (out of scope for the task
that found it — check before that job's first real run).

**How to apply:** whenever adding a new CI job that talks to GCP/APIs only
(no repo files touched) to a workflow that sets a subdir-scoped
`defaults.run.working-directory`, check whether the job has `actions/checkout`.
If not, add the `${{ github.workspace }}` override — don't assume the omission
is safe just because the job "doesn't need" repo files.
