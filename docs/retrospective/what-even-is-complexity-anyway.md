# What even is complexity anyway?

In the 80s, the costs of software started ballooning. People became obsessed with the idea that software could and should write itself.

ML techniques are not new. Neural Networks had existed since the 60s, and in the 80s - like LLMs today - there was a craze to apply those techniques to "fix" all of the problems in software, namely to get it to write itself and/or correct itself.

In [No Silver Bullet](https://www.cs.unc.edu/techreports/86-020.pdf), the proposal is simple: well written software is almost as simple as it can possibly be. There is little hope for a language to save us such that it can be 10x or more expressive than today's leading languages.

The operative phrase from No Silver Bullet is “well written software”.  Most software is far from well written.

In the 80s, as now, people tried to figure out: is there even a way to programmatically define what is well written and ideal? This is thought to be an undecidable problem. If this was possible, you could programmatically rewrite all architecturally bad software to its ideal form. The fact that you've not seen this is evidence the problem remains unsolved.

In [Out of the Tar Pit](https://curtclifton.net/papers/MoseleyMarks06a.pdf), the author spends much time discussing the difference between Essential and Accidental Complexity.

But I don't think the average person really understands complexity. In this essay, complexity is not Complexity Theory in computer science.  Like in Out of the tar Pit, it is the complexity that makes software hard to understand and maintain, essentially.

At its core, this complexity stems almost entirely from **state** and **control flow**. More specifically, it is unnecessary, implicit, shared, mutable, duplicated, or poorly bounded state/control flow.  And most of that stems from **bad design**.

State and control flow are sort of easy to understand at a high level, but it can be a challenge to pin down exactly what the problem is, where, and why.  Good design typically focuses on minimizing state and implicit control flow. So if you do not understand them fully, it is hard to design good software.

It is easy to feel the pain of bad software, who among us engineers can say they have not?  But it is hard to fix or avoid this pain if you don't understand the cause.

## What is state?

State is data that persists across time. It is the memory of your application.

As Rich Hickey says, the problem is: few languages make data carry a flag that says: “I’M STATE!  WATCH OUT!”

It is easier to understand state, by looking at what is NOT state. Pure functions have no state.

They take inputs and produce outputs:

```ruby clear illustrative
FN add(x, y) -> RETURN x + y;
```

State is often created, read, or mutated through the *side effects* of an impure function:

```ruby clear illustrative
GLOBAL = 0
FN badAdd(x, y)
  res = 0
  IF GLOBAL == 0 THEN  # This is a state-based decision, control flow
    res = x + y + GLOBAL;
    GLOBAL += 1  # GLOBAL is state
  END
  RETURN res
END
```

You can have control-flow without state (which is ideal):

```ruby clear illustrative
FN sometimesAdd(a, x, y)
  res = 0
  IF a == 0 THEN  # This is stateless control flow
    res = x + y;
  END
  RETURN res
END
```

And you can have state without control flow:

```ruby clear illustrative
ADD_COUNT = 0
FN trackedAdd(x, y)
  ADD_COUNT += 1;
  RETURN x + y;
END
```

## That doesn’t seem so bad.  What’s the big problem?

Take a very typical object oriented lifecycle, for a `BillingService`:

```ruby clear illustrative
CLASS BillingService
  FN setCart() ... END
  FN setUser() ... END
  FN validateUser() ... END
  FN applyDiscount() ... END
  FN processPayment() ... END
END
```

All of these functions individually are fine. They  mutate some state on the `BillingService`.

The problem is that this class has an *implicit* Control Flow.  You are supposed to do something like:

```
setUser() -> setCart() -> validateUser() -> applyDiscount() -> processPayment()
```

But there are infinite combinations in which these 5 functions that could be applied.  Will the code work if you try?

```
setUser() -> applyDiscount() -> validateUser() -> setCart() -> processPayment()
```

What this class has technically done is created a state machine with `2^N` states and `M!` Control Flows.  You only need to add a handful more decision points on state & class methods that use them before this class is completely incomprehensible for the human mind.

 * **Essential Complexity:** The actual business logic (e.g., "A user must pay for the items in their cart").
   * You cannot code your way out of this.
 * **Accidental Complexity:** The mess we introduce by our choice of tooling or poor architecture (e.g., the state bugs in `BillingService`).
   * This is entirely preventable.

## What’s a State Machine Anyway?

A state machine is not an academic abstraction. It is rarely a complex design pattern that you *actually* implement.

A lot of engineers learn about state machines in college, promptly forget about them, and might think, since they’ve never seen a state machine class, and never created one, they don’t ever have "state machines".

Wrong.

A state machine is a fundamental mathematical reality. It consists of three things:

 * **States:** A finite set of conditions the system can be in (e.g., `EmptyCart`, `ValidatedUser`, `Paid`).
 * **Inputs/Events:** Actions that trigger a change (e.g., `setCart()`, `processPayment()`).
 * **Transitions:** Rules that explicitly say, "If I am in State A, and Event X happens, I move to State B. If Event Y happens, throw an error."

State itself is particularly tricky.  Most of the state an application creates is *implicit* / invisible.  As are nearly all of the "state machines".

State can be stored directly on an object, like: `isValid`

But state is often created on the fly: 

```ruby clear illustrative
IF user.name != "" THEN ... END
```

The above is control flow.  You used a value to make a decision (whether the `user.name` is not empty).  This is an "**unnamed state**".  You don’t need a variable: `stateUserIsNamed` to have state.  You just need to make a **decision** on a value that **changes over time**.

Any value that can change over time is state. But a value that changes over time *AND* affects control flow, is typically the most problematic.

Let's examine an outlier state that *DOESN'T* affect control flow, but could still be problematic:

```ruby clear illustrative
CLASS Player
  Int64 health;
  Int64 healingPower;
  FN heal() -> health += healingPower; END
  FN powerUp() -> healingPower = healingPower * 2;
END
```

`health` and `healingPower` both change over time.  `healingPower` has direct effects on health, but it doesn't impact control flow.

In computer jargon, this is called **temporal coupling** and **cascading state mutations**.

If you call:

```
heal() -> powerUp()
```

The effects are different than:

```
powerUp() -> heal()
```

Only one of these may be correct.  But how do we know which one?  A lot of times you don't, until someone does something in the wrong order.

The problem with these types of bugs is that as applications grow in complexity exponentially, it becomes easier for these bugs to go undetected.

## We’ve all seen bad code before:

```ruby clear illustrative
# A function that adds two numbers
FN add(x, y)
  RETURN x + y
END

# A class that does the same...
CLASS OverEngineeredCalculator
  DATA globalStatus = "IDLE"
  DATA lastOpWasAdd = FALSE
  DATA trackingId = 0

  FN calculate(x, y, opType)
    THIS.trackingId += 1
    LOCAL finalResult = 0
    
    IF opType == "ADDITION" THEN
      THIS.globalStatus = "PROCESSING"
      LOCAL temporalFactor = 0
      
      IF THIS.trackingId > 0 THEN
        temporalFactor = x + y
        THIS.lastOpWasAdd = TRUE
      ELSE
        temporalFactor = 0
      END
      
      IF THIS.globalStatus == "PROCESSING" THEN
        finalResult = temporalFactor
      END
      
      THIS.globalStatus = "IDLE"
    ELSE
      finalResult = -1
    END
    
    RETURN finalResult
  END
END
```

## What are all problems with complex code:

 * It is hard (sometimes impossible) to know the full extent of a change you need to make.
 * You can break something where it is literally not possible at compile time to know you broke it (or that the thing even existed to break in the first place).

How are you supposed to write working code when this is possible?  And why is there so much code like this in the first place?

## The Entropy Problem

In physics, entropy is the measure of disorder or randomness in a closed system. Left alone, things fall apart. Buildings crumble, hot coffee goes cold, and neat rooms become messy.

Software behaves exactly the same way. Every time you make a quick commit, add an IF statement to bypass an existing constraint, or introduce a new instance variable to fix a localized bug, you are increasing the entropy of the system.

You start with a pristine, perfectly ordered vision:

```
# Day 1: Order (Zero Entropy)
setUser() -> setCart() -> validateUser() -> processPayment()
```

But requirements change...

A feature request demands a discount step, but only for certain users on Tuesdays. A bug fix requires a temporary tracking ID. Suddenly, without anyone maliciously trying to write bad code, without any particular commit looking terrible, your system slides into maximum entropy:

```
# Day 300: Chaos (High Entropy)
setUser() -> applyDiscount() -> validateUser() -> ??? -> processPayment() 
# With 4 parallel background threads mutating the state simultaneously
```

There may be 99 functions you have to call in the exact right order, and if you take one down, pass it around, call any in the wrong order, you're dead!

This is why complexity is the default state of all software. Writing clean code isn't a passive state you achieve once and leave alone; it is an active, ongoing expenditure of energy.

Who created the mortal sin of making this "bad"?  Which commit broke the camel's back and made this `BillingService` completely unusable? As with state, the problem is, commits rarely come with a message that says: "WATCH OUT! THIS IS TERRIBLE DESIGN!". When you get the diff to review, you don't even have all the information available, typically, to make an informed decision. When do you decide that someone needs to make a ~1000 line refactor to finally clean up the mess anyway?

To fight complexity, we have to fight entropy. We do this not by hoping for a Silver Bullet - that an LLM will magically sort out our mess. We do this by ruthlessly minimizing global state, enforcing explicit control flows, and keeping our execution paths so visible that complexity has nowhere to hide.

## Can a language save you?

No.

In any Turing Complete language, you can write a piece of software in infinite ways.  The vast majority of those ways are absolutely terrible.

Take the stateful player example - it translates perfectly to Lisp (or OCaml or any language):

```lisp
(defvar *initial-billing-state* #(nil nil nil nil nil))
(defun set-cart ... )
(defun set-user ... )
(defun validate-user ... )
(defun apply-discount ... )
(defun process-payment ... )
```

It's the same problem, slightly less bad, different language.

Look at our `OverEngineeredCalculator` - there are infinite ways to add more unnecessary complexity to that function to still just add two numbers.  There are infinite feature requests that you could add to it:

 * PM: I want that calculator to alert me if anyone adds 42 and 42 together.
 * PM: I want to know how often people try to divide by 0.
 * PM: It’s too slow when people try to add 1, add a fast path.

All of that is business logic: **Essential Complexity**.  Those things *may* need to exist.  But a suitably bad engineer could add infinite complexity as well:

 * Bad engineer: instead of adding together positive and negative numbers, first I should see if it’s negative, then get the absolute value, then subtract it.

The harder and more complicated a language is, and the more difficult it is to recover from bad design choices, the more you need to reach outside the box, and the more you get trapped into a bad box once you go in there.

The cost of a bad function is minimal.  The cost of a bad architecture / design (in most existing languagues) is enormous.

A bad function can be rewritten cheaply.

An engineer may decide to open a subprocess, call grep, parse the results, mutate a string.  You can replace that with a call to `gsub`.

A bad design can *rarely* be fixed so easily.

A bad engineer designs a class with tons of unnecessary state and implicit control flow.  Another engineer builds a class to interact with it, and bleeds its toxic implementation details throughout the codebase.

One of the biggest problems with software is that it tends to be incrementally developed, almost exactly in this fashion.  So much software was built with minimal design.  It just incrementally came into existence, building on past versions of itself, with no awareness to where exactly it was headed.

This is the entropy problem.

## So what are you to do?

As software grows, you should attempt to measure its complexity.

 * How much state is being added (values that change over time)?
 * How sloppy are state reads and writes (are you reading from state far away from where it’s written, are you writing to it far from where it’s owned)?
 * How many independent modules have write-access to the same state lifecycle (is your data tightly contained, or do you have an implicit global bucket)?
 * Are you making decisions repeatedly that should be eliminated entirely by the type system?
 * Are you making slight variations of decisions that are likely latent bugs?
 * Are you making state based decisions under assumptions not guaranteed to be true?
 * What is your branch coverage?

A sure-fire sign that you’re heading in the wrong direction is:

 * How many bug fix commits do you have vs feature commits?
 * Are your bug fix commits frequently touching several modules / systems / classes?
 * Is your complexity growing exponentially while your features are growing linearly?

These are things you can and should measure as well.

Most software is moving in the wrong direction, and we know it.  But people rarely quantify it.

## I know what the problem is.  How do I fix it?

Bjarne Stroustrup has a cute quote about writing working C code.

When asked: How do you handle memory leaks in C?

Bjarne says: Why, by not writing them in the first place...

The problem with prescribing design patterns is... Writing good software *DOES NOT* scale. Bad software is everywhere.

Anyone who tries to fool you that Google and Facebook and Alibaba are filled with beautiful, perfectly working software has never peaked under the hood.

Sure, the quality is higher than average, but messes abound even at the most elite software institutions.

The solution at scale is not: write good code.

The solution is: build tooling to identify what is bad, where it is, and when you should invest in fixing it.

*YOU*, individually, may be able to come up with a good design, follow it truthfully, and write a good implementation.  At an institutional level, that does not scale.  It is irrelevant.

 * Languages or frameworks can help, but they cannot save you.
 * Hiring can help, but it also cannot save you.

What can save you is, shockingly, what Bjarne suggested: don’t get yourself into the mess in the first place.

The best defense is a good offense.  The best thing that can save you is to stay *AHEAD* of the mess, not behind it.  So measure it and stay ahead of it.

Why is staying ahead of it so important?  Because software complexity tends to grow exponentially.  It doesn’t take too long of falling behind before you’re completely under water.

## I know that, stupid.  I’m behind it.  Now what?

The problem with refactoring a pile of crap is... Any time you change a pile of crap, it’s far easier to make it crappier than to make it better.

That’s the reason it’s crappy in the first place...

If writing good code was easy, there probably wouldn’t be so many software jobs, and we probably wouldn’t make good money...

This is why - when faced with a pile of crap - a lot of senior engineers, rightly, will throw up their hands and shrug and say: C’est la Vie. It’s the way it is. No use fighting it. Learn to live with the crap.

But metrics *can* help:

 * If you’re going to make a change to make things better, you have acceptance criteria - not opinions and vibes.
 * If you measure complexity, you cannot do a “refactor” that makes the code worse - that's "enshittification".

Metrics can help you prioritize the most complicated parts of the codebase and your efforts to resolve them - see the end for details.

If your codebase is a steaming pile of crap, the solution is not making leaf functions prettier.

### One thing that is critical:

The solution to your problem is *DEFINITELY NOT* moving to Rust or OCaml or Clojure.

If your team wrote a pile of crap in Python, they can just as easily write a pile of crap in Rust.

The solution is an intelligent, prioritized triage - based on measures of complexity.

### Step 1: Identify the "Hotspots" (The Churn vs. Complexity Matrix)

Do not waste time refactoring a highly complex class if it hasn't been modified in three years and causes zero production issues. Leave it alone. It is a stable tumor.

Instead, cross-reference your commit history with your complexity metrics. Look for files that have **high state-based branch counts**, **high state read/write counts (state & control flow)**, and **high commit churn**. This intersection is *almost* always the nexus of your bad design. Target it.

Do not blindly use cyclomatic complexity. Cyclomatic complexity is easily cheated by *MOVING* complexity around, which does nothing. If you break half of a bad function up, turn it into two, you've arguably made something worse, not better.  If you take half of a bad class, and make it two bad classes, that's usually worse...

Cyclomatic complexity *without* a bunch of state-based control flow is typically harmless. Fixing it is *typically* a low ROI beauty contest.

### Step 2: Quarantine the Macro-State Boundaries

If your codebase is a steaming pile of crap, the solution is definitely not spending two weeks making local leaf functions look prettier. That is a micro-fix for a macro-disaster.

Find the places where state leaks across boundaries: where three different modules are reaching inside a global object to mutate values. Do not rewrite the modules. Instead, figure out the API that is missing that those readers & writers *should* be using, and implement it.

You aren't fixing the bad design yet: you are containing the blast radius of it...

Trying to completely fix it all at once is a re-write which will more-often than not turn out poorly. Either it takes  much longer than anticipated, has integration failures, or the new solution is bad in different ways, rather than the solution you *actually* needed...

### Step 3: Enforce a "Complexity Tax" on New Pull Requests

You cannot clean a house while people are tracking mud through the front door. If your metrics show that complexity is growing exponentially while features grow linearly, you must change the rules of entry.

Introduce a static analysis step into your CI pipeline.  New pull requests should have minimal increases to your complexity ratings, and ideally should come with cleanups that *reduce* complexity while adding new features.  You don't have to force developers to write "good code" overnight.  You can just have them chip away at the worse offenders.

If you don't have the testing in place for this to be possible, you need to start chipping away at that *first*. Otherwise, your mess will grow exponentially, and progress will crawl to a freeze.

If you’re swimming in a pile of exponentially growing shit, the solution isn’t to swim faster, it’s to clean the water.

## What does that look like?

Let’s return to the `BillingService` and see this in action:

```ruby clear illustrative
CLASS BillingService
  FN setCart() ... END
  FN setUser() ... END
  FN validateUser() ... END
  FN applyDiscount() ... END
  FN processPayment() ... END
END
```

As it currently exists, it has an *implicit* control flow, that you need to call all of these functions in the correct order (or one of many possible correct orders) for a payment to succeed.

As none of the instance variables have a giant sign that says: “I’M STATE! WATCH OUT!”  Also none of the methods have a sign that says: “I CAUSE CONTROL FLOW! WATCH OUT!”

The solution to this problem is likely that the `BillingService` should only expose one public function: `processPayment()`, and you feed it all the data that it needs.

In the process, you eliminate the state: storing the user and the cart and the discount.

## A Simple Way to Think About the Reality of Complexity:

You’re not building a Rust compiler easily whether you build it in F# or JavaScript or Rust.

Building a Rust compiler is hard.

Choosing the right tools obviously helps, but most “bad” software is bad because the business logic demands it to be!

It’s not hard to make a Rust compiler because all the languages and tools suck.  It’s hard because Rust itself is complicated!

If I had to make a guess how much complexity is typically Essential (building the compiler) vs Incidental (the implementation / design) - I would guess the averages look something like:

 * 50% Essential
 * 50% Accidental

Some language / framework designers want you to think that if C or Assembly would be 100% accidental complexity, by using their language or framework, you’ll get 0% accidental complexity.

And wouldn’t that be great?  Your software would be half as complicated.  The reality is that of the Accidental Complexity, it depends on language, but it *probably* looks something like:

 * 60-70% design
 * 40-30% language / framework

Clojure does its best to minimize surface area for the language to give you headaches.  It can help you sleep at night knowing that you won't have some classes of bugs, and that you'd have had to go out of your way to encounter others.  That *IS* very valuable.  But a lot of others provide similar benefits:

 * Go is probably somewhere in the middle
 * Rust is probably somewhere near the ideal
 * C is probably somewhere near the un-ideal

But, the reality is, the harder the language is, typically the engineers are better at it - survivorship bias, etc.  You’re not going to make it very far as a C engineer if you throw up your hands and slam your head into a brick wall every time you segfault...

Yes, C makes your life harder. I’d argue it definitely makes your life more *frustrating*. It may slow you down more than Clojure or OCaml would.  But, typically, C engineers “figure it out enough” that the end result of what complexity looks like, tends to be the same:

 * Most of it stems from a design that entropy bastardized and broke.
 * Less of it stems from "C being bad" and "the libraries and frameworks sucking".

Outliers obviously exist.

At scale, the problem *tends* to be design that *causes* bugs, not people who can't code individual functions.  *Occassionally* you inherit those designs through mainstream frameworks in a language, but that's the exception, not the norm.

## In Closing

In No Silver Bullet, I don’t feel the author did a good enough job making it concrete exactly why there is No Silver Bullet, and why there is unlikely ever to be one.

If you are starting a new project, I recommend trying to find the right balance of a language that makes your life as easy as possible, and one that others can build on and understand, and that has access to the tooling and libraries you need so that you *DON'T* need to re-invent wheels poorly.

But if a Silver Bullet exists to make building a Rust compiler easy, no one has found it yet.

Rather than searching for a Silver Bullet, you should search for the right combination of what maximizes velocity, reduces room for error (especially severity), is performant / cost effective, and - if applicable - easy to hire for. 

Rich Hickey makes a great joke about functional programming languages:

> Parenthesis are hard, yes... haha... I mean, I’ve seen them before.  But I’ve never seen them ON THAT SIDE of the function!!  My God!

Functional programming isn't so scary, and it *might* provide a lot of value for you.  But functional programming nor Rust will allow you to write a working version of the Rust compiler in a weekend.  Neither will using an LLM.  There is no Silver Bullet.

If you really want to increase your velocity, do yourself a favor.  Measure complexity and stay ahead of it.  You may quickly find your designs are worse than you thought they were, and fix them *BEFORE* they become problems.  Do this *regardless* of what language you choose - *especially* if you're using LLMs.

> [!NOTE]
> [gems/nil-kill](/gems/nil-kill/README.md), [gems/decomplex](/gems/decomplex/README.md), [gems/slopcop](/gems/slopcop/README.md), [gems/boobytrap](/gems/boobytrap/README.md), and [gems/espalier](/gems/espalier/README.md) do all of this for CLEAR.

> [!NOTE]
> This is why [CLEAR](/README.md) is designed to be 1) understandable, 2) opinionated, 3) full-featured, 4) maximally optional (allow you to change bad design easily), and 5) has built-in tooling as a first-class citizen to detect these problems. You do get the "WATCH OUT" signs!  But you *don't* get a silver bullet...
