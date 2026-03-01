# CLEAR TYPES

CLEAR distinguishes between **Types** (what data is) and **Capabilities** (how it's accessed).

```CLEAR
-- IMMUTABLE BY DEFAULT
VAR x = 5;                  -- Type: Number (inferred)
SET x = 6;                  -- COMPILER ERROR: x is immutable

-- MUTABLE EXPLICITLY
MUTABLE x = 5;
SET x = 6;                  -- OKAY

-- TYPE SPECIFICATION
VAR x: UInt64 = 5;

-- COLLECTIONS (No % sigil needed)
VAR coords = [1, 2, 3];     -- IMMUTABLE array
coords.push!(4);            -- COMPILER ERROR: coords is immutable

MUTABLE items = [1, 2, 3];  -- MUTABLE array
items.push!(4);             -- OKAY

-- CAPABILITIES (Acquired at edges)
VAR sharedU = SHARE(User.new());               -- shared User (Arc)
VAR multiU = MULTIOWN(User.new());             -- multiowned User (Rc)
VAR lockedU = SHARE:locked(User.new());        -- shared:locked User (Mutex<Arc>)
VAR rwLockedU = SHARE:writeLocked(User.new()); -- shared:writeLocked User (RwLock<Arc>)

-- RULE: Functions take TYPES, not CAPABILITIES
FN process(u: User) -> 
  PRINT(u.name);
END

process(sharedU); -- OKAY, capability is "discharged" at the call site.

-- LIFETIMES & REFERENCES
-- Lifetimes in CLEAR are strictly local to the function they occur in.
-- They cannot cross thread boundaries or be passed into async/callbacks.

-- 1. Immutable References (90% case: No poison)
FN getName(u: User) -> String
  RETURN u.name; -- OK: Returns a COPY or a transient borrow
END

-- 2. Explicit Returned References (Path-Based)
-- This function returns a reference to a sub-field of 'n'.
-- The return type 'n.child::Node' explicitly links the lifetime to 'n.child'.
FN grandChild(n: Node) -> n.child::Node
  RETURN n.child.child;
END

-- 3. Mutable Poison (WITH RESTRICT)
-- When a mutable object is borrowed, it is "restricted" (poisoned).
-- This must be explicitly scoped to ensure local reasoning.
MUTABLE node = buildTree();
WITH RESTRICT node.child {
  VAR gc = node.grandChild();
  -- node.child is immutable here.
  -- node.child.name = "New"; -- COMPILER ERROR: node.child is RESTRICTed.
}
-- node.child is mutable again here.

-- ERROR HANDLING
-- 1. Unsafe / Explicit Panic (!!)
list.push!(10)!!;

-- 2. Safe / Handled Result (The CLEAR Paradigm)
list.push!(10) OR EXIT "Buffer Overflow";

-- 3. Recovery
list.push!(10) OR list.clear!();

-- SAFE NAVIGATION (?.)
VAR name = getUser(id)?.name OR "Guest";

-- PIPELINES (s>)
VAR result = data
  s> filter(%(x) -> x > 10)
  s> map(%(x) -> x * 2)
  s> sum();
```

---

### Key Takeaway

CLEAR optimizes for **understandability** and **velocity** by separating the "Happy Path" (Types) from the "Messy Implementation" (Capabilities and Error Handling). Your business logic remains clean, while your system-level guarantees remain strong.
