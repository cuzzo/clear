# How to Vibe Code something that *actually* works

LLMs are outstanding at writing code that *sort of* works, and finding *some* bugs.

The problem is: production systems need to **actually** work, and bugs need to be fixed **correctly**, otherwise it's turtles-all-the-way-down with bugs.

If you rely on LLMs to blindly fix bugs in a system that is not *extremely* well tested, they’ll likely “fix” one bug, and silently introduce 3 others.

## Some things you can count on:

 1. If you ask an LLM to build you something non trivial, at best, it will be *sort of* architecturally correct.
 2. Everything fails from here. It is very hard to arrive at something that *actually* works when you have the fundamentally wrong design.
 3. LLMs simply do not have the contextual capability yet to analyze medium+ sized codebases and figure out:
    * Is this actually broken?
    * If so, how do I fix it?
    * And what is the realistic path to *actually* fixing it without just re-inventing another system with all of the same problems (or worse)!

## What DOES NOT work:

 1. **Test coverage** alone is *almost* meaningless in a vibe code project.
    * LLMs regularly test that code successfully does not work:
      - This feature is intended not to work at this stage (even when you told them specifically TO fix it at that stage)
      - Testing obviously wrong behavior: `1 + 1 = 3` (successfully)
      - Tests that test *nothing* - these hit lines, but don’t actually test that anything works - LLMs are famous for this type of test when you blindly tell them to increase coverage
 2. **Branch coverage** alone fails for similar reasons.
    * A line covered means nothing, but critically a branch taken does not imply all possible paths to that branch were taken
    * All possible paths in a non-trivial program is typically an undecidable halting problem: it is essentially infinite
      - This is exactly why writing non-trivial *working* code is hard!
 3. **Cyclomatic complexity scores**
    * Some functions are inherently complex.
    * Breaking them up for the sake of satisfying cyclomatic complexity often makes your code worse, not better.

### Goodhart's Law:

> "When a measure becomes a target, it ceases to be a good measure."

 * LLMs are *VERY* good at gaming metrics.
 * If you want code that actually works, you don’t arrive at it by gaming metrics.
    - You arrive at it by using your brain, something LLMs don’t have.
 * LLMs are a tool that can *HELP* you make sound decisions, and can *sometimes* make sound decisions.
 * But just like you cannot trust yourself, you can also not trust LLMs.

## What DOES help:

### Mutation Tests

 * A good test is load bearing. When production code changes, it should break it.
 * LLMs write tests that test nothing.
 * Mutation tests help you find them and turn them into load bearing tests that actually have value.
   * LLMs can often fix this, and the diff should be small and easy to review.

### Coupling and Cohesion

 * This measures how many other classes/modules rely on a piece of code (Afferent) and how many things that code relies on (Efferent).
 * LLMs default to writing spaghetti code. This *helps* you find it. 
   * **Fixing it correctly will require using your brain.**
   * The diff will typically not be small, and require a lot of review - though you can use LLM convergence to help.

### Code Duplication (DRYness)

 * You want your production code to be DRY, your test code to repeat itself.
 * LLMs are famous for repeating themselves incorrectly.
   * LLMs can often fix this.
   * **Though telling them to do it blindly can cause bugs rather than reduce them.**
   * Use your brain!

The key is: these *help*. But they does not *guarantee* you’ll get working code, or even close.  

 * It helps you find the most common LLM problems.
 * It does not help fix them correctly, and relying on LLMs to figure out how to do that on their own is a fool's errand.
 * **YOU**, the human, are the **driver**.
 * LLMs are the **car** helping you arrive where you want to go faster than you could without them.
    * If you ask the car to drive you somewhere, it might drive you off a cliff.

## The Key to Success - Signal Diversity

LLMs are *sort of* good at everything. 

You can make them far better if you build a self-correcting fortress to: 1) reject their failures, and 2) accept their wins.

### How do you do that?

A system that has worked for me seems related to how hedge funds like Bridgewater think about investments:

> Ray Dalio advises that, rather than focusing on a specific number of individual stocks, true diversification requires 15 or more good, uncorrelated return streams to significantly lower risk.

If you vibe code, and you want code that works, do it in a way that you have several streams **independently** verifying that your code is implemented correctly.

You do not need to solve the halting problem to vibe code with LLMs and get *reasonable* results. All you need is diversity:

 1. Your design docs
    * Have LLMs spec out a design for you. Compress it to something actionable for them to look back on.
    * They can use this as a first layer of defense to check if what was done actually works.
 2. Your actual code
    * LLMs are decent at finding some bugs.
    * They can look directly at code and get a signal if it actually works.
 3. Your unit tests
    * Advise LLMs to independently write tests without looking at implementation, only function signatures and the compressed design doc.
    * They can look at the test code independent of the actual code to see if it’s a 1) test nothing test, 2) a test this successfully fails test, or 3) what you want - a test that actually tests it works correctly according to your spec / design.
 4. Your integration tests
    * Advise LLMs to independently write feature/integration tests without looking at implementation, and to avoid unnecessary mocks at all costs.
    * LLMs can easily write do-nothing integration tests that mock literally everything and test nothing.
    * Just as with unit tests, this is yet another layer for them to independently look at as a signal for if the code is adequately tested
 5. Fuzz Tests
    * Integration tests mainly test happy paths.
    * Without fuzzing / formal verification, it is difficult to explore all the necessary paths to ensure your code actually works.
    * Integration tests are a minimal first line of defense.
    * The reason fuzz testing is great to combine with integration testing, implemented separately - is diversity.
    * You will find several bugs here - often times the first bugs will be that the LLM wrote the fuzz testing incorrectly. But almost always they will find the gaps in you unit tests and integration tests.
 6. Mutant Tests
    * Fuzz tests are valuable on their own, but mutant testing is how you know they are load bearing.
    * When combined with Fuzz testing, written independently, looking only at your docs, you are unlikely to arrive at a situation where 5 layers of code and testing **all** test that your code either 1) does nothing or 2) fails successfully.
    * Though LLMs can do it!
 7. Tooling
    * You need reports that show all the common pitfalls LLMs have:
       a. **Code Duplication - especially PARTIAL:** where they checked some invariant in slightly different ways - more times than not a bug when working with LLMs - have them review each case.
       b. **Branch coverage - especially DECISION based:** where you have untested branches specifically on key decision points - the pillars of your system / product.
       c. **Afferent and Efferent Reporting:** to give you insights into where LLMs inevitably turned your code into spaghetti.
 8. **Review!!!**
    * Even with 6 layers of protection and tooling & reporting on code health specifically for LLM pitfalls, you need to review their work after they’ve screamed done and written all the tests.
    * Have 2-3 LLMs review on 1) architecture, 2) bugs, 3) gaps, 4) tech debt. Have them converge on which of the feedbacks are actually worth doing, and which are hallucinations or moving in the wrong direction.
       a. Save this plan to docs/agents/*.md design doc.
    * Have one LLM implement the plan until the 2-3 others converge on the plan being done correctly.
    * At a *BARE* minimum, get the LLMs to converge on how *YOU* can be convinced the code actually works. Check that it works! Even at this stage, you should not be surprised if it is completely broken…
    * At a *REASONABLE* minimum, review the final integration testing to make sure it’s not mocking everything important.

### What is Convergence?

 * If one LLM tells you something, there's some unknown probability that it's wrong.
 * If 2-3 tell you the same thing, it certainly does not mean it's right, but it does mean it's more likely to be right.
 * If they all agree and something *and* it makes sense to you, that's *probably* the best you're going to do on your own.
 * Never take **DESIGN** from LLMs blindly - i.e. just one.
    * This is letting the car pick where to drive.
 * If you personally don't know where to go, have the LLMs first agree, and then **use your brain** to make sure it makes sense.
 * Then, and only then, should you proceed.

Here is my [Review Process](what-I-learned-the-hard-way.md), complete with the magic words I use at different stages of development that have led to far better outcomes.
