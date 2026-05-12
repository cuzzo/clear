# The V1 Implemetation - an introduction to Stack Machines

To understand our VM, forget about complex registers. Imagine a stack of cafeteria trays.

 * You can only ever interact with the top tray.
 * PUSH: You put a new tray (a number) on top of the stack.
 * POP: You take the top tray off to look at it or use it.

## Why is this simple?

In a traditional CPU (like the one in your laptop), you have to manage specific "registers" (tiny boxes labeled EAX, EBX, etc.). It’s like juggling. 

In a Stack Machine, you don't care where data is. You just know that if you want to add two numbers, they *must* be the two trays on top.

### How our V1 VM works:

Our VM has three parts:

 * **The Stack:** For temporary work (like holding the number 42 for a split second).
 * **Memory:** A row of cubby holes where we store variables for the long term.
 * **The Instruction Pointer (IP):** A finger pointing at the current line of Bytecode.

### The Instruction Set (The Primitives)

In our V1 example, we only need four "dumb" instructions to do everything:

| Instruction | What It Does |
| --- | --- |
| PUSH 42 | Put the number 42 on top of the stack. |
| STORE 0 | Take the top stack value and move it into Memory Cubby #0. |
| LOAD 0 | Take the value in Memory Cubby #0 and put a copy back on the stack. |
| SYSCALL 1 | Pop the top value and print it to the screen. |

### The Compiler: The "Translator"

The compilers job is to transform *Puck code* into *Stack Machine code*.

Let's look at how the Compiler handles our example line by line:

**Case A:** The Assignment (`result := 42;`)

The programmer wants to save a value. The Compiler breaks this into two machine steps:

```
PUSH 42   # "Hey VM, hold this number."
STORE 0   # "Now put that number into the first available memory slot (which we'll call result)."
```

**Case B:** The Syscall (`SYSCALL(1, result);`)

The programmer wants to see the result. The Compiler translates:

```
LOAD 0      # "Go get the value from the result slot and put it on the stack."
SYSCALL 1   # "Take that value and hand it to the Operating System to print."
```

---

## A full example

You can view the Ruby code for the compiler and VM in [puck.rb](v1/puck.rb).

### Step 0: User Code

```pascal
result := 42;
SYSCALL(1, result);  # SYSCALL 1 is PRINT
```

> NOTE: Later there will be a nice `PRINT(result)` function, when we introduce `MACRO`s.

### Step 1: Tokenizer

The tokenizer turns this into a long list of tokens with meanings.

Output (The Token Stream):

```
[
  # Line 1: result := 42;
  [:SYMBOL, "result"],
  [:OPERATOR, ":="],
  [:INTEGER, 42],
  [:OPERATOR, ";"],

  # Line 2: SYSCALL(1, result); 
  [:SYSCALL, "SYSCALL"],
  [:OPERATOR, "("],
  [:INTEGER, 1],
  [:OPERATOR, ","],
  [:SYMBOL, "result"],
  [:OPERATOR, ")"],
  [:OPERATOR, ";"]
]
```

### Step 2: Parser

The Parser takes that flat list of tokens and groups them into logical "sentences" called Abstract Syntax Tree (AST) Nodes. 

It ignores punctuation like `;` and `()`.  Those were just hints to help the parser find the boundaries of the commands.

Output (The AST):

```
[
  AssignmentNode(Variable: "result", Value: 42),
  SyscallNode(ID: 1, Argument: "result")
]
```

### Step 3: Compiler

The compiler now has instructions that have meaning (one of our 9 language constructs).

It simply needs to tranlate this into something the stack machine can do (the codes we described above).

```
[
  # Line 1: `result := 42;`
  #    AST: AssignmentNode(Variable: "result", Value: 42)

  [:PUSH, 42]  # Put the number 42 on top of the stack.
  [:STORE, 0]  # Take the top stack value and move it into Memory Cubby #0.

  # Line 2: `SYSCALL(1, result);`
  #    AST: SyscallNode(ID: 1, Argument: "result")

  [:LOAD, 0]      # Load the value in Memory Cubby #0, put it on the top of the stack.
  [:SYSCALL, 1]   # Take that value and hand it to the Operating System to print (SYSCALL #1).
]
```

### Step 4: VM

The translation so far may have been hard to follow, but the VM is likely to be the hardest to follow.

So we will break it down the most thuroughly here.

Our program translated into these 4 bytecode instructions:
```
[
  [:PUSH, 42]    # Put the number 42 on top of the stack.
  [:STORE, 0]    # Take the top stack value and move it into Memory Cubby #0.

  [:LOAD, 0]      # Load the value in Memory Cubby #0, put it on the top of the stack.
  [:SYSCALL, 1]   # Take that value and hand it to the Operating System to print (SYSCALL #1).
]
```

#### Instruction 1

When the VM starts, it's current stack and memory look like:

```
stack = []
memory = []
```

When the VM is told to execute intstruction #1: `[:PUSH, 42]`

It pushes 42 onto the top of the stack:

```
stack = [42]
```

#### Instruction 2

When the VM is told to execute instruction #2: `[:STORE, 0]`

It TAKES the value of the top (removes it), and puts it in memory slot #0.

```
stack = []
memory = [42]
```

#### Instruction 3

Now we need to do the entire opposite, Instruction #3: `[:LOAD, 0]`

The VM will KEEP 42 in memory (important), and put it back on top of the stack (so that the next step can print it).

```
stack = [42]
memory = [42]
```

#### Instruction 4

When the VM runs the instruction #4: `[:SYSCALL, 1]`

It will TAKE the value off the top of the stack (42) and SEND it to SYSCALL #1 (PRINT):

```
stack = []
memory = [42]
```

Your computer screen:

```
> 42
```

Pat yourself on the back.  You just built a working VM!
