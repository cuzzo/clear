# Why CLEAR

CLEAR is designed to be:

 1. Correct
 2. Safe
 3. Understandable
 4. Scalable
 5. *BLAZING* fast

 ## But Why?

Rust was designed to replace C for Browser Engines & Kernel development. There are a number of tradeoffs Rust was not willing to make for it to be either 1) easy / understandable, or 2) a better Go.

Yet people are desperate to use Rust as a better Go because it has so much potential to be that.

Pony eliminates nearly all concurrency hazards by design. Rust merely ensures memory safety - which is perhaps the most common and critical concurrency hazard. But despite its safety, Pony is not widely used because the learning curve is too steep.

Rust & Pony were both not willing to make tradeoffs to prioritize ease-of-use or understandability.

Go made those trade-offs. But Go is a thin veneer over C with the most sophisticated runtime in the world bolted on. To achieve best in class speeds Go - like C - relies on loading a footgun and exposing yourself to a number of hazards and developer discipline and/or chosing the right libraries to get it right. It provides valuable best-in-class tooling to help mitigate *some* of these problems.

CLEAR exists because it thinks Rust is not truly safe enough inherently, Pony is not easy enough, and Go is currently the most practical trade-off but is too dangerous and cannot fix its inherent problems.

Further, although Pony literally forces you into the actor pattern - at least at this stage, it is not inherently distributive. The actor model does not require serialization, distributed fault tolerence, supervision, etc. Pony uses the ideas to achieve safety on a single machine, but just because you wrote the code that *allows* for distribution easily, does not mean it actually can be distributed effectively by default.

Pony did not want to make any sacrifices on safety. This led to a language that is impractical and/or not competitive for many of workloads (with a high cognitive burden).

CLEAR **aims** to take the lessons of Pony, Rust, Go, and BEAM and combine them. The goal is to make trade-offs to achieve understandability, and to sacrfice *some* safety if it means giving you tools necessary to realistically accomplish common workloads.

## Rubric

| Feature | C | Rust/Tokio | Go | Pony | BEAM | CLEAR |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **Cognitive Load** | F * | D+ | B | D- | C+ | **A-** |
| **Raw Speed** | A+ | A+ | A- | A | C | **A** |
| **Throughput** | A | A | A+ | A | A | **A** |
| **Memory Usage** | A+ | A+ | B- | B+ | C- | **A-** |
| **Predictability** | A+ | A+ | B+ | A- | A- | **A** |
| **Memory Safety** | F | A+ | B * | A+ | A+ | **A+** |
| **Memory Ordering** | F | F | F | A+ | A+ | **A+** |
| **TOCTOU** | F | F | F | A+ | A- | **B+** |
| **Deadlock** | F | F | F | A+ | A+ | **A- \*** |
| **Starvation** | F | B | A | B | A+ | **A-** |
| **Causality** | F | F | F | B | B | **B \*** |
| **Backpressure** | F | A | A+ | D | C | **A** |
| **Time / Ordering** | F | F | F | F | F | **A** |

### Non-CLEAR Ratings: Context & Justification

**All ratings are inherently subjective.** 

  * **The C Cognitive Load Controversy:** C scoring an **F** may be controversial, but "Cognitive Load" here captures the true difficulty of writing *correct* concurrent systems. C’s F is the price it pays for A+ ratings elsewhere; you could write C with a B in cognitive load (e.g., using a single global lock), but throughput would plummet to an F. Similarly, you could bolt on a Garbage Collector to improve safety, but speed and predictability would drop to a C.
  * **The “Best Practices Fallacy”:** Given perfect discipline and SOTA libraries, one can achieve better ratings in C, Rust, or Go. However, "doing it right" is not a scalable systems architecture. These ratings reflect the language’s inherent, default guarantees.
  * **The Rust & Tokio Note:** Rust is graded slightly unfairly as its evaluation includes Tokio. While not part of the core language, it is the *de facto* production standard and its semantics must be evaluated.
  * **The Go Scheduler:** Go experts may feel there isn't enough separation in Throughput/Backpressure. CLEAR praises Go’s runtime and scheduler as one of the most sophisticated pieces of software ever written; these ratings may not do its operational excellence enough justice.
  * **The Pony Asterisk:** Pony’s flawless safety comes at a hit to expressiveness. By forbidding shared mutable state, certain highly efficient data structures (like lock-free graphs) are nearly impossible to write idiomatically.

## CLEAR Ratings: The Architecture

  * **Cognitive Load:** CLEAR is designed so that **Profile Guided Optimization (PGO)** and automated tooling solve the heavy lifting. You write intuitive, sequential code, and the profiler suggests (and injects) the necessary optimization directives based on actual workloads.
  * **Memory Safety:** Like Rust, CLEAR utilizes **Affine Ownership** to guarantee memory safety.
  * **TOCTOU:** Values behind Arcs/Locks cannot escape lexical scope. The compiler can generate **Loom tests** in our deterministic VM to catch dependencies and break them.
  * **Deadlock:** CLEAR uses locks for read-heavy workloads where MVCC unpredictability is a non-starter. If locks detect deadlock, they will park; if parked over a configured time, they *can* die (if the task is marked killable).
  * **Starvation & Backpressure:** Like BEAM, CLEAR prevents CPU starvation via a preemptive scheduler. It separately tracks per-task memory consumption to kill runaway tasks and enforce backpressure.
  * **Memory Consumption:** CLEAR uses **MVCC** as a default synchronization technique. This adds memory overhead to eliminate common classes of bugs (deadlocks, contention).
  * **Causality:** CLEAR offers **A+** causality with MVCC and `@split` streams, but allows you to "load the foot-gun" (locks) for specific read-heavy workloads where predictability is paramount.
  * **Time / Ordering:** CLEAR separates time as a **tense** in the type system. Time can only be shared via streams through the `@split` capability, guaranteeing ordering across shared
