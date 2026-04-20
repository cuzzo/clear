# Why CLEAR

CLEAR is designed to be:

 1. Correct
 2. Safe
 3. Understandable
 4. Scalable
 5. *BLAZING* fast

 ## But Why?

Rust was designed to replace C for the Linux Kernel. There are a number of tradeoffs Rust was not willing to make for it to be either 1) easy / understandable, or 2) a better Go.

Yet people are desperate to use Rust as a better Go because it has so much potential to be that.

Pony eliminates nearly all concurrency hazards by design. Rust merely ensures memory safety - which is perhaps the most common and critical concurrency hazard. But despite the safety, it's not widely used because the learning curve is too steep.

Rust & Pony were both not willing to make tradeoffs to prioritize ease-of-use or understandability.

Go made those trade-offs. But Go is a thin veneer over C with the most sophisticated runtime in the world bolted on. To achieve best in class speeds relies on - like C - loading a footgun and exposing yourself to a number of hazards and developer discipline to get it right. It provides valuable best-in-class tooling to help mitigate *some* of these problems.

CLEAR exists because it thinks Rust is not truly safe enough inherently, Pony is not easy enough, and Go is currently the most practical trade-off but is too dangerous and cannot fix its inherent problems.

Further, although Pony literally forces you into the actor pattern - at least at this stage, it is not inherently distributive.

CLEAR **aims** to take the lessons of Pony, Rust, Go, and BEAM and combine them. The goal is to make trade-offs to achieve understandability, and to sacrfice *some* safety if it means giving you tools necessary to realistically accomplish common workloads.