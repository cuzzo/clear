# Why CLEAR

CLEAR is designed to be:

 1. Correct
 2. Safe
 3. Understandable
 4. Scalable
 5. *BLAZING* fast

 ## But Why?

Rust to have memory safety with no overhead - primarily to use for Servo to replace C for Browser Engines and for Kernel development. There are a number of tradeoffs Rust was not willing to make for it to be either 1) easy / understandable, or 2) a better Go.

Yet people are desperate to use Rust as a better Go because it has so much potential to be that.

Pony eliminates nearly all concurrency hazards by design. Rust merely ensures memory safety - which is perhaps the most common and critical concurrency hazard. But despite its safety, Pony is not widely used because the learning curve is too steep.

Rust & Pony were both not willing to make tradeoffs to prioritize ease-of-use or understandability.

Go made those trade-offs. But Go is a thin veneer over C with the most sophisticated runtime in the world bolted on. To achieve best in class speeds Go - like C - relies on loading a footgun and exposing yourself to a number of hazards and developer discipline and/or chosing the right libraries to get it right. It provides valuable best-in-class tooling to help mitigate *some* of these problems.

CLEAR exists because it thinks Rust is not truly safe enough inherently, Pony is not easy enough, and Go is currently the most practical trade-off but is too dangerous and cannot fix its inherent problems.

Further, although Pony literally forces you into the actor pattern - at least at this stage, it is not inherently distributive. The actor model does not require serialization, distributed fault tolerance, supervision, etc. Pony uses the ideas to achieve safety on a single machine, but just because you wrote the code that *allows* for distribution easily, does not mean it actually can be distributed effectively by default.

Pony did not want to make any sacrifices on safety. This led to a language that is impractical and/or not competitive for many of workloads (with a high cognitive burden).

CLEAR **aims** to take the lessons of Pony, Rust, Go, and BEAM and combine them. The goal is to make trade-offs to achieve understandability, and to sacrfice *some* safety if it means giving you tools necessary to realistically accomplish common workloads.

## Rubric

| Feature | C | Rust/Tokio | Go | Pony | BEAM | CLEAR |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Cognitive Load** | F * | D+ | B | D- | C+ | **A-** |
| **Memory Safety** | F | A+ | B * | A+ | A+ | **A+** |
| **Raw Speed** | A+ | A | B+ | A- | C | **A-** |
| **Throughput** | A | A | A+ | A | A | **A** |
| **Memory Usage** | A+ | A+ | B- | B+ | C- | **A-** |
| **Predictability** | A+ | A+ | B- | B+ | A- | **A-** |
| **Backpressure** | F | A | A+ | C | B | **A** |
| **Starvation** | F | B | A | B | A+ | **A-** |
| **Fault Tolerance** | F | F | F | F | A+ | **?** |
| **Deadlock** | F | C | C+ | A+ | A+ | **A- \*** |
| **Memory Ordering** | F | C | B | A+ | A+ | **A-** |
| **Logical TOCTOU** | F | F | F | A+ | A- | **B+** |
| **Causal Ordering** | F | F | F | B+ | C | **B \*** |
| **Stream Ordering** | F | F | F | F | F | **?** |

### Non-CLEAR Ratings: Context & Justification

**All ratings are inherently subjective.** 

  * **The C Cognitive Load Controversy:** C scoring an **F** may be controversial, but "Cognitive Load" here captures the true difficulty of writing *correct* concurrent systems. C’s F is the price it pays for A+ ratings elsewhere; you could write C with a B in cognitive load (e.g., using a single global lock), but throughput would plummet to an F. Similarly, you could bolt on a Garbage Collector to improve safety, but speed and predictability would drop to a C.
  * **The “Best Practices Fallacy”:** Given perfect discipline and SOTA libraries, one can achieve better ratings in C, Rust, or Go. However, "doing it right" is not a scalable systems architecture. These ratings reflect the language’s inherent, default guarantees.
  * **The Rust/Tokio Note:** Rust is graded slightly unfairly as its evaluation includes Tokio. While not part of the core language, it is the *de facto* production standard and its semantics must be evaluated.
  * **The Go Scheduler:** Go experts may feel there isn't enough separation in Throughput/Backpressure. CLEAR praises Go’s runtime and scheduler as one of the most sophisticated pieces of software ever written; these ratings may not do its operational excellence enough justice.
  * **Go Memory Safety:** Go is memory-safe in the conventional sense, but it does not provide strong concurrency-safety or invariant-safety by default. Its practical model often relies on discipline around shared mutable state.
  * **The Pony Asterisk:** Pony’s flawless safety comes at a hit to expressiveness. By forbidding shared mutable state, certain highly efficient data structures (like lock-free graphs) are nearly impossible to write idiomatically.

## CLEAR Ratings: The Architecture

  * **Cognitive Load:** CLEAR is designed so that **Profile Guided Optimization (PGO)** and automated tooling solve the heavy lifting. You write intuitive, sequential code, and the profiler suggests (and injects) the necessary optimization directives based on actual workloads.
  * **Memory Safety:** Like Rust, CLEAR utilizes **Affine Ownership** to guarantee memory safety.
  * **Logical TOCTOU:** Values behind Arcs/Locks cannot escape lexical scope. The compiler can generate **Loom tests** in a deterministic VM to catch dependencies and break them. Use-after-free and race conditions are included in Memory Saftey. Time-related bugs are captured in Causality and Timing / Ordering categories.
  * **Deadlock:** Technical deadlock is not part of CLEAR’s intended concurrency model, and by v0.3 the runtime aims to detect and prevent unbounded lock-wait cycles from silently persisting. Locks are intentionally more cumbersome to use because they are rarely the best-performing or safest solution. When developers opt into lock-based coordination anyway, they are also opting into explicit responsibility for handling lock-related failures correctly. A language like Pony or BEAM which does not have locks deserves a better ranking.
  * **Starvation & Backpressure:** Like BEAM, CLEAR *will* prevent CPU starvation via its cooperative scheduler with automatically injected yielding. It separately tracks per-task memory consumption to kill runaway tasks and enforce backpressure.
  * **Memory Consumption:** CLEAR uses **MVCC** as a default synchronization technique. This adds memory overhead to eliminate common classes of bugs (deadlocks, contention).
  * **Causal Ordering:** CLEAR separates time as a **tense** in the type system, and offers **A+** causal ordering with `@split` streams and solves the concurrent write problem with MVCC and transaction failure handling. But it allows you to "load the foot-gun" (unsafe escape hatches) for specific workloads where predictability is paramount.
  * **Stream Ordering:** CLEAR has not yet determined if it will offer any guarantees to protect against stream ordering related bugs. Frameworks like Flink and Kafka exist to solve this problem. It may not make sense to try to solve it in the runtime/language.
  * **Fault Tolerance:** It is still too early in the design stage to determine a realistic score for CLEAR's fault tolerance story—particularly regarding issues that arise from shared mutable memory and the fact that idempotence is not a first-class function color. 

### Fault Tolerance

CLEAR hopes to have a reasonable ceiling of a **B** (similar to Causality). It will likely give you tools to shoot yourself in the foot to prioritize understandability and broad workload support—for example, you could mark tasks as killable which aren't, or tasks as retrying which aren't idempotent. But CLEAR will have the systems in place to easily support an **A+** architecture when paired with modern infrastructure. 

The fact that everything else scores an **F** besides BEAM is evidence that solving these problems purely at the language level may no longer be the best choice. 

  The approach CLEAR is currently most interested in is targeting the five most common catastrophic faults: 
  1) **CPU Starvation** (Time) 
  2) **Local Heap Exhaustion** (Space) 
  3) **Lexical Orphanhood** (The spawning task died; the work is no longer relevant) 
  4) **Data-Flow Severance** (Producing a stream that no one is listening to) 
  5) **Deadlocks** (Unbounded lock-wait cycles)

CLEAR aims to either safely assassinate the offending fibers automatically (Deadlocks/Orphans) or detect the threshold and force the developer to handle the outcome (OOM limits). 

Whatever CLEAR's final solution ends up being, BEAM folks are likely to look at it and say, "That's basically an F." But CLEAR aims to provide pragmatic value.  Like BEAM folks, CLEAR is of the view that killing entire processes with important state just because you have no built-in fault tolerance is insane.  Unlike BEAM, CLEAR is unlikely to eliminate the possibility of *needing* to do that *occasionally*, but it aims to reduce that need to practically zero.

## How Does CLEAR think about Cognitive Burden

In CLEAR's perspective, a program becomes difficult to understand because of global complexity.

A function is impossible to understand if the entire codebase must be understood to understand the function and line of code you are looking at.

This is why CLEAR aims to completely eradicate all forms of global complexity. If you can understand any function fully by just looking at the function, it is simple.

Rust is not considered difficult because of Affine Ownership.  It is considered difficult because of "Fighting the Borrow Checker" which mainly boils down to Rust's obsession that it must achieve zero-cost abstractions in *ALL* cases - which includes shared-mutable borrows. This is almost entirely the source of confusing lifetime annotations in Rust. If you eliminate this demand, you eliminate most of the "Fighting the Borrow Checker" in Rust complaints. CLEAR has done this. This is because this is Rust's main source of global complexity.

Pony is not considered difficult because it merely has capabilities or because it forces you into the actor pattern. It is difficult because capabilities do are not intuitive. You aren't describing what you *want* to do, you are describing what *can be done*. This is less intuitive.

Go claims to be *easy* - which implies simplicity. But Go allows and often forces you to load footguns to achieve decent performance, lending itself to global complexity and hard-to-understand programs.

Go may claim to be easy, but if you need to write 20 lines of imperative arcana in the precise ceremonial order or rely on a set of libraries to do common things efficiently - it is not truly easy.

In essence, CLEAR thinks SQL proved that it is relatively easy to describe *what* you want to do (your intent), and it is certainly easy to recognize it after the Profiler points you in the right direction for efficiency and safety (one-line optimizaitons clearly separate from code).

It is much harder to think like the computer and tell it *HOW* to do that, or list what *CAN* be done and hope that matches what you want to do.

## How Does CLEAR think about Performance and Speed

**Raw Speed** being a metric should raise some eyebrows.  Performance is not a monolith. It is a balance of competing trade-offs.

From CLEAR's perspective - Correct, Safe, and Understandable are by far the most important pillars of the design that are being balanced.

When CLEAR thinks about speed, it mainly thinks about **single machine** concurrent throughput in compute heavy workloads. CLEAR is looking toward the future of compute rather than the present.

In the future, core count is expected to continue growing faster than memory.  Cache per core has not meaningfully grown much in decades, and CLEAR *assumes* this will not grow as meaningfully as core count in the future.

CLEAR thinks the main **Raw Speed** metrics are: 1) compiling via Zig to get LLVM best in class optimizations to single-core performance, 2) maximizing for **cache locality** as memory read stalls can dominate compute performance benchmarks.

In general, CLEAR aims to overcome added memory, co-operative yielding, and any safety checks by given a level of cache locality that is nearly impossible to reach in any other language.

How?

The core pillar of CLEAR's design is to maximize local reasoning and minimize global complexity. This is what makes CLEAR **simple**, even if it may not be as **easy** as Go. It also **should** allow CLEAR to make compiler optimizations WRT escape analysis that no other language (that we are aware of) can make to maximize cache locality.
