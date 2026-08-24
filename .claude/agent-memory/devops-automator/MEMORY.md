# Memory Index

- [project_preview_image_cleanup_pattern.md](project_preview_image_cleanup_pattern.md) — preview-cleanup must GC the pr-<N> image, not just the Cloud Run tag; preprocess now lives in the monorepo (NEO-123), old standalone-repo framing corrected
- [project_neo175_preprocess_fast_heavy_split.md](project_neo175_preprocess_fast_heavy_split.md) — heavy/fast Cloud Run split from one image, role-selected by terraform; smoke-test trap
- [reference_ci_vs_terraform_ownership_guard.md](reference_ci_vs_terraform_ownership_guard.md) — describe-first guard pattern so CI never creates a Cloud Run service terraform owns
- [reference_workflow_no_checkout_cwd_crash.md](reference_workflow_no_checkout_cwd_crash.md) — a job with no checkout + a subdir `defaults.run.working-directory` crashes bash outright; known unresolved instance in preprocess-deploy.yml's dev-smoke-fast
- [reference_preprocess_deployer_sa_separate_from_browser.md](reference_preprocess_deployer_sa_separate_from_browser.md) — use the preprocess deployer SA (not browser's) for preprocess Cloud Run calls, even from other workflow files; WIF binding is repo-scoped
- [reference_import_recovery_after_inconsistent_apply.md](reference_import_recovery_after_inconsistent_apply.md) — "inconsistent result after apply" then 409-on-retry recovery: reconfigure init to the right prefix, `terraform import` the orphan, verify plan before handing back to CI
