# What I learned (the hard way) Building a Memory Safe Programming Language with LLMs over the last 6 months

## Background
I wanted a language like Rust, but substantially safer and more intuitive.

I thought outsourcing this to LLMs was reasonable. The goal was primarily to understand their capabilities and limitations. My initial expectations were low.

Verifying compiler correctness is notoriously difficult. While harder problems exist, compilers are challenging. Controlling the language limits the problem space, yet for the goals I had - the problem space would be inherently difficult to verify correctness. Even though LLMs are particularly weak here, they have completely blown away my expectations. I have been both humbled and endlessly frustrated by their powers and limitations.

The language is [CLEAR](https://github.com/cuzzo/clear), and these are my learnings from this six-month adventure.

## Where LLMs excel
* Generating ideas and signals
* Filtering and reducing noise
* Identifying problems
* Applying optimizations (with strict guardrails)

## Where LLMs are decent, but not as good as I expected
* Refactoring—especially re-architecting

## Where LLMs do not excel
* Getting things correct
* Obeying design principles
* Resolving merge conflicts

Finding a hole in a ship is easier than building one that never leaks.

Extracting high value from LLMs requires strict discipline. They make it easy to cut corners, even unintentionally.

When you lack ideas, LLMs can flood you with them. Usually, you can weed out the bad ones.

When flooded with data, LLMs sort it reasonably well, though they will make mistakes.

You can solve many problems by having LLMs generate scripts to produce and sift through data.
* I’m planning to release a tool that allows LLMs to loop until they fully type a Ruby codebase.
  - They did this for a ~40k line transpiler in a day after tooling was built.
  - The tooling took another 1-2 days to develop.
  - You can see it in [nil-kill](https://github.com/cuzzo/clear/blob/master/tools/nil-kill.rb); I’ll release this as a standalone Gem shortly.
* I could never find the signal in that data without spending significant time on tooling.
  - Without LLMs, I wouldn’t have spent the time to build that tooling by hand.
* LLMs will miss things, but they can find a shocking amount of signal in data that is easy to generate but impossible for me to derive value from manually.

LLMs struggle when absolute correctness is required, as in language development. They are good at getting *close* quickly, but bad at being *actually* correct independently.

The goal of any tool is to maximize value without introducing negatives.

A hammer is great for hitting nails but terrible for knitting sweaters.

## Where to use LLMs aggressively

**LLMs can prototype things unbelievably fast.** In many cases, a "mostly correct" prototype is valuable. However, think twice before prototyping even with an LLM:
* If speed AND correctness are required, there may be significant performance implications.
* A prototype’s simplicity often comes from its incompleteness or incorrectness.

**Second opinions generally**: Two heads are better than one. LLM commit reviews may be noisy, but the signal is often worth it.

**Second opinions specifically for reasons to reject something**: Signal on a critical bug is worth the noise. I have had success having LLMs hunt for bugs. If 1 in 10 is a signal, that’s a win; I’ve seen rates closer to 1 in 3. It’s easier for LLMs to find bugs in code than to write correct code initially.

**Second opinions on design**: Several designs I was excited about were shattered by an LLM pointing out a flaw I hadn’t considered. I’m not a language expert, and even after six months, I still feel like a novice. Experts might have better first attempts.

## Where to use LLMs with caution

**Starting points**: An LLM-designed system is often mediocre.
* *Workaround:* Treat the LLM’s output as an initial idea. Feed it to other LLMs, noting that while you want to move in that direction, the specific design is flawed. This turns a weakness into a strength by using them as second opinions. Results improve if you start with a strong personal opinion and iterate between multiple models.

**Testing their own code**: LLMs often verify that broken code "works" correctly. Even in reviews, they may miss bugs and praise flawed commits.
* *Workaround 1:* Don’t ask an LLM to test its own code. Instead, ask a different model for the ideal strategy to test *similar* code.
* *Workaround 2:* Use multiple LLMs to review code, specifically asking them to find bugs or poor implementations. This iterative process often reveals hidden issues.

## Where to use LLMs as a last resort

**Following directions**: LLMs won't always run tests, even when instructed. If you need a task performed reliably, use tooling. Integrate CI/CD (like GitHub Actions) immediately; LLMs can set this up quickly, but they cannot be trusted to run tests manually every time.

**Verifying correctness**: LLMs are disappointing here. They can generate complex SVGs but fail to count the "r's" in "strawberry."
* *Workaround 1:* Use LLMs for search. Ask for the best ways to verify correctness.
* *Workaround 2:* Iterate between models to refine verification methods.
* *Workaround 3:* Build tooling that provides a high signal-to-noise ratio regarding code quality. Code coverage is a start, but focus on building project-specific tooling for deeper insights.

## What LLMs I use and how

| Model | Implementation | Speed | Design | Review Signal |
| :--- | :--- | :--- | :--- | :--- |
| **Codex** | B+ | A+ | C | D |
| **Claude Code** | A- | D | B | B |
| **Gemini CLI** | C | D | B | B+ |

Gemini CLI is currently free and excellent as a second opinion. I haven’t tried Open Code or DeepSeek yet, but hear they excel at implementation over design.

For the cost-conscious:
* **Claude Code (Opus)** for design ONLY.
* **Codex** for implementation.
* **Gemini CLI** for review and second opinions.
* **DeepSeek** as a budget-friendly third opinion.

## The Magic Words

I’ve found that no amount of CLAUDE.md / AGENTS.md / skills beats manually prompting them at specific points.

You will obviously get better results the more attention you pay to what they've done, giving them more specific instruction. However, even broad ones like these can work wonders:

**For design and review:**
> "I suspect this design is unsafe, unscalable, or won't integrate well, but I can’t articulate why. Please find the holes in this design, especially where a better solution is obvious."

**For test reviews:**
> "Carefully review these tests. Are they verifying that the code is CORRECT or just that it's successfully broken? Are they testing robust invariants of the system, or just that THIS specific marginal case works?"

**For implementation reviews:**
> "Review this implementation for bugs. If you find one, add a test that proves it. Does this introduce redundant systems? Should it integrate with existing authorities? Look for tech debt and hacks. Determine if the test coverage is robust and sufficient."

## CLAUDE.md / AGENTS.md 

See my [CLAUDE.md](https://github.com/cuzzo/clear/blob/master/CLAUDE.md). The sections below "Output" are safe to copy. The "Contributing" section should be tailored to your project.

## Summary

LLMs can suggest a 100x velocity increase, but the reality is closer to 10x. Parallelizing work streams (compiler, runtime, VM) can multiply this, potentially reaching 40x.

However, LLMs struggle with merge conflicts and may ignore test failures. They also tend to change unrelated code, like comments.
* *Workaround 1:* Instruct them to remove non-essential comment changes or irrelevant edits before committing.
* *Workaround 2:* Make sure you have CI setup so that they can't pretend the system already didn't work and that they didn't break it (they will).

## Biggest Mistakes

### 1. Assuming LLMs could re-architect
I initially allowed LLMs to build a "pile of crap," assuming they could fix it later. They are great at building such piles but struggle to refine them into a functioning language. I could have saved 66% of my headaches by enforcing design guardrails early.

### 2. Moving too fast
Blitzing through features usually resulted in more work and headaches. Even with LLMs, rushing is costly. Delivering at 100x is tempting, but the "headache factor" of LLM mistakes is significant.

 * I had great success when I followed my learnings closely for this [FSM / Thunks / Streams PR](https://github.com/cuzzo/clear/pull/3).
    - The FSM implementation went especially well, which is where I slowed down the most.
 * I had much pain and suffering when I ignored my learnings, and prematurely merged in a ["hotfix"](https://github.com/cuzzo/clear/pull/31).
    - It ended up being a "Hot Bug Party" instead.

### 3. Not understanding LLM limitations early
I should have generated a robust test suite from the start. LLMs break architectural invariants easily. They can generate testing frameworks quickly; use them to create "fortress files" that protect your design goals.

## Why Software Jobs Aren't Imminent Targets
Engineering was never about typing speed. It’s about ensuring code works as intended. While LLMs could generate my project in days - it wouldn't *actually* work, and the bottleneck is review, ensuring it's implemented correctly and architecturally soundly, that it's sufficiently tested to have any guarantees it *actually* works, rather than it just happens to pass a slim set of tests, which may in fact be testing nothing.

Most engineers spend only a third of their time writing code or less. Even if LLMs automate that, cheaper code will likely increase demand for engineering. The market will lag technological possibility by 5–10 years.

Disruption will be asymmetric. Startups, new grads, and managers may see more impact than the general engineering population (or vice versa).

## Conclusion
In six months of part-time tinkering, I’ve built a competitive runtime and language. This would have been impossible without LLMs acting as a 50x force multiplier.

I can "code" while walking the dog, at the gym, during lunch, instead of doom scrolling before bed, etc.

While LLMs can be frustratingly inconsistent, they are the most amazing tools I’ve used. I’ve never been more excited about the future of engineering.
