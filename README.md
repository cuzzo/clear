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

In CLEAR, you describe the strategy you want to employ, and the compiler generates the *how*.  When it's mature, you'll be able to trust that it leverages its runtime as efficiently as possible (as Go does currently).

In CLEAR, the compiler can tell when you're *probably* employing a bad strategy, and changing it is typically just a one-line fix, rather than a full-app rearchitecture.

In CLEAR, at runtime, the Control Plane can detect when you've employed a bad strategy and *typically* self correct.  Some issues, like sharding a heavily skewed workload, require a recompile and restart to fix.

CLEAR is designed such that you can override default compiler behviors if you know what you're doing, but you don't have the tools to shoot yourself in the foot.

## BUILDING & TESTING

### Prerequisites

- **Ruby** (for the compiler)
- **Bundler** (`gem install bundler`)
- **Zig 0.15.x** (for the Zig integration test and runtime)

### Ruby Compiler Tests and Benchmarks

```bash
bundle install
bundle exec rspec
```

This runs all Ruby specs covering the lexer, parser, annotator, and transpiler.

```bash
clear test ...
```

This runs the transpile-tests/

### Running / Building individual code

```bash
clear run benchmarks/.../bench.cht
```

This will run an individual benchmark.

```bash
clear run my_script.cht
```

This will run `my_script.cht` (for example).

### Benchmarks

```bash
ruby benchmarks/runner.rb --cores=N
```

This will run all the benchmarks on `N` cores on your machine.

### Zig Package Integration Test

The integration test exercises multi-package compilation using Zig's build system. It transpiles two CLEAR packages (`math` and `geometry`) and a main program, wires them as Zig modules, and runs assertions end-to-end.

```bash
cd transpile-tests/module-integration
zig build test
```

### Performance

There's an extensive performance suite in benchmarks/

Idiomatic CLEAR single core performance vs *perfect* C code is typically between 0-30% slower (in a fraction of the code).

Idiomatic CLEAR multi-core performance is typically 0-10% slower than perfect Rust/Tokio for non-pathological workloads.  It typically outperforms Go, often signficantly, typically using 1/2 the peak memory (no Garbage Collector in CLEAR).

In typical *non-pathological* server workloads (primarily waiting) - idiomatic CLEAR, Rust/Tokio, and Go have similar throughput within ~10% differences.  Though CLEAR and Rust/Tokio both use about half as much memory.

Go's runtime is *extradinarly* optimized to achieve world-class throughput in even adversarial and pathological workloads.  It can substantially outperform Rust/Tokio and CLEAR at the p99 level.

For v0.2, CLEAR aims to close this gap.

