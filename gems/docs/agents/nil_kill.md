# Nil-Kill Architecture and Plan

## Current State & Problem
- **Broken State**: `gems/nil-kill` haphazardly migrated its static analysis fact-mining into `gems/espalier`.
- **Result**: It currently doesn't work in any sense of the word. It no longer performs its former `source_index` operations (which relied on the fact-mining it used to have).

## Architecture Guidelines
- **Data Source**: Eventually, Nil-kill needs to be solved such that `gems/espalier` fully migrates to the Rust version of Fact-Mine.
- **Nil-kill resolution**: Once Espalier is successfully migrated, Nil-kill can be revisited to repair its `source_index` functionality.

## Plan & Priorities
1. **Deferred**: We will leave Nil-kill alone for now.
2. **Prerequisites**: Do not attempt to fix Nil-kill until Espalier is fully working on Fact-Mine Rust with >95% integration test coverage and all its architectural purity standards met.
