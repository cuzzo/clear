# So You Want To Build A Programming Language?

You should start with an easy one to build!

Some well-known languages are *shockingly* easy to implement *partially*:

* Scheme / Lisp
* Forth
* TCL
* SmallTalk

I would not start with trying to build Rust...

### What are the properties that make a language easy to build?

* **Parsing difficulty:** Dependent on grammar and syntax.
* **Annotation / Type difficulty:** You can typically trade annotation in the parser for type difficulty in the VM, but not eliminate both.
* **Memory Management:** Easy mode = just leak memory, but RefCounting is nearly as easy.
* **Compilation / Interpretation difficulty:** Can be as simple as 7 primitives.

So you could build a fully functioning language in **< 300 dense lines of code** (not counting comments, whitespace, or end-only lines).

---

### The Comparison Matrix

| Language | Parsing Difficulty | Annotation (Type System) | Memory Management | Interpretation Complexity |
| --- | --- | --- | --- | --- |
| **Scheme** | Trivial. S-expressions do all the heavy lifting. | None. Fully dynamic; types attached to values. | GC / Leaking. Toy versions leak; real ones need GC. | Minimal. The "7 Primitives" (car, cdr, etc.). |
| **Forth** | Non-existent. Whitespace-delimited words. | Zero. No types, only cells on a stack. | Manual. User manages stack; VM stays out of it. | Low. Loop that looks up "words" in a dictionary. |
| **TCL** | Low. "Everything is a string" eliminates complex ASTs. | None. Strings are the only currency. | Buffers. Ref-counting is common; string buffers work. | Moderate. Heavy reliance on a command-dispatch table. |
| **Smalltalk** | Minimal. Postcard-sized grammar based on messages. | Purely Dynamic. Everything is an object; late dispatch. | Heavy. Requires real GC or Image for anything serious. | Elegant. Everything is a message pass. |

 * **Scheme and SmallTalk** typically require a Garbage Collector (GC) to be functional.
 * **TCL** requires a command-dispatch table.
 * **Forth** is truly easy to implement, but can feel alien to use.

What if we wanted something **ALMOST** as easy as Forth to implement, but with a syntax that is much more intuitive and natural (thus easier to understand)?

---

## Oberon to the Rescue

Standard Oberon, much like standard Lisp, is massive and not easy to implement. But what if we stripped it down?

You can implement working versions of Scheme in almost as little code as Forth, but you are still stuck with Lisp's heavily parenthesized notation. **Oberon**, on the other hand, is an **ALGOL descendant**. It reads like a slightly-less ergonomic version of JavaScript or Ruby.

By designing a highly constrained dialect of Oberon, you get the best of both worlds: a language that is trivial to parse and build, but uses a syntax most modern programmers immediately understand.

> **The Trade-off:** The parser will be the largest part of the language, but it is simple and mundane. ALGOL descendants like Oberon trade more parsing logic to make the compiler and VM considerably easier than Lisp / Scheme. It is almost objectively simpler, even if it is ~50-70 dense lines of code longer (20-30%).

### What does Oberon Look Like?

```pascal
PROCEDURE Factorial(n: INTEGER): INTEGER;
  VAR result: INTEGER;
  BEGIN
    IF n <= 1 THEN
      result := 1
    ELSE
      result := n * Factorial(n - 1)
    END;
    RETURN result
  END Factorial;
```

It is less ergonomic than a Ruby one-liner:

```ruby
def factorial(n) n <= 1 ? 1 : n * factorial(n-1) end
```

But such is the price you pay to implement a language in ~250 lines of code instead of ~250,000.

---

## Why Oberon looks this way

### 1. LL(1) Parsing

In plain English, **LL(1)** means your parser reads the text left-to-right and only ever needs to look ahead by **1 single word (token)** to know exactly what to do next. There is no guessing and no backtracking.

This is why we use the `:=` operator for assignment. In high-level languages:

* `x = 1` (Declare and assign)
* `x = 2` (Reassign)

In an LL(1) language, this is ambiguous. In Oberon, we separate them:

* `VAR x: INTEGER;` (Declare)
* `x := 1;` (Assign)

This is also why we use `IF ... THEN` and `END;`. Although not strictly needed, without them, the compiler can't easily tell where one block stops and the next begins.

### 2. Types

Oberon is **statically typed**. While dynamic typing sounds easier, it is a runtime headache. Every time you execute `x + y` in a dynamic C runtime, you must unpack structs, check types, and handle errors. It is slow and requires defensive code - that can become massive with a more complex type system. Implementing a typed language is considerably easier. As a bnous, it allows for a simple **JIT** later.

---

## The Seven Magic Primitives

In 1960, John McCarthy famously proved that you only need seven basic operations (`car`, `cdr`, `cons`, `quote`, `atom`, `eq`, `cond`) to compute literally anything in the universe using Lisp.

But we aren’t building a Lisp interpreter. We are building a statically typed, minimal Oberon.

Our "primitives" aren't list manipulators; they are the fundamental atoms of the CPU. The beauty of compilation is that no matter how complex your high-level language gets, it all eventually boils down to a tiny handful of incredibly dumb operations.

If you look back at our `Factorial` example, it seems like there is a lot of high-level logic happening. But to a CPU, that entire program is just a combination of these seven primitive instructions:

 * `LOAD`: Read a value from memory (like looking up the variable n).
 * `STORE`: Write a value to memory (like the := assignment to result).
 * `MATH`: Perform basic arithmetic (Add, Subtract, Multiply).
 * `COMPARE`: Look at two numbers and set a microscopic flag in the CPU if they are equal, greater, or lesser (e.g., checking n <= 1).
 * `JUMP_IF_FALSE`: The secret sauce of all logic. If the previous COMPARE flag was false, skip the next few lines of code. (This is how an IF statement actually works under the hood).
 * `JUMP`: Unconditionally jump to another line of code. (This is how you skip over the ELSE block after finishing an IF block, or how you loop back to the top of a WHILE loop).
 * `CALL` / `RETURN`: Pause current execution, jump to a new function, and when it hits `RETURN`, magically warp back to exactly where it left off.

---

## The Breakdown

What we will implement:

 * **A parser:** shockingly easy for LL(1) with an extremely minimal grammar, nearly as easy as Lisp or even Forth
 * **A bytecode compiler:** to compile our language down to 7 byte code operations
 * **A VM:** to run the 7 bytecodes and execute any program computable.


## The Language

Our core language consists of 10 constructs:

 * `MODULE` / `BEGIN` / `END`: The outer wrapper of our program.
 * `VAR`: Variable declarations (e.g., `VAR x: INTEGER;`).
 * `PROCEDURE` / `RETURN`: For creating our own reusable functions.
 * `CALL`: Executing those functions (e.g., `Factorial(5)`).
 * `:=` (Assignment): Storing values in memory (e.g., `x := 10;`).
 * `Expressions` (Math & Logic): Handling basic arithmetic (`+`, `-`, `*`) and comparisons (`=`, `<=`).
 * `IF` / `THEN` / `ELSE`: Basic conditional branching.
 * `LOOP` / `EXIT`: The only iteration construct we need. (We skip WHILE and FOR loops—a generic LOOP with an EXIT condition is much easier to parse and can do the exact same things).
 * `SYSCALL`: To do everything we can’t do, like open files, print to the console, read sockets, etc
 * `MACRO`: To expand our language within our own language, to make it surprisingly user-friendly
    * This allows a ~600 LOC language to feel almost as user-friendly as ~250,000 LOC language, in a way Lisp/Scheme cannot really achieve - the syntax is what it is.
    * **Note**: This will not be in the initial implementation, as building a text-expansion engine makes the parsing almost 2x as hard!

This is all you need to build a *shockingly* usable language.

---

## The Scope

First, over 6 stages we will implement the prototype in Ruby, so that it's incredibly easy to understand, and only about ~250 lines of code.

Finally, we will add `MACRO` to the parser, which will nearly double the size of the Ruby parser, but will make our language quite usable!

You can probably follow all of this in an evening or two.

 * Add on another to support macros.
 * Add in another day or two to write a C VM that's ~100x faster, and to self-host Oberon.
 * And another two to understand JIT.

The first version will be slow, but very understandable. 

 * We will re-implement the VM in C.
 * That will take our Ruby VM from ~75 lines of code ~300, and nearly double the project size, but speed up runtimes by 100x.
 * In this process you'll learn how and why things can be slow, a lot about how computers actually work, and - trust me - it'll be more fun than it sounds.

### What's not in Scope

Our language will not do a number of things:

 * Have nice, helpful errors
 * Optimize aggressively (without JIT)
 * Support concurrency
 * Prevent memory leaks (RefCounting can easily leak in graphs)


## The Pipeline

### 0. Source Code

The raw text the programmer writes: 
```pascal
IF n <= 1 THEN ... END;
```

### 1. Tokenizer

Breaks the raw string into a flat list of categorized words (tokens), throwing away spaces and formatting:

```
[IF, SYMBOL:n, OPERATOR:<=, INTEGER:1, THEN, ..., END]
```

### 2. Parser

Reads the tokens left-to-right and groups them into our 9 language constructs, in an Abstract Syntax Tree (AST):

```
IfStatement(
   condition: LessThanOrEqual( Variable(n), Integer(1) ),
   body: [ ... ]
)
```

### 3. Compiler

Flattens that tree down into our 7 primitive machine instructions (Bytecode):

```
001: LOAD n
002: LOAD 1
003: COMPARE_LTE
004: JUMP_IF_FALSE 089 # (Skip to line 89 if n is not <= 1)
```

### 4. The VM
The loop that actually reads those instructions one by one and executes them on your physical CPU.

---

## Roadmap: The Seven Versions

1. **V1:** Minimal tokenizer, parser, compiler, VM. Prints "42" (~80 dense lines).
2. **V2:** Define and call a function. Split into four files (~120 dense lines).
3. **V3:** FizzBuzz program with a loop (~200 dense lines).
4. **V4:** Add GC/RefCounting (~220 dense lines).
5. **V5:** Add Strings (~230 dense lines).
6. **V6:** Add `MODULE` for a standard library (~270 dense lines).
7. **V7:** Add `MACRO` for Structs and advanced syntax (~350 dense lines).

---

You can jump to [V1](v1/README.md) to get started, and see how you can make a *very* minimal programming langauge in ~80 lines of code.
