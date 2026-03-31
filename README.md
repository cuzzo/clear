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

### DECLARATIVE CONCURRENCY

Concurrency is not hard.  We do it every day in SQL queries as effiently as possible.

Concurrency is only hard when you have to do it yourself.  That's why CLEAR eliminates that need.

In CLEAR, you describe the strategy you want to employ, and the compiler generates the *how*.  When it's mature, you'll be able to trust that it leverages its runtime as efficiently as possible (as Go does currently).

### PROFILE GUIDED OPTIMIZATION

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

#### Single-Core (Benchmark 05: HashMap, 1M keys)

CLEAR's numeric HashMap outperforms hand-optimized C with FNV-1a hashing. CLEAR uses Zig's AutoHashMap with frame-arena allocation - zero GPA calls in the hot path.

| Language | Variant | Insert | Lookup | Total | vs C String |
|----------|---------|--------|--------|-------|-------------|
| C | string key, FNV-1a | ~180 ms | ~170 ms | ~350 ms | 1.0x (baseline) |
| C | f64 key, bit-cast | ~130 ms | ~70 ms | ~200 ms | 0.57x |
| CLEAR | string key, frame | ~580 ms | ~155 ms | ~735 ms | 2.1x |
| CLEAR | numeric i64 key | ~110 ms | ~58 ms | ~168 ms | **0.48x** |

Idiomatic CLEAR single-core performance vs hand-optimized C is typically 0-30% slower for string workloads, and competitive or faster for numeric workloads.

#### Single-Core KV Store (Benchmark 20: RESP protocol, vs Dragonfly)

A RESP-compatible TCP KV store tested with `redis-benchmark`. Single thread, 100K operations, 50 concurrent connections. CLEAR uses `@sharded(8):locked` HashMap with fiber-per-connection.

**With pipelining (P=16):**

| Server | SET rps | GET rps | SET p50 | SET p99 | GET p50 | GET p99 |
|--------|---------|---------|---------|---------|---------|---------|
| **CLEAR** | **471,698** | **438,596** | **0.87 ms** | **4.29 ms** | **0.87 ms** | **5.89 ms** |
| Dragonfly v1.37 | 126,422 | 153,846 | 5.50 ms | 11.80 ms | 4.35 ms | 11.40 ms |

**Without pipelining:**

| Server | SET rps | GET rps | SET p50 | SET p99 | GET p50 | GET p99 |
|--------|---------|---------|---------|---------|---------|---------|
| **CLEAR** | **34,638** | 30,395 | **0.97 ms** | **2.90 ms** | **1.08 ms** | 4.30 ms |
| Dragonfly v1.37 | 26,947 | **27,457** | 1.30 ms | 3.58 ms | 1.24 ms | **3.79 ms** |

CLEAR is 3.7x faster on pipelined SET and 2.9x faster on pipelined GET. Without pipelining, CLEAR is ~25% faster on SET with better p50/p99 latency.

#### Multi-Core, Non-Adversarial (Benchmark 24: TCP JSON API)

CLEAR, Rust/Tokio, and Go achieve similar throughput within ~5% for typical server workloads. CLEAR and Rust use roughly half the peak memory of Go (no garbage collector).

| Server | SET (ms) | GET (ms) | Verified |
|--------|----------|----------|----------|
| Rust/Tokio | 1292 | 20830 | 10000/10000 |
| Go | 1252 | 20393 | 10000/10000 |
| **CLEAR** | **1089** | 21080 | 10000/10000 |

*10K GETs, 50 concurrent connections, all verified.*

#### Multi-Core, Adversarial (Benchmark 25: Pathological Workloads)

NOTE: CLEAR performs well in these benchmarks, but in the ugly world of reality, it is highly unlikely to be this competitive with Go at p99.9 in adversarial workloads.

Benchmark 25 tests scheduler fairness under adversarial load using iterated SHA256 hashing. Three phases: uniform (all equal), skewed (1% of requests 1000x heavier), and adversarial (one connection does all heavy work).

**Phase 1: Uniform (50K requests, 50 concurrent)**

| Server | p50 | p99 | p99.9 | Throughput |
|--------|-----|-----|-------|------------|
| Rust/Tokio | 4.89 ms | 12.86 ms | 16.65 ms | 9228 req/s |
| Go | 5.50 ms | 16.14 ms | 26.82 ms | 8043 req/s |
| CLEAR | 5.36 ms | 14.21 ms | 18.52 ms | 8418 req/s |

**Phase 2: Skewed (1% of requests 1000x heavier, 50K requests, 50 concurrent)**

| Server | p50 | p99 | p99.9 | Throughput |
|--------|-----|-----|-------|------------|
| Rust/Tokio | 4.30 ms | 32.69 ms | 59.12 ms | 7015 req/s |
| Go | 4.10 ms | 25.82 ms | 36.86 ms | 7733 req/s |
| **CLEAR** | 4.18 ms | **23.71 ms** | **33.71 ms** | **8086 req/s** |

**Phase 3: Adversarial (1 connection all-heavy, 49 all-light, 50K requests, 50 concurrent)**

| Server | p50 | p99 | p99.9 | Throughput |
|--------|-----|-----|-------|------------|
| Rust/Tokio | 3.21 ms | 34.80 ms | 73.75 ms | 2868 req/s |
| Go | 2.95 ms | 15.63 ms | 30.54 ms | 3492 req/s |
| **CLEAR** | **2.80 ms** | 16.36 ms | **21.41 ms** | **3635 req/s** |

CLEAR wins on throughput and p99.9 in the adversarial phase. Go's preemptive scheduler gives it the best p99 under adversarial load, but CLEAR's cooperative scheduling with per-iteration yields is competitive across all percentiles.
