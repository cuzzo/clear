# Decomplex Metrics Expo

This document explains Decomplex metrics from the perspective of the
complexity model in
[`What even is complexity anyway?`](../../../../docs/retrospective/what-even-is-complexity-anyway.md):
software becomes hard to understand when state and control flow become
unnecessary, implicit, shared, mutable, duplicated, or poorly bounded.

Decomplex does not try to prove that code is wrong. It ranks candidates.
The point is to show where a human should look first.

## Running Example

The bad shape is a common object lifecycle:

```ruby
CLASS BillingService
  FN setCart(cart)
    @cart = cart
  END

  FN setUser(user)
    @user = user
  END

  FN validateUser()
    @user_valid = @user != nil && @user.active?
  END

  FN applyDiscount()
    IF @user_valid && @cart.total > 100 THEN
      @discount = 10
    END
  END

  FN processPayment()
    IF @cart != nil && @user_valid THEN
      charge(@user, @cart.total - @discount)
      @paid = true
    END
  END
END
```

Each method can look reasonable by itself. The class is still dangerous:

```text
setUser -> setCart -> validateUser -> applyDiscount -> processPayment
```

is probably intended, while:

```text
setUser -> applyDiscount -> validateUser -> setCart -> processPayment
```

may be wrong. The class has created an implicit state machine. It has
state (`@cart`, `@user`, `@user_valid`, `@discount`, `@paid`) and a
hidden control-flow contract over methods.

A better design makes the control flow explicit:

```ruby
CLASS BillingService
  FN checkout(user, cart)
    validateUser(user)
    discount = discountFor(user, cart)
    processPayment(user, cart, discount)
  END
END
```

The metrics below are different ways of asking: "Where did state and
control flow escape their boundary?"

## How To Read The Report

Start with convergence and root-cause clusters, then inspect the
highest-tier metric rows.

- **Convergence** means independent detectors point at the same method.
- **Root-cause clusters** mean independent detectors name the same state,
  predicate, method, or protocol.
- A large count is not automatically bad. A large count on hot, mutable,
  state-based code is where the return on review is highest.

## State Metrics

### State Heatmap

Question: which state has the most read/write scatter?

In `BillingService`, the heatmap would rank fields such as:

```text
@user_valid  written by validateUser, read by applyDiscount/processPayment
@discount    written by applyDiscount, read by processPayment
@cart        written by setCart, read by applyDiscount/processPayment
```

This is not saying `@cart` is a bug. It is saying `@cart` is part of a
shared mutable lifecycle. If a field is written in one method and read
in many others, the reviewer should ask whether those readers are
protected by an explicit API or are relying on call order.

### Temporal Ordering Pressure

Question: does this owner expose a public mutable lifecycle?

The five-method `BillingService` is the archetype:

```text
public state methods: setCart, setUser, validateUser, applyDiscount, processPayment
shared fields: @cart, @user, @user_valid, @discount
possible call orders: 5!
```

The metric is about the public surface. A class with many public methods
that read/write the same fields has made callers responsible for order.
The usual fix is to hide the lifecycle behind one method such as
`checkout(user, cart)`.

### Implicit Control Flow

Question: do internal calls have an order that matters because of state?

This metric does not flag arbitrary repeated call order. It only cares
when the callees have overlapping state effects on the same feasible
path:

```text
validateUser -> applyDiscount
```

matters because `validateUser` writes `@user_valid` and `applyDiscount`
reads it.

```text
applyDiscount -> processPayment
```

matters because `applyDiscount` writes `@discount` and `processPayment`
reads it.

Decomplex reports the protocol itself as pressure:

```text
validateUser -> applyDiscount   write_read @user_valid
applyDiscount -> processPayment write_read @discount
```

This is useful even if every call site is consistently ordered, because
the consistency is exactly the hidden rule callers must learn. A
reversed site is stronger evidence, but the metric does not require a
reversal. If two pure helpers are often called in one order, Decomplex
ignores them. It also keeps `if`/`case` alternatives separate, so a
dispatcher does not become a fake `branchA -> branchB` protocol.

### State-Based Branch Density

Question: how much branching depends on mutable/object state?

In `BillingService`:

```ruby
IF @user_valid && @cart.total > 100 THEN ...
IF @cart != nil && @user_valid THEN ...
```

are state-based branches. Cyclomatic complexity alone treats these like
any other branch. Decomplex treats them as more important because the
branch outcome depends on prior mutation and method order.

### Neglected Updates

Question: are two pieces of state usually written together, but one site
writes only one of them?

If `BillingService` usually treats `@discount` and `@discount_reason` as
a pair:

```ruby
FN applyDiscount()
  @discount = 10
  @discount_reason = "cart_total"
END
```

then a later method that writes only `@discount` may be a stale-state bug.
This is the "co-written state drifted" metric.

### Derived-State Staleness

Question: did we compute state from another value, mutate the source,
and keep using the old derived value?

In the billing shape:

```ruby
discounted_total = @cart.total - @discount
@discount = 20
charge(@user, discounted_total)
```

`discounted_total` may be stale. Decomplex looks for the local version
of this pattern.

## Decision Metrics

Use one tiny policy helper for the decision metrics:

```ruby
CLASS CheckoutPolicy
  FN canDiscount(user, cart)
    RETURN user.active? && cart.total > 100 && !cart.locked?
  END

  FN canPay(user, cart)
    RETURN user.active? && cart.total > 0 && !cart.locked?
  END

  FN expressCheckout(user, cart)
    IF user.active? && cart.total > 100 THEN
      processPayment(user, cart)
    END
  END
END
```

### Missing Abstractions

Question: is the same guard tuple recomputed in several places?

If the code repeatedly checks:

```text
user.active? && cart.total > 100 && !cart.locked?
```

there is probably a missing predicate such as `discountable_cart?`.
The problem is not the branch count. The problem is duplicated business
meaning.

### Neglected Conditions

Question: does one site use a high-support condition set minus one atom?

If most discount checks include:

```text
user.active? && cart.total > 100 && !cart.locked?
```

but `expressCheckout` checks only:

```text
user.active? && cart.total > 100
```

Decomplex reports the missing `!cart.locked?`. This is a candidate bug,
not a verdict; sometimes the shorter condition is intentional.

### Neglected Path Conditions

Question: does the same missing-condition pattern appear through nested
control flow rather than one `&&` expression?

These two shapes are semantically close:

```ruby
IF user.active? THEN
  IF cart.total > 100 THEN
    IF !cart.locked? THEN ...
```

```ruby
IF user.active? && cart.total > 100 && !cart.locked? THEN ...
```

Path-condition mining tries to compare the guard set, not just the
surface syntax.

### Decision Pressure

Question: are repeated loose-contract guards adding avoidable control
flow?

Examples:

```ruby
IF user != nil THEN ...
IF user.respond_to?(:active?) THEN ...
IF cart.is_a?(Cart) THEN ...
```

If these checks scatter everywhere, the real fix may be a tighter type
or API contract, not another helper method.

### Redundant Nil Guards

Question: is a nil check dominated by an earlier proof?

```ruby
RETURN unless user != nil
IF user != nil THEN processPayment(user, cart) END
```

The second guard is redundant. It is small locally, but repeated
redundant guards are a sign that contracts are not carrying invariants.

### Reification Misses

Question: did code reinvent an existing predicate inline?

If `CheckoutPolicy#canDiscount` exists, then this:

```ruby
IF user.active? && cart.total > 100 && !cart.locked? THEN ...
```

is a reification miss. The code should call the named predicate so the
decision has one owner.

### Exact And Semantic Predicate Aliases

Question: do multiple predicates mean the same thing?

```ruby
FN canDiscount(user, cart)
  RETURN user.active? && cart.total > 100
END

FN eligibleForPromo(user, cart)
  RETURN user.active? && cart.total > 100
END
```

Exact aliases have identical bodies. Semantic aliases try to see through
small definitional differences. Either way, two names for one decision
increase maintenance cost.

### Oversized Predicates

Question: is one predicate doing too many independent checks?

```ruby
IF user.active? && cart.total > 100 && !cart.locked? &&
   user.region == "US" && !user.fraud_flag THEN ...
```

This may be essential business logic, but it should probably have a
name. Oversized predicates are often missing vocabulary.

## Sequence And Clone Metrics

### Broken Protocols

Question: are two actions usually paired, but one site does only one?

If billing code usually does:

```text
reserveInventory -> processPayment
```

but one path only calls `processPayment`, Decomplex reports the broken
protocol. Unlike Implicit Control Flow, this detector is about
co-occurrence, not state-dependent order.

### Inconsistent Rename Clones

Question: did a pasted block rename most identifiers but miss one?

This catches the classic copy/paste bug where `cart` became
`trial_cart` everywhere except one stale reference.

### Structural Similarity

Question: are there large structural clones?

Tree-sitter structural similarity is a broad clone signal. Decomplex
uses it as supporting evidence; it is not by itself a bug report.

## Shape Metrics

### Weighted Inlined Cognitive Complexity

Question: did a method look simple only because the complex work was
moved into same-owner helpers?

This metric uses Decomplex's conservative Ruby topology graph. It only
inlines bare or `self.` calls inside the same class/module, so it avoids
guessing about dynamic dispatch or cross-object call targets.

The score is:

```text
local cognitive weight(method)
+ weighted local cognitive weight(callees)
+ weighted local cognitive weight(callees of callees)
```

Local cognitive weight is not McCabe. It counts nested control-flow and
reader burden: `if`/`unless`, loops, rescue, boolean guard tangles, and
early exits inside nesting. `case`/match-style dispatch is deliberately
cheap: Decomplex charges a small dispatch cost and then scores complex
branch bodies normally, instead of punishing every arm as if every arm
were an independent decision.

In the improved-looking billing shape:

```ruby
CLASS BillingService
  FN checkout(user, cart)
    validateUser(user)
    discount = discountFor(user, cart)
    processPayment(user, cart, discount)
  END

  FN validateUser(user)
    IF user != nil && user.active? && !user.suspended? THEN true END
  END

  FN processPayment(user, cart, discount)
    IF gateway.ready? THEN
      IF cart.total > 0 && user.active? THEN
        charge(user, cart, discount)
      END
    END
  END
END
```

`checkout` has low local complexity. But a reviewer cannot understand it
without jumping through `validateUser`, `discountFor`, and
`processPayment`. If those helpers are only called by `checkout`, their
complexity is almost fully counted as hidden reader burden.

The weighting intentionally distinguishes helper shapes:

- Single-caller helpers are weighted heavily, because they may be
  extraction-for-extraction's-sake.
- Shared helpers are damped, because a well-named shared abstraction can
  reduce complexity.
- Public shared helpers are damped further.
- Recursive cycles are cut off.
- Call-chain depth is capped, so one method does not absorb the whole
  owner.

Default reports require at least 15 hidden weighted points. Lower-score
helper hops are still available through `DECOMPLEX_WICC_MIN_HIDDEN`, but
the default report skips that low tail because it mostly finds tiny
wrappers and grammar-style forwarding methods.

The usual finding looks like:

```text
BillingService#checkout
local=0.0, inlined=16.3, hidden=16.3
chain: checkout -> processPayment
single-caller helpers: validateUser | discountFor | processPayment
```

This is subjective by design. Sometimes extraction is correct because a
helper has a good name and a clear concern. The metric says: "review this
as if the helper bodies were inline, because that is the cognitive cost
the reader is paying."

### Locality Drag

Question: did a complex function initialize a local far away from the
place that first uses it?

```ruby
CLASS BillingService
  FN checkout(user, cart, logger)
    receiptId = user.id

    total = cart.total
    IF total > 100 THEN discount = 10 END
    IF cart.taxable? THEN tax = total * 0.2 END
    IF logger.enabled? THEN logger.info(total) END
    IF cart.valid? THEN status = :ready END

    emitReceipt(receiptId)
  END
END
```

`receiptId` is live across a block of work that does not affect it. A
reader has to keep it in mind while scanning unrelated calculation,
logging, validation, or parser work. Often the better shape is to move
the initialization closer to the first use:

```ruby
CLASS BillingService
  FN checkout(user, cart, logger)
    total = cart.total
    IF total > 100 THEN discount = 10 END
    IF cart.taxable? THEN tax = total * 0.2 END
    IF logger.enabled? THEN logger.info(total) END
    IF cart.valid? THEN status = :ready END

    receiptId = user.id
    emitReceipt(receiptId)
  END
END
```

Sometimes the better shape is an extraction instead:

```ruby
CLASS BillingService
  FN checkout(user, cart, logger)
    prepareCart(cart, logger)
    emitReceipt(user.id)
  END
END
```

Decomplex looks for assigned locals whose first later read is separated
by unrelated statements in a non-trivial method. A statement is related
if it touches the local or a local derived from it; everything else
counts as unrelated reader burden. The score rises with unrelated
statement count, line distance, structural boundary crossings, and local
cognitive complexity.

This metric is meant to be reviewed with WICC, Function LCOM, and
Operational Discontinuity. Alone, it often says "move this declaration
closer." Combined with those metrics, it can say "this public function
has trapped private phases."

### Function LCOM

Question: does one function contain multiple independent local data
pipelines?

Class-level LCOM asks whether methods share fields. Function LCOM asks a
smaller question: do local variables inside one method form one connected
data-flow graph?

```ruby
CLASS BillingService
  FN prepareInvoice(price, tax, logger)
    subtotal = price + tax
    total = subtotal.round

    timestamp = now()
    buffer = []
    buffer.push(timestamp)
    logger.info(buffer)

    RETURN [total, buffer]
  END
END
```

There are two local pipelines:

```text
price -> subtotal -> total
timestamp -> buffer -> logger
```

They only meet at the terminal return. That terminal join does not make
the function cohesive; it is often evidence that two concerns are being
packaged together at the end.

Decomplex builds an undirected graph from local interactions:

- `x = y + z` connects `x`, `y`, and `z`.
- variables co-used in a call, branch, return, or side effect are
  connected.
- the terminal statement is also tested separately so late joins do not
  hide independent pipelines.

The metric is high-recall and tier 3. A finding means "inspect for mixed
concerns", not "extract immediately."

### Operational Discontinuity

Question: did the function author visibly separate phases while keeping
them inside one scope?

This metric looks for a structural boundary plus a local lifecycle reset:

```ruby
CLASS Importer
  FN run(input)
    raw = input.fetch(:raw)
    normalized = raw.strip()
    valid = normalized != ""

    # load side table
    path = "/tmp/table"
    bytes = read(path)
    checksum = hash(bytes)
    RETURN checksum
  END
END
```

The blank/comment boundary is not enough by itself. Decomplex also
requires the locals from the first phase to go dead and a new set of
locals to start after the boundary:

```text
dead: raw | normalized | valid
new:  path | bytes | checksum
```

That is a likely implicit sub-function boundary. Sometimes this is fine
setup code. Sometimes it is validation, calculation, IO, and logging
sharing one method because extraction was never done.

Decomplex splits the report by confidence:

- tier 2: repeated resets, explicit `Phase`/`Step`/numbered comments, or
  a high reset score.
- tier 3: the remaining review-only resets.

Parser-shaped `parse_*` methods stay review-only unless they have an
explicit phase marker, because grammar alternatives often look like
phase resets without being extraction-worthy design problems.

### False Simplicity

Question: does the local code look simple while hiding non-local work?

Examples include callbacks, metaprogramming, monkeypatching,
hidden mutation, hidden IO, and dynamic dispatch. In billing code,
`processPayment` may look like one call while actually performing
network IO, state mutation, callbacks, and retries.

### Fat Unions

Question: is a `case` over variants repeatedly reading the same common
members?

If every billing method switches over `CardPayment | BankPayment |
WalletPayment` and each arm reads `amount`, `currency`, and `user`, the
common core probably wants a product type plus a smaller variant.

## Practical Triage

For `BillingService`, the likely report progression is:

1. **State Heatmap** shows `@user_valid`, `@discount`, and `@cart` are
   shared mutable state.
2. **Temporal Ordering Pressure** shows too many public lifecycle
   methods over the same state.
3. **Implicit Control Flow** reports state-dependent call order that
   exists at all, even before a reversed call site appears.
4. **Weighted Inlined Cognitive Complexity** catches a refactor that
   hides the lifecycle inside single-use helpers without reducing reader
   burden.
5. **State-Based Branch Density** shows decisions depending on the
   mutable lifecycle.
6. **Missing Abstractions / Reification Misses / Neglected Conditions**
   show duplicated or inconsistent business rules.

The fix is rarely "split one long method into three methods." That can
make complexity worse by moving implicit control flow around. The usual
fix is to name the missing state transition, hide the lifecycle behind a
smaller public API, and make the required order explicit.
