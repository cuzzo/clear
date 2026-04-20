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

Pony eliminates nearly all concurrency hazards by design. Rust merely ensures memory safety - which is perhaps the most common and critical concurrency hazard. But despite its safety, Pony not widely used because the learning curve is too steep.

Rust & Pony were both not willing to make tradeoffs to prioritize ease-of-use or understandability.

Go made those trade-offs. But Go is a thin veneer over C with the most sophisticated runtime in the world bolted on. To achieve best in class speeds Go - like C - relies on loading a footgun and exposing yourself to a number of hazards and developer discipline and/or chosing the right libraries to get it right. It provides valuable best-in-class tooling to help mitigate *some* of these problems.

CLEAR exists because it thinks Rust is not truly safe enough inherently, Pony is not easy enough, and Go is currently the most practical trade-off but is too dangerous and cannot fix its inherent problems.

Further, although Pony literally forces you into the actor pattern - at least at this stage, it is not inherently distributive. The actor model does not require serialization, distributed fault tolerence, supervision, etc. Pony uses the ideas to achieve safety on a single machine, but just because you wrote the code that *allows* for distribution easily, does not mean it actually can be distributed effectively by default.

Pony did not want to make any sacrifices on safety. This led to a language that is impractical and/or not competitive for many of workloads (with a high cognitive burden).

CLEAR **aims** to take the lessons of Pony, Rust, Go, and BEAM and combine them. The goal is to make trade-offs to achieve understandability, and to sacrfice *some* safety if it means giving you tools necessary to realistically accomplish common workloads.