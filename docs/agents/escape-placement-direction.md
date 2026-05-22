# Escape Placement Direction

This branch must converge on one simple pipeline.

1. Hoist anonymous owning expressions before escape decisions need names.
2. Escape analysis is an AST-bound placement pass. It stamps `symbol.storage = :heap` for the few escape mechanisms: return, enclosing-scope store, fiber/closure capture, TAKES or mutable collection param, and storage into a longer-lived aggregate/container.
3. MIR lowering never decides escape. It places a value into an already-decided destination. Destination storage chooses allocator; a heap string destination receives a heap-owned string value through one placement helper.
4. Ownership transfer is a separate structural fact: returned value, TAKES/GIVE, move into aggregate/container, and owning field extraction consume the source owner. Cleanup reads this fact; it does not rediscover it.
5. Cleanup classification builds recipes from type shape plus final storage. AllocMark, Cleanup, ErrCleanup, and ReassignWithCleanup must use the same allocator for a binding.
6. MIRChecker verifies these invariants and reports gaps. It must not become the decision maker.

Do not reintroduce promotion, value-flow fixpoints, allocator guessing in emitters, or per-bug rewrite hooks. If a failure appears to need a local special case, first identify which upstream fact is missing: destination placement, final symbol storage, or ownership transfer.
