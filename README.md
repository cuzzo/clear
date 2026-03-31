# CLEAR

## PROPAGANDA

*Cheating is all you need.*

* Software should be performant, robust, AND resilient.
* It should also be effortless to write and understand.
* It should be able to run anywhere, optimized for distributed parallelism and concurrency.

They told you "Pick one." They lied.

You can have it all, if you're willing to CHEAT.

**Commands like SQL. Pipelines like Bash. Easy like Ruby. Speed like C.**

Being a genius like *antirez* isn't scalable. It's not something everyone can be.

Everyone else can CHEAT.

## WHAT IS CHEAT?

CLEAR is a memory safe language like Rust, with better ergonomics than Swift.

It runs on a Go-like Runtime (the CHEAT runtime) that makes concurrent code as easy, safe, and fast as possible.

## CORE CLEAR PHILOSOPHY

* Code should work.
* Code that is easy to understand, write, AND test is more likely to work.
* Dependencies should be Strictly-Correct, as that *IS* their business logic.
* Applications should *FIRST* be Business-Logic correct, only Strictly-Correct if need be.
* The language and compiler should never get in the way of Business-Logic correctness.
* Making things Strictly-Correct, once Business-Logic correct, should be easy.
* Making things *BLAZING* fast, once Strictly-Correct, should be easy.

## WHAT DOES CLEAR LOOK LIKE

### The *SMOOTH* operator

```ruby
bill = users AS @u
  s> UNNEST _.orders
  s> SELECT _.price * @u.discount
  s> COCURRENT REDUCE(0, (acc, x) -> acc + x );

-- Automatically generates efficient, parallel partial reduction.
```

### Combine with in-line error handling

```ruby
FN myFunc(a, b, c) ->
  val = fetchData(a, b, c) OR RAISE
   s> parseHeader OR EXIT "Invalid Header"
   s> parseBody OR EXIT "Invalid Body"
   s> fetchUser
      s> RECOVER(DefaultUser())
   s> saveToDb(a, b, c, %%)

CATCH ParseError WITH("Invalid Header")
  logInvalidHeader(%e.snapshot.header());
  RETURN defaultPage();
DEFAULT
  logUnknownError(%e)
  raise %e
END
```

## WHY CLEAR?

* SQL solved the problem of writing code once, and it constantly improving as the engine improves.
* Go proved the engine/run-time being added into the language can be fantastic.
* Rust proved that affine types can manage memory without a garbage collector simply (it's borrow checker is what gives it a bad reputation for complicated, not Affine types).

Rust & Go need to be combined to build the language of the future: one that can constantly leverage new and better architectures and run your code as fast as possible without you having to tell it *HOW* to do that exactly - like SQL code.

### Declarative Concurrency

Concurrency is not hard.  We do it every day in SQL queries as effiently as possible.

Concurrency is only hard when you have to do it yourself.  That's why CLEAR eliminates that need.

In CLEAR, you describe the strategy you want to employ, and the compiler generates the *how*.  When it's mature, you'll be able to trust that it leverages its runtime as efficiently as possible (as Go does currently).

### Profile Guided Optimization

In CLEAR, the compiler can tell when you're *probably* employing a bad strategy, and changing it is typically just a one-line fix, rather than a full-app rearchitecture.

In CLEAR, at runtime, the Control Plane can detect when you've employed a bad strategy and *typically* self correct.  Some issues, like sharding a heavily skewed workload, require a recompile and restart to fix.

CLEAR is designed such that you can override default compiler behviors if you know what you're doing, but you don't have the tools to shoot yourself in the foot.

## BUILDING & TESTING

### Prerequisites

- **Ruby 3.x** (for the compiler)
- **Bundler** (`gem install bundler`)
- **Zig 0.15.x** (for runtime compilation)
- **Go 1.21+** (for benchmark baselines, optional)
- **Rust/Cargo** (for benchmark baselines, optional)

### Quick Start

```bash
bundle install                       # Install Ruby dependencies (one time)

./clear build hello.cht              # Compile a CLEAR program
./clear run hello.cht                # Build + execute
./clear test hello.cht               # Test with leak detection
```

### The `clear` CLI

```bash
# Build
./clear build foo.cht                # Produces ./foo binary
./clear build foo.cht -o bin/app     # Custom output path
./clear build foo.cht --safe         # With bounds/overflow checks (-O ReleaseSafe)

# Run
./clear run foo.cht                  # Build + execute
./clear run foo.cht -- --port 8080   # Pass arguments to the program
CLEAR_THREADS=0 ./clear run app.cht  # Multi-threaded fiber runtime

# Test
./clear test foo.cht                 # Test with GPA leak detection + scheduler
```

FFI modules (`.zig` files referenced via `EXTERN ... FROM`) are auto-detected and linked.

### Test Suites

```bash
# Ruby compiler specs (1343 examples)
bundle exec rspec

# Transpile integration tests - two ways:
./clear test transpile-tests/58_bg.cht           # One at a time (129 tests)
ruby transpile-tests/gen.rb && \
  cd zig && zig test all-tests.zig -lc switch.S onRoot.S  # All at once (130 tests, faster)

# Package integration
cd transpile-tests/module-integration && zig build test

# FFI integration
cd transpile-tests/ffi-integration && zig build test
```

### Benchmarks

```bash
ruby benchmarks/runner.rb --smoke benchmarks/24_json_api/   # CLEAR only, fast (~5s)
ruby benchmarks/runner.rb --fast benchmarks/05_hashmap/     # All langs, quick (~30s)
ruby benchmarks/runner.rb benchmarks/05_hashmap/            # Normal (5 runs)
ruby benchmarks/runner.rb --release benchmarks/05_hashmap/  # Exhaustive (5x load)
ruby benchmarks/runner.rb --all                             # All benchmarks
ruby benchmarks/runner.rb --smoke --all                     # Smoke test everything
ruby benchmarks/runner.rb --cores=4 benchmarks/17_kvstore/  # Control core count
```

### Performance
*** Single-Core (HashMap):***
 * Numeric i64 keys outperform hand-optimized C by ~2x due to Zig's AutoHashMap and frame-arena allocation.
 * Sring workloads and other workloads typically remain within 0-30% of hand-optimzied C.

*** Multi-Core, Non-Adversarial:***
  * Achieves throughput parity (within 5%) with Rust/Tokio and Go.
  * CLEAR uses similar peak memory to Rust, about ~50% of Go due to the absence of a garbage collector.

*** Multi-Core, Adversarial (Pathological Workloads):***
  * Demonstrates high throughput and competitive p99.9 latency under skewed/adversarial loads using cooperative scheduling.
     * Though Go's preemptive scheduler maintains a slight edge in p99 consistency.

*** Reality: Multi-Core KV Store (vs Dragonfly):***
 * Matches Dragonfly's raw I/O and sharded HashMap throughput (within 5-10%) and offers better p99 latency.
    * Explicit caveat that this compares a minimal parser to a feature-complete production database.
    * Though this is achieved in ~50 lines of code.

See [docs/benchmarks.md](docs/benchmarks.md) for table comparisons.

## DISCLAIMER

CLEAR is currently in **v0.1-pre** release. It is an architectural preview and is NOT production-ready.

- **Benchmarks**: While we have performed extensive benchmarking, "apples to apples" comparisons with mature ecosystems (Go, Rust, C) are difficult. Our results demonstrate raw engine potential, not feature-complete parity.
- **Tail Latency**: While throughput is high, CLEAR's p99.9 latency is **NOT** expected to be competitive with Go's preemptive scheduler across all adversarial workloads in this release.
- **Standard Library**: The current "standard library" is a barebones shim used for bootstrapping and internal testing. It is highly likely that none of the current internal APIs will survive into the v0.3 release.
- **Stability**: Although CLEAR has an extensive test suite, several significant bugs were identified in the final week before this pre-release. The current state is an unstable preview and is not representative of the stability goals for v0.2.


