# CLEAR Vision

CLEAR strongly believes that Rust is not hard.  It's error messages are.

Rust's error messages are hard because most developer journies look like:

 1. Experiment with the language
 2. Learn as you encounter errors

The problem with Rust, like C++, is that errors only make sense if you already have the vocabulary to understand them.

Essentially, many common Rust errors are only helpful if you already know how to solve them.

This can be solved by reading an ~800 page manual.  But most developers don't learn that way.

Many developers simply need to work on a codebase, and do not want to read an ~800 page manual to make a few changes.

## How does CLEAR aim to make a Rust-like language more accessible

Because Affine Ownership in CLEAR uses keywords, rather than symbols, the affine error messages are more intuitive:

```ruby clear illustrative
FN foo(TAKES x: User) -> ... END

myUser = getUser();
foo(myUser);
print(myUser.name);  
# Error: You can't use `myUser`.  
# `foo` already TOOK it away.  
# You can either GIVE foo a COPY of `myUser`, or make `myUser` multi-owned so `foo` you can `KEEP` it while foo `TAKES` it.    
# Option: `foo(COPY u, a)`
# Option: `u = getUser()@multiOwned`;
```

## CLEAR supports *MODES* of compilation

In `EASY` mode, CLEAR allows aggressive type inference to allow you to write code that looks like scripting:

```ruby clear illustrative
FN foo(x) -> ... END

myUser = getUser();
foo(myUser);
print(myUser.name);
```

Under the hood, this creates:

```ruby clear illustrative
FN foo(x: Auto) -> ... END
```

`Auto` allows type inference for functions.  It will "just work" until it doesn't.  And the error is typically easy to fix:

```ruby clear illustrative
FN foo(x) -> ... END

myUser = getUser();
myAccount = getAccount();
foo(myUser);
foo(myAccount);
# Error: type cannot be inferred for param `x` of function `foo`.
# You are passing both `Account` and `User`.
# This is typically bad design.
# If desired, you must strongly type param `x of `foo`.
# `foo(x: User | Account)`.
```

### What EASY mode does *NOT* allow

`EASY` mode will not allow you to skirt some of Affine Ownership's largest problems.

If it did so, you could create a codebase in EASY mode, and then upgrading to efficient code for `DEFAULT` or `STRICT` mode *could* be very difficult.

#### TAKING ownership

```ruby clear illustrative
FN foo(x, a) -> 
  a[0] = x;
END
# Compiler error: `a[0] = x` TAKES ownership of `x`.
# You must either `COPY x` or change `foo()` to `TAKE` ownership of x.
# Option: `a[0] = COPY x;`
# Option: `foo(TAKES x, a)`
```

```ruby clear illustrative
FN foo(TAKES x, a) -> 
  a[0] = x;
END

u = getUser();
a = makeUserArray();
foo(u, a);
print(u.name); 
# Error: You can't use `u`.  
# `foo` already TOOK it away.  
# You can either GIVE foo a COPY of `u`, or make `u` multi-owned so `foo` you can `KEEP` it while foo `TAKES` it.  
# Option: `foo(COPY u, a)`
# Option: `u = getUser()@multiOWned`;
```

#### Concurrency

```ruby clear illustrative
# Existing library
FN foo(u: SHARED User) -> ... END

myUser = getUser();
foo(myUser);
# Error: `foo` expects `myUser` to be a @shared object.
# Option: `myUser = getUser()@shared;`
# Option: `foo(SHARE myUser);`
```

```ruby clear illustrative
myUser = getUser();
BG { print(myUser.name); }

print(myUser.name);
# Error: BG { ... } is not guaranteed to complete before `print(myUser.name)`
# BG { ... } TOOK ownership of `myUser`.
# Option: use `DO { ... }` so that it guarantees completion.
# Option: use `NEXT BG { ... }` so that it guarantees completion.
# Option: LEND a BORROW of `myUser` to `BG { ... }` so that you can KEEP `myUser`.
#         WITH BORROWED myUser AS u { BG { print(u.name) } }
```

## VM Debugging

CLEAR has a VM for development to make debugging as easy as a scripting language compared to GDB/LLDB.

  1. To be able to run a REPL / VM, to live-debug like you can in Ruby, to write working code *faster* than you can even in scripting languages.
     - CLEAR *aims* to achieve a level of fearless concurrency above Rust, Pony, or Elixir.
     - Rust and actor models guarantee memory safety.  But you can still have higher-level logic races / non-deterministic state transitions that are very painful to debug.
     - CLEAR **aspires** to make this as easy as debugging sequential code in a scripting language with a world-class debugger by providing deterministic replay of concurrent events (in the VM).
        - CLEAR **aspires** to completely prevent as many bugs as feasible without making the language overly difficult to understand.  For the category of bugs that could possibly be prevented (some ADA-level safety issues), but can be compiled in CLEAR - the goal is to auto-generate tests to catch *most* of them, and make them easier to debug than in any known language. This is obviously a step down from preventing them entirely, but it comes with the language being much more accessible and understandable.
     - In other languages, Stateless Model Checking is a separate, difficult tool you have to opt into. In CLEAR, it's just how `./clear test` *will* work.
  3. For `./clear doctor` to be able to walk you ~95% of the way from that to HFT-Standards of C speed, and ADA-level safety.
  4. For code, even at the highest-level of optimization, to be easily understandable.
  5. A Control Plane so reliable that even if your most heavily optimized application experiences wildly unpredictable and adversarial workloads, it can glide through it gracefully.
  6. To be able to distribute loads across multiple machines effortlessly like BEAM, but with native speeds.