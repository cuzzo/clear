# Decomplex TODO

Launch-readiness items for Decomplex.

## Burned Down In This WIP

- [x] Move the Decomplex image into a stable docs asset path.
- [x] Add the image to the Decomplex README.
- [x] Rewrite the Decomplex README around launch-facing sections.
- [x] Create `gems/README.md` explaining that `gems/` contains CLEAR
  quality/tooling subprojects, not merely published RubyGems.
- [x] Update the repository `CONTRIBUTING.md` with gem contribution
  guidance.
- [x] Add a small Decomplex-specific `CONTRIBUTING.md`.
- [x] Check `docs/agents/metrics-expo.md` against the current report
  sections and update stale section names.
- [x] Add SARIF generation from structured report findings.
  - Implemented as `decomplex report --sarif=tmp/decomplex.sarif`.
  - Uses the same finding identities and locations as Markdown/delta.
  - Does not re-run detectors from the SARIF adapter.

## Current Launch

- [ ] Add CI integration docs and/or workflow example.
  - Generate `report.md` as an artifact.
  - Generate a JSON baseline snapshot.
  - Run `decomplex delta` on PRs.
  - Upload SARIF with `github/codeql-action/upload-sarif`.
- [ ] Add a release/retrospective doc for the Decomplex launch.
- [ ] Update `docs/retrospective/what-even-is-complexity-anyway.md`
  with concrete examples for the Decomplex metrics, or write a separate
  retrospective/blog article based on
  `gems/decomplex/docs/agents/metrics-expo.md`.
- [ ] Decide whether the Decomplex metrics expo should become a public
  blog-style article separate from the internal agent doc.

## Follow-Up

- [ ] Design a stable custom metric plugin API.
  - Goal: similar in spirit to RuboCop custom cops, but for Decomplex
    complexity metrics.
  - Plugins should consume normalized syntax facts, not raw parser nodes
    where avoidable.
- [ ] Document what a third-party language profile must provide.
- [ ] Ensure package metadata includes the README/docs/assets if
  Decomplex is published as a conventional gem.
