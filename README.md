# CLEAR

CLEAR is a *memory safe* language, with a *declarative concurrency model*, that runs on a Go-like Green Fiber runtime.

It's designed to be:

 1. Correct
 2. Safe
 3. Understandable
 4. Scalable
 5. *BLAZING* fast

 See [Why These Priorities](docs/why-these-priorities.md) for more details.

## WHAT DOES CLEAR LOOK LIKE

### The *SMOOTH* operator

```ruby
bill = users AS @u
  s> UNNEST @u.orders
  s> SUM _.price * @u.discount;

-- Fuses nested iteration with aggregation. No intermediate allocations.
```

### Combine with in-line error handling

```ruby
FN myFunc(id: Int64, name: String) RETURNS MyPage ->
  val = fetchData(id, name) OR RAISE
   s> parseHeader OR EXIT "Invalid Header"
   s> parseBody OR EXIT "Invalid Body"
   s> fetchUser
      s> RECOVER(defaultUser())
   s> saveToDb(id, name, _);

CATCH Input WITH(ParseError)
  IF __error.context == "Invalid Header" -> logInvalidHeader(__error.snapshot.header());
  RETURN defaultPage();
DEFAULT
  RAISE __error;
END
```

## WHY CLEAR?

* SQL solved the problem of writing code once, and it constantly improving as the engine improves.
* Go proved the engine/run-time being added into the language can be fantastic.
* Rust proved that affine types can manage memory without a garbage collector simply (it's borrow checker is what gives it a bad reputation for being complicated, not Affine types).

CLEAR attempts to merge the best of Rust, Go, and SQL to build the language of the future: one that can constantly leverage new and better architectures and run your code as fast as possible without you having to tell it *HOW* to do that exactly - like SQL code.

### Declarative Concurrency

Concurrency is not hard.  SQL is the most commonly used programming language in the world, and it executes parallel queries quite efficiently.

Concurrency is only hard when you have to tell the computer exactly how to achieve it safely and efficiently.  CLEAR does the hard part for you - like a SQL engine.

In CLEAR, you describe the strategy you want to employ, and the compiler generates the *how*.  When it's mature, you'll be able to trust that it leverages its runtime as efficiently as possible (as Go does currently).

```ruby clear illustrative
-- `notify()` users in parallel, with back pressure
users
  s> CONCURRENT(workers: 8, parallel: TRUE) EACH notify

-- Spawn a short-lived green fiber, do all allocations in an Arena for speed:
BG { @micro:arena -> foo() }
```

### The Finite State Machine Advantage

Because CLEAR's concurrency is declarative, the compiler has total visibility into the lifecycle of your tasks. In Go, every Goroutine requires allocating a continuous stack (often 2KB+), which means 1 million idle connections consumes gigabytes of RAM.

In CLEAR (starting in v0.2), the compiler lowers the vast majority of concurrent tasks (anything that isn't strictly reentrant) into Finite State Machines rather than stack-allocated fibers. This allows CLEAR to handle millions of concurrent operations with the memory footprint of Rust/Tokio's async/await, but with the developer ergonomics of Go's blocking syntax.

### Profile Guided Optimization

In CLEAR, the compiler can tell when you're *probably* employing a bad strategy, and changing it is typically just a one-line fix, rather than a full-app rearchitecture.

For the v0.1-pre release, CLEAR comes with a Control Plane.  It can detect when you've employed a bad strategy.  It works with the profiler to help you pick better strategies.  For some, it can self-correct (like if you picked a bad stack-size for a reentrant fiber).  In the near future, it will correct from contention issues.  In the far future, the Control Plane aims to be able to protect you from even heavily skewed workloads (when you picked the wrong strategy, like shared-nothing).

CLEAR is designed such that you can override default compiler behviors if you know what you're doing, but you rarely have the tools to shoot yourself in the foot, and when you do, CLEAR makes it painfully obvious you could be shooting yourself in the foot.

### Full Access to the Entire C Library

CLEAR lowers to Zig, which has native access to the entire C library.

In addition, Zig supports compiling *to* any target *from* any machine. I.e. you can compile for a Mac architecture from your Linux workstation.

It also has exceptionally fast *debug* build times, but does not produce production binaries as fast as Go.

In general, CLEAR thinks that the people buiding Zig are some of the smartest people in the world, and it has the picked the most practical build system trade-offs. Some Go engineers will likely disagree.

## BUILDING & TESTING

If you want to contribute, see [CONTRIBUTING.md](CONTRIBUTING.md).

### Prerequisites

- **Ruby 3.x** (for the compiler)
- **Bundler** (`gem install bundler`)
- **Zig 0.16.0** (for runtime compilation)
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
# Ruby compiler specs (parallel)
bundle exec prspec spec/

# Transpile integration tests - two ways:
./clear test transpile-tests/                    # Run all at once (139 tests)
./clear test transpile-tests/58_bg.cht           # One at a time

# Package integration
cd transpile-tests/module-integration && zig build test

# FFI integration
cd transpile-tests/ffi-integration && zig build test
```

### Benchmarks

```bash
ruby benchmarks/runner.rb --smoke benchmarks/server/02_json_api/   # CLEAR only, fast (~5s)
ruby benchmarks/runner.rb --fast benchmarks/sequential/04_hashmap/     # All langs, quick (~30s)
ruby benchmarks/runner.rb benchmarks/sequential/04_hashmap/            # Normal (5 runs)
ruby benchmarks/runner.rb --release benchmarks/sequential/04_hashmap/  # Exhaustive (5x load)
ruby benchmarks/runner.rb --all                             # All benchmarks
ruby benchmarks/runner.rb --smoke --all                     # Smoke test everything
ruby benchmarks/runner.rb --cores=4 benchmarks/concurrent/09_kvstore/  # Control core count
```

### Performance

  * On a single core, typically with 0-30% of Perfect C code.
  * In concurrent throughput and p99 latency, typically competitive with Rust/Tokio and Go. 

See [benchmarks/README.md](benchmarks/README.md).

## ⚠️ DISCLAIMER ⚠️

CLEAR is currently in **v0.1-pre** release. It is an architectural preview and is NOT production-ready.

- **Benchmarks**: There's an extensive set of benchmarks, but it is hard to make "apples to apples" concurrent comparisons with mature ecosystems (Go, Rust/Tokio). The current state of benchmarks should serve as evidence CLEAR is not vaporware, and is currently competitive in *many* cases. Take it with a grain of salt.  It should not be considered *proof* of anything - just *some* evidence.
- **Tail Latency**: While throughput is high in the benchmarks, CLEAR's p99.9 latency is **NOT** expected to be competitive with Go's preemptive scheduler across all adversarial workloads in this release (and probably not until the v0.4 release). Go is *nearly* perfect at what its designed to do. CLEAR is unlikely to beat it on the benchmarks its most optimized for any time soon. Go was designed to be relatively easy, have fast build times, exceptional throughput, and p99.9 latency predictability (especially across adversarial workloads). The cost of that is memory. Go was designed in the days when "memory is cheap" reigned supreme. That is somewhat true still, but cache locality is becoming increasingly important. CLEAR *aims* to beat Go in total throughput, use substantially less RAM, have significantly lower latency at p50 across the board and up to p99 in predictable workloads, and to be competitive at p99.9 levels (though Go will likely reign supreme for some adversarial workloads). This is with much added inherent safety and, in CLEAR's opinion, better developer ergonomics that make it substantially easier to accomplish *most* concurrent tasks *correctly*.
- **Standard Library**: The current "standard library" is a barebones shim used for bootstrapping and internal testing. It is highly likely that none of the current internal APIs will survive into the v0.3 release.
- **Stability**: Although CLEAR has an extensive test suite, several significant bugs were identified in the final week before the demo-release. The v0.1-pre release required a major refactor to reach a reasonable level of assurance use-after-free, double-free, and memory leaks won't compile for *most* of the supported language. The v0.1 release will still be an unstable preview and is not representative of the stability goals for v0.2.
- **Safety**: The examples, benchmarks, and transpile-tests cover a wide range of the language and there are no use-after-free, double-free, or memory leaks.  Do not expect that everything you can compile will be as safe as Rust for the v0.1 release (and certainly not before).
- **Linux Only**: CLEAR is not currently cross platform. It will only support x86 Linux until v0.3+.

## KNOWN SCALING ISSUES

* Zig's `std.Thread.Mutex` scales poorly vs Rust's parking_lot at high core counts (2x gap at 32 cores) - see [benchmarks/concurrent/09_kvstore/README.md](benchmarks/concurrent/09_kvstore/README.md).
  * Zig will likely fix these issues before a CLEAR v0.3 release.
  * CLEAR's RwLock (`@shared:writeLocked`) bypasses Zig's stdlib, using `pthread_rwlock_t` with writer-preferring attributes directly.

## VISION

In short, they tell you that you can:

 1. Have the efficiency of Rust,
 2. Or the safety of Pony,
 3. Or the latency predictability of Go,
 4. Or the distribution of BEAM.

Pick one.

CLEAR **aims** to give you **near** best-in-class at all categories, while having a significantly lower cognitive burden / barrier to entry than even Go.

This is **wildly ambitious** and **certainly unproven** in a v0.1-pre release. But CLEAR thinks it has the design to make this **eventually possible**.

How?

  1. To be able to run a REPL / VM, to live-debug like you can in Ruby, to write working code *faster* than you can even in scripting languages.
     - CLEAR aims to achieve a level of fearless concurrency above Rust, Pony, or Elixir.
     - Rust and actor models guarantee memory safety.  But you can still have higher-level logic races / non-deterministic state transitions that are very painful to debug.
     - CLEAR **aspires** to make this as easy as debugging sequential code in a scripting language with a world-class debugger by providing deterministic replay of concurrent events (in the VM).
     - In other languages, Stateless Model Checking is a separate, difficult tool you have to opt into. In CLEAR, it's just how `./clear test` works.
  3. For `./clear doctor` to be able to walk you ~95% of the way from that to HFT-Standards of C speed, and ADA-level safety.
  4. For code, even at the highest-level of optimization, to be easily understandable.
  5. A Control Plane so reliable that even if your most heavily optimized application experiences wildly unpredictible workloads, it can glide through it gracefully.
  6. To be able to distribute loads across multiple machines effortlessly like BEAM, but with native speeds.
