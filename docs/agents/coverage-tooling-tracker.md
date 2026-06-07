# Coverage Tooling Tracker

| Date | Status | Item | Resolution |
|---|---|---|---|
| 2026-06-04 | resolved | Zig production/test bucketing treated only `*-vopr.zig` as non-production in the diff coverage report, and Codecov still tracked Zig test/VOPR/Loom harness files. | Updated diff coverage bucketing, Loom/VOPR coverage scanner exclusions, and `codecov.yml` ignore rules for `*-test.zig`, `vopr-*`, `loom-*`, `*-vopr.zig`, and `*-loom.zig`. |
