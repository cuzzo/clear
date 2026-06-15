# Auto-type Split

Nil-kill owns evidence collection, static/runtime inference, pressure ranking, and reporting. It should not own source rewriting as a product surface.

Auto-type owns source edits. Its input is a transformation/action plan, currently Nil-kill's `evidence.json` actions. Its output is changed source after a provider has applied edits and, for review-grade actions, a verifier has accepted them.

## Current Boundary

- Nil-kill CLI: `collect`, `infer`, static/runtime normalization, pressure reports, `struct-rbi`, `doctor`.
- Auto-type CLI: `apply`, `review`, `loop`, `guarded-autocorrect`.
- Ruby provider: existing Sorbet-aware source rewrites.
- Future providers: consume the same action shape, implement language-specific planning/apply/verify hooks.

## Non-goals

- Auto-fixing hidden enums automatically. Hidden enum pressure remains report-only until candidates prove consistently high signal.
- Requiring every language provider to support every action kind.
- Letting raw review actions mutate source without a verifier.
