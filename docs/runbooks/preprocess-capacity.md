# Preprocess capacity: three layers, one number

NEO-299. Heavy and fast preprocess capacity is expressed in three places.
They must always agree; disagreement is what NEO-299 fixed. This is how to
read the effective cap and where each layer is set.

## The three layers

1. **Service-level Cloud Run annotation** (`run.googleapis.com/maxScale`),
   set on the top-level `metadata` block of `google_cloud_run_service.
   neonbinder_preprocess` / `neonbinder_preprocess_fast` in `main.tf`.
   Applies to the service as a whole — the named revision that's currently
   serving 100% of traffic.
2. **Revision template `maxScale`** (`autoscaling.knative.dev/maxScale`),
   set on `template.metadata.annotations` in the same two resources.
   Applies to whichever revision the annotation is on — including a
   **tagged, no-traffic revision** such as a PR preview deploy.
3. **Convex's dispatch pool** (`HEAVY_PREPROCESS_MAX_PARALLELISM` /
   `PREPROCESS_MAX_PARALLELISM`), the number of in-flight requests Convex
   itself will ever have outstanding to that service. This is the only
   layer that can under-use the Cloud Run ceiling on purpose; it must never
   exceed it.

All three trace to one file: the monorepo's
`apps/web/convex/preprocessCapacity.json` (`{heavy,fast}.{prod,dev,preview}`).
Terraform's `heavy_preprocess_max_instances` / `preprocess_max_instances` in
`environments/{dev,prod}.tfvars` are set from it by hand today; the
`terraform.yml` parity step fails the plan/apply if they drift apart.

The parity step checks the **tfvars first, then the JSON**: it reads this
env's `environments/{dev,prod}.tfvars` value before it ever fetches the
monorepo file, so a JSON fetch failure never masks a tfvars problem and the
error message always names the tfvars value it found. See that workflow's
"Preprocess capacity parity check" step for the exact comparison and its 404
handling for the case where the JSON file is still mid-rollout — a 404 is a
warning in dev/develop (the JSON can legitimately not exist yet there) but a
hard failure in prod, since prod's rollout order guarantees the monorepo
merge lands first.

## The failure mode this exists to prevent

**A tagged, no-traffic revision (a PR preview) ignores the service-level
annotation and scales to its own template's `maxScale`.** A hand-set,
out-of-repo service-level cap can hold the *serving* revision to a low
number while a PR preview revision, never having received traffic, scales
straight to the template's (possibly much higher) `maxScale` — a burst of
heavy + fast preview instances can then exceed the project's 400 GiB/region
Cloud Run memory quota even though the serving revision looks constrained.

The effective cap for the revision **currently serving traffic** is
`min(service-level, revision-level)`. The effective cap for a **tagged,
no-traffic revision** is just its own revision-level `maxScale` — the
service-level annotation does not constrain it at all.

## Reading the effective cap

```bash
# Service-level (applies to the traffic-serving revision):
gcloud run services describe neonbinder-preprocess \
  --project <project> --region <region> \
  --format='value(metadata.annotations["run.googleapis.com/maxScale"])'

# Revision-level, for a SPECIFIC revision (including an untagged preview):
gcloud run revisions describe <revision-name> \
  --project <project> --region <region> \
  --format='value(metadata.annotations["autoscaling.knative.dev/maxScale"])'

# All revisions currently receiving traffic and their split:
gcloud run services describe neonbinder-preprocess \
  --project <project> --region <region> \
  --format='value(status.traffic)'
```

Same commands against `neonbinder-preprocess-fast` for the fast service.

## What to check before changing any of the three numbers

1. Read `apps/web/convex/preprocessCapacity.json` — that's the number to
   change, not the tfvars or the Convex env var directly.
2. Recompute the quota arithmetic in `variables.tf`'s comment on
   `heavy_preprocess_max_instances` / `preprocess_max_instances` against the
   new number, including the ~78 GiB a single PR preview preprocess deploy
   adds to dev's budget.
3. Update all three: the JSON, the tfvars (dev via `develop`, prod via
   `main`), and Convex's env vars in both environments.
4. Let the `terraform.yml` parity step confirm agreement rather than
   eyeballing it.
