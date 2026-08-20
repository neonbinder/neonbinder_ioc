# NEO-175 Phase 3 — preprocess fast/heavy split: deploy runbook

Branch: `feature/neo-175-preprocess-fast-heavy-split` (off `develop`).
Status as of authoring: **committed to the feature branch, NOT pushed, NOT
merged, NOT applied.** Nothing in this document has been executed against a
real environment except the read-only `terraform plan` calls whose output is
quoted below.

This is Phase 3 of NEO-175 (terraform). Phases 1–2 (app code) are commits
`7ad8c5b` and `ba799cc` in the monorepo worktree
`neonbinder-mono-worktrees/neo-170-workpool`, branch
`jburich/neo-170-print-sheet-batch-pipeline-convex-workpool-orchestrates`
(GitHub PR #180) — **3 commits ahead of what is actually pushed to that PR**.
See "Hard prerequisite" below before treating those phases as done.

---

## What this ships

A new `neonbinder-preprocess-fast` Cloud Run service (dev + prod), running the
**same container image** as the existing `neonbinder-preprocess` service in a
new `PREPROCESS_ROLE=fast` mode (classical-CV only, no BiRefNet/SAM load →
cold-starts in seconds instead of ~191s), plus an IAM lock-down of the
existing heavy service. Full resource list is in the PR diff; the six
security controls the task specified map to terraform as follows:

| # | Control | Where |
|---|---|---|
| 1 | Fast service IAM-only, no `allUsers` | `preprocess_fast_convex_invoker` exists; no `allUsers` resource anywhere for the fast service |
| 2 | Dedicated `preprocess-fast-runtime` SA, scoped secrets/GCS/logging, no SA key | `google_service_account.preprocess_fast_runtime` + its 2 secret grants + 2 GCS grants + logWriter; no `google_service_account_key` resource |
| 3 | Heavy lock-down T1 (convex invoker) + T2 (remove `allUsers`), landed together | `preprocess_convex_invoker` (new) + `preprocess_public_access` (deleted), same commit |
| 4 | No fast→heavy or fast-self invoker | No `run.invoker` grant for `preprocess_fast_runtime` anywhere — verified by grep, called out in a terraform comment |
| 5 | Fast memory sized for `concurrency × peak-decode-RAM` | `preprocess_fast_memory` variable comment, grounded in `MAX_IMAGE_PIXELS`/`MAX_IMAGE_BYTES` code constants |
| 6 | Capacity vars cross-referenced to Convex | `preprocess_max_instances` (→ fast) and `heavy_preprocess_max_instances` (→ heavy) variable comments name the exact Convex env vars |

Also included, **not in the original task list but discovered to be a hard
prerequisite during authoring** (see "Extra IAM grant" below):
`preprocess_deployer_invoker` on both services, granting the
`neonbinder-preprocess-deployer` SA `roles/run.invoker`.

---

## Hard prerequisite: the app code this terraform assumes is not on the open PR yet

The task's context said Phases 1–2 were "already done, on #180." That's true
of the **code** — it exists, committed, exactly matching the contract below —
but **PR #180 as currently pushed to GitHub does not contain it.** Verified
2026-08-20:

- `origin/jburich/neo-170-print-sheet-batch-pipeline-convex-workpool-orchestrates`
  (the pushed branch backing PR #180, HEAD `6153087`) has zero occurrences of
  `PREPROCESS_ROLE`, `FAST_URL`, or `HEAVY_PREPROCESS` anywhere in the repo.
- The local worktree `neonbinder-mono-worktrees/neo-170-workpool`, same
  branch, is **3 commits ahead of origin**:
  `7ad8c5b` (Phase 1, `PREPROCESS_ROLE` fast/heavy split), a snapshot commit,
  and `ba799cc` (Phase 2, Convex escalation orchestration). Those unpushed
  commits are where the exact env var names, the host-regex normalizer, and
  the `heavy_preprocess_max_instances` naming this terraform was written
  against actually live.

**Before this terraform is applied to either environment, those 3 commits
must be pushed to #180 and merged to `main`** (or the relevant pieces
cherry-picked into whatever supersedes them) — the fast Cloud Run service
this PR creates will 500 on every request until the app image running on it
understands `PREPROCESS_ROLE`, and Convex will not send it any traffic until
`preprocessAudience.ts`/`adapters/preprocess.ts` exist. This terraform can
merge to `develop` first (it's additive-safe on its own — see the dev plan
below), but do not proceed past dev→prod without confirming the monorepo
side has actually shipped.

---

## Extra IAM grant this task's spec didn't ask for, and why it's required

The task's ordering note only mentioned Convex losing access if T1 (convex
invoker) doesn't precede/accompany T2 (removing `allUsers`). Reading the
monorepo's CI workflows before assuming that was the whole picture surfaced a
second caller with the identical problem:

`.github/workflows/preprocess-deploy.yml` and `preprocess.yml`'s smoke-test
jobs (dev-smoke, prod-smoke, preview-smoke) — **already present on the pushed
PR #180 branch**, tagged "NEO-170 Phase D" — mint a Google OIDC ID token for
the `neonbinder-preprocess-deployer` SA and send it as `Authorization: Bearer`
alongside the pre-existing `x-internal-key` header, with this comment already
in place:

> Terraform lands a run.invoker binding for this deployer SA before this
> deploys, but the allUsers invoker binding is removed LATER (terraform T2)

That binding did not exist anywhere in terraform before this change (confirmed
live via `gcloud run services get-iam-policy neonbinder-preprocess
--project=neonbinder[-dev]` — both envs showed only `allUsers` +
`preprocess-runtime`, no deployer). Removing `allUsers` without it would have
made every dev/prod preprocess CI deploy fail at the smoke-test step with a
403 from Cloud Run IAM itself (before the app-layer key check even runs).
`preprocess_deployer_invoker` (heavy) and `preprocess_fast_deployer_invoker`
(fast, pre-provisioned for the not-yet-built fast CI deploy lane — see below)
close this. This is grounded directly in the pushed CI code, not speculation.

---

## Ordering invariants

1. **T1 and T2 land in the same terraform change (this PR), never split
   across two.** `google_cloud_run_service_iam_member` resources are
   per-(role, member) grants — the provider does a scoped get-modify-set
   against just that member, not a full-policy replace, and it serializes
   concurrent `_iam_member` calls against the same target resource within one
   `terraform apply`. So within a single apply, whichever of "add convex
   invoker" / "add deployer invoker" / "remove allUsers" happens to execute
   first, the other real grants are either already present or land within the
   same apply run — there is no scenario where a human ships the removal in
   an earlier PR/apply than the additions. There is no `depends_on` to
   express here (T2 is a resource *deleted* from config, not one with a
   lifecycle hook), so this is enforced by "author them together," which this
   PR does.
   - If you want a hard guarantee with zero race window instead of relying on
     the above: `terraform apply -target=google_cloud_run_service_iam_member.preprocess_convex_invoker -target=google_cloud_run_service_iam_member.preprocess_deployer_invoker`
     first, confirm both via `gcloud run services get-iam-policy`, then run
     the full apply. Optional — the risk window without it is one
     `terraform apply`'s wall-clock time between independent IAM API calls,
     not "removal ships before addition."
2. **Monorepo #180's Phase 1–2 commits must be pushed + merged before the fast
   service carries real traffic** (see "Hard prerequisite" above). Terraform
   can land in `develop`/dev independently of this — the fast service will
   just 500 until the image understands `PREPROCESS_ROLE` — but do not
   promote to `main`/prod until the app side is confirmed live in prod.
3. **The fast-service CI deploy lane does not exist yet.** `preprocess.yml`
   and `preprocess-deploy.yml` only deploy to `neonbinder-preprocess` (heavy)
   today. This terraform creates `neonbinder-preprocess-fast` with whatever
   image `var.preprocess_image` resolves to at apply time (today:
   `:latest`), and nothing will update it afterward until the CI workflows
   grow a second `deploy-cloudrun` step targeting it. That is a real,
   separate follow-up (not built here — out of scope for a terraform-only
   Phase 3) — track it before relying on the fast service staying in sync
   with future preprocess deploys.

---

## GitFlow apply order

1. Push `feature/neo-175-preprocess-fast-heavy-split`, open a PR into
   `develop` in `neonbinder_ioc`.
2. Get it reviewed/approved. **Merge is squash, feature → develop** (per this
   repo's GitFlow convention, confirmed against `git log` — e.g. `a0e414a
   feat(neo-174): raise preprocess max_instances 3 -> 20 (#69)` squashed
   straight onto `develop`).
3. Merging to `develop` triggers this repo's dev apply (push-to-merge
   auto-applies, per this repo's CI). **Confirm the monorepo prerequisite
   above is satisfied first if you want the fast service to actually work
   post-apply** — the terraform itself is safe to land regardless.
4. **Verify dev** (commands below).
5. Set the dev Convex env vars (below) once satisfied.
6. Promote `develop` → `main` via a **merge commit** (not squash — this
   repo's GitFlow convention for that promotion specifically).
7. Merging to `main` triggers the prod apply.
8. **Verify prod** (commands below).
9. Set the prod (and preview, if applicable) Convex env vars.

---

## Convex env vars to set

**Approval-gated — these are live Convex deployment mutations, run them only
after the corresponding terraform apply has landed and been verified.** Two
are genuinely new; two close a pre-existing drift found incidentally while
verifying the naming contract (see "Incidental finding" below) — call all
four out explicitly when asking for approval, not just the two the task
named.

```bash
# --- New: point Convex at the fast service ---
npx convex env set NEONBINDER_PREPROCESS_FAST_URL "https://<fast-service-url-from-terraform-output>" 
npx convex env set NEONBINDER_PREPROCESS_FAST_URL "https://<fast-service-url>" --prod

# --- New: heavy's now-independent parallelism ceiling ---
# MUST equal heavy_preprocess_max_instances (this terraform's default: 20) in the SAME env.
npx convex env set HEAVY_PREPROCESS_MAX_PARALLELISM 20
npx convex env set HEAVY_PREPROCESS_MAX_PARALLELISM 20 --prod

# --- Recommended, closes a pre-existing dev/terraform drift (see below) ---
# PREPROCESS_MAX_PARALLELISM now governs the FAST service. It is already set
# to 20 in prod (matches terraform). It is UNSET in dev, which falls back to
# a hardcoded default of 3 (apps/web/convex/preprocessCapacity.ts,
# DEFAULT_PREPROCESS_MAX_PARALLELISM) — stale since terraform's dev
# preprocess_max_instances default was raised 3->20 in NEO-174. Setting it
# explicitly closes that gap regardless of this PR; doing it now keeps the
# fast/heavy pairing correct in dev.
npx convex env set PREPROCESS_MAX_PARALLELISM 20
```

Get the fast URL from terraform (`terraform output preprocess_fast_cloud_run_url`)
or the actual Cloud Run URL post-deploy — do not guess it, per-project hash
suffixes are not predictable.

`NEONBINDER_PREPROCESS_URL` (heavy) is **unchanged** — same service, same
name, no Convex env change needed for it.

---

## Verification (after apply, before promoting Convex traffic to it)

Replace `<PROJECT>` with `neonbinder-dev` or `neonbinder`, and get URLs from
`terraform output` (`preprocess_fast_cloud_run_url` / `preprocess_cloud_run_url`)
rather than guessing them.

```bash
FAST_URL=$(terraform output -raw preprocess_fast_cloud_run_url)
HEAVY_URL=$(terraform output -raw preprocess_cloud_run_url)

# Fast: unauthenticated must 403 (Cloud Run IAM, before the app is reached)
curl -s -o /dev/null -w "fast unauth: %{http_code}\n" "$FAST_URL/health"
# Expect: 403

# Fast: convex SA's ID token must 200
TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account=neonbinder-convex@<PROJECT>.iam.gserviceaccount.com \
  --audiences="$FAST_URL")
curl -s -o /dev/null -w "fast authed: %{http_code}\n" -H "Authorization: Bearer $TOKEN" "$FAST_URL/health"
# Expect: 200

# Heavy, AFTER T2 (allUsers removed): unauthenticated must now 403 too —
# this is the one that PREVIOUSLY returned 200/whatever-the-app-said, so it
# is the real regression check for the lock-down.
curl -s -o /dev/null -w "heavy unauth: %{http_code}\n" "$HEAVY_URL/health"
# Expect: 403 (was previously reachable pre-T2)

# Heavy: convex SA's ID token must still 200
TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account=neonbinder-convex@<PROJECT>.iam.gserviceaccount.com \
  --audiences="$HEAVY_URL")
curl -s -o /dev/null -w "heavy authed: %{http_code}\n" -H "Authorization: Bearer $TOKEN" "$HEAVY_URL/health"
# Expect: 200
```

`/health` is deliberately the target: it is the one route in
`services/preprocess/app/main.py` that requires no `x-internal-key` header at
all, so a 200 here isolates "Cloud Run IAM let the request through" from any
app-layer credential — exactly the boundary this lock-down changes. Running
the convex-SA impersonation curl requires the invoking user
(`neonbinder@neonbinder.io`) to hold `roles/iam.serviceAccountTokenCreator` on
`neonbinder-convex` — already true per this repo's standing local-dev setup
(see the top-level `CLAUDE.md`).

If CI's own smoke tests are green post-merge, that already exercises the
deployer-SA path (`SMOKE_ID_TOKEN` + `x-internal-key` together, per NEO-170
Phase D) — the curls above are for confirming the IAM boundary itself, which
CI's dual-auth transition period doesn't isolate on its own.

---

## `terraform plan` — actual output, read-only, no apply

Ran against the real GCS state backends
(`neonbinder-terraform-state-prod`, prefixes `terraform/state/dev` and
`terraform/state/prod`) with real `neonbinder@neonbinder.io` credentials,
2026-08-20. No `terraform apply` was run.

### dev (`environments/dev.tfvars`) — full plan

```
Plan: 14 to add, 1 to change, 1 to destroy.

Changes to Outputs:
  + preprocess_fast_cloud_run_url                 = (known after apply)
  + preprocess_fast_runtime_service_account_email = (known after apply)
```

Resources: `google_cloud_run_service.neonbinder_preprocess` (update — maxScale
annotation source variable swap, **plus incidental drift, see below**),
`google_cloud_run_service.neonbinder_preprocess_fast` (create),
`preprocess_convex_invoker` / `preprocess_deployer_invoker` /
`preprocess_fast_convex_invoker` / `preprocess_fast_deployer_invoker`
(create), `preprocess_public_access` (destroy — the `allUsers` binding),
`preprocess_fast_runtime` SA + its logging/secret/GCS/impersonation IAM (7
resources, create).

**Incidental finding, pre-existing, unrelated to this PR:** the dev plan for
`neonbinder_preprocess` shows more churn than just the maxScale annotation —
Terraform wants to remove a `GCS_PLACEHOLDER_BUCKET` env var that exists on
the **live dev service** but is absent from `main.tf` entirely (not something
this PR touches), plus a remove+recreate of the adjacent `ANTHROPIC_API_KEY`/
`INTERNAL_API_KEY` env blocks (a mechanical consequence of `env` being an
ordered list in this resource type — removing one element forces the
positionally-adjacent ones to re-diff). **Confirmed independent of this
change**: stashed this PR's diff, re-ran `terraform plan` against unmodified
`develop`, and the identical `GCS_PLACEHOLDER_BUCKET` removal appeared. Prod
shows zero drift on this resource (confirmed via targeted plan below) — dev
only. Someone set `GCS_PLACEHOLDER_BUCKET` on the live dev heavy service
out-of-band (not through this terraform config) at some point after NEO-148.
**Do not let this surprise you mid-apply** — it will show up as part of the
same `terraform apply` that lands this PR's changes (the resource is touched
either way), but it is not something this PR caused or is responsible for
fixing. If that env var is load-bearing for anything currently reading it in
dev, resolve that **before** applying this PR, in a separate change — either
by adding it to `main.tf` (if it should stay) or confirming dev doesn't need
it (if not).

### prod (`environments/prod.tfvars`) — targeted plan

A full untargeted prod plan currently fails on an unrelated pre-existing
issue: `google_billing_budget.gcp_spend[0]`'s data read 403s under local ADC
because `billingbudgets.googleapis.com` has no quota project set for the
`neonbinder@neonbinder.io` user credential (`gcloud auth application-default
set-quota-project`, or run this via the actual CI/CD apply path, which uses a
service account with this already configured) — **unrelated to NEO-175**, do
not attribute it to this change. Worked around by scoping the plan to only
this PR's resources via `-target`:

```
Plan: 13 to add, 0 to change, 1 to destroy.
```

One fewer "add" than dev (`developer_impersonate_preprocess_fast_runtime` has
zero instances in prod — `developer_emails` defaults to `[]` there, matching
the existing pattern for every other SA's developer-impersonation grant) and
"0 to change" instead of dev's "1" (prod's live heavy service has no
`GCS_PLACEHOLDER_BUCKET` drift — dev-only, per above). Fast service's image
resolved correctly to `gcr.io/neonbinder/neonbinder-preprocess:latest`
(prod's own image, not dev's) — confirmed in the targeted plan output.

Before a real prod apply, either resolve the quota-project issue (so the full
plan runs clean end-to-end) or accept that the actual CI/CD-driven apply
(which this repo's push-to-merge automation uses, on a properly configured
service account) won't hit it — this is a **local plan-running limitation**,
not a blocker for the real apply pipeline.

---

## Rollback

- **Terraform**: revert the PR, merge the revert through the same GitFlow
  path (develop → main). This recreates `allUsers` on heavy and removes the
  fast service + its IAM entirely. Cloud Run services with `minScale=0` and
  no active traffic cost effectively nothing while gone, so there's no
  cleanup deadline pressure either direction.
- **Convex**: if only the env vars need rolling back (terraform stays),
  `npx convex env set NEONBINDER_PREPROCESS_FAST_URL ""` (or delete it) makes
  `preprocessFastUrl()` fall back to the heavy URL (`preprocessHeavyUrl()` —
  this fallback is already built into `adapters/preprocess.ts`, not something
  this rollback plan invents), collapsing back to single-service behavior
  without needing a terraform change at all.
- **Mid-incident break-glass**: if the heavy lock-down (T2) turns out to break
  something unforeseen in prod, `gcloud run services add-iam-policy-binding
  neonbinder-preprocess --region=us-central1 --project=neonbinder
  --member=allUsers --role=roles/run.invoker` restores public access
  immediately without waiting on a terraform apply — but the next
  `terraform apply` will silently remove it again unless the PR reverting T2
  has already landed by then, so treat this as a bridge to a real revert, not
  a standalone fix.

---

## Cost

Fast service: scale-to-zero, so idle cost is ~$0 (matches the existing
heavy/browser pattern). Per-request cost at 2 vCPU / 8Gi / no model load is a
small fraction of heavy's ~$0.03/cold-start figure (no ~191s model-load
component at all) — not separately re-derived here; see
`.claude/agent-memory/devops-automator/project_neo170_split_cost_estimate.md`
in the private config repo for the full FAST/HEAVY cost model this phase's
capacity numbers were designed against. No new always-on resources, no new
billing-budget-relevant line items.
