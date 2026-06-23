# Gems Performance TODOs

## 1. Optimize Espalier Execution time
- [x] **Action**: Espalier must be modified to accept and parse a *PREVIOUSLY* mined fact file instead of triggering `fact-mine-rust` on every run.
- [x] **Goal**: Espalier's command execution time should be extremely fast (near-instantaneous) when reusing static facts.

## 2. Optimize SlopCop Execution time
- [x] **Action**: SlopCop must follow the exact same architecture as Espalier, consuming a pre-mined fact file directly.
- [x] **Goal**: SlopCop's execution time should also be extremely fast.
