# Can AI Un-Slop Itself?

Everyone knows that LLMs can, at least, *sometimes* create slop.

The interesting question isn’t whether they can create slop.  It’s: can they un-slop themselves?

## Problem

I dreamed of a programming language for 10 years. After Gemini 3.1-pro, I figured LLMs were good enough that I should at least finally see what this AI "vibe-coding" craze was all about.

I set on a 6-month journey to build a programming language.

 * Within 2-months, I had a custom runtime built in Zig competitive with Go & Tokio.
 * Within 3-months, I had an Affine Ownership-based memory safe language like Rust - but (in my opinion) much more intuitive.

The problem is: this only *barely* worked, and no one wants a *barely* working programming language.

## What didn’t work

### WRT the language: 

 * Architecturally, the LLMs built it without a MIR-pass. 
 * Without boring you too much, it’s virtually impossible to guarantee affine ownership / memory safety without a MIR-pass.
 * So I had a memory safe language that *WASN’T* memory safe...
 * Nobody wants a Rust that regularly leaks memory and still has UAF and double free bugs...

### WRT the runtime: 

 * More of the same
 * There was no TSan testing in place
 * There was no memory ordering testing in place
 * The LLMs built a fiber runtime - complete with hammer tests... and never bothered to test if it’s actually thread safe...
 * Spoiler: it wasn't!

### What happened next?

I told the LLMs to fix their slop!

In about ~35 minutes, they screamed:

> “Done, you have a complete MIR pass in place! Everything is memory safe.”

They proceeded to feed me this same line of crap for ~1000 commits over 2 months, and me constantly asking:

> “If the MIR pass is done, then how come X is still there and Y is still segfaulting?”

LLMs:

> “Oh, yes, there’s just that one small part left. Okay, now it’s done!” 

## What happened next?

The definition of insanity is trying the same thing and expecting different results!

I gave up on LLMs' ability to tell me the truth about the state of a non-trivial codebase.

I got a wild idea...

 * If I can’t trust LLMs... 
 * Can I trust them to build me tools & systems to have more trust in them???

I had LLMs build me a set of tools that don’t exist in Ruby (it's turtles all the way down).

 1. I built the compiler in Ruby, because, initially this started off as a project I was building by hand.
 2. The initial scope was merely to play around with Syntax and see if I could develop something I liked.
 3. Never did I ever dream that I would actually get something this far.
 4. Everyone knows that a good compiler eventually self-hosts, and the goal was - like Crystal - my language would be quite close to Ruby (so LLMs should be able to migrate it easily).

Anyway, Ruby has decent tooling around “code health” like SimpleCov / Flay / Flog / Reek / Debride, etc.

The problem is, if you’re building a compiler with LLMs these aren’t the core metrics you need.

 * LLMs repeat themselves constantly... but then forget to do something the right way in one place... and then also don’t test it.
 * Especially in a dynamically-typed language, LLMs will randomly decide to use strings or symbols or nil to represent something, and then make thousands of defensive checks throughout your codebase... rather than fixing the problem at the source.
 * LLMs will regularly “refactor” your code and remove 99% of usage, but still leave 1% and then move on - leaving you with competing systems... and then later use the old one that doesn’t do everything you need, and get that usage back up to 10% (plus bugs).

The list goes on.

## What did they build?

I’m used to developing... like myself.  LLMs are different.  It’s sort of like pair-programming with a genius who is occasionally extremely dumb and sometimes downright adversarial.

How do you learn to work with this crazy partner?

I rarely need to think to implement code, and I type quite fast... So LLMs are not that much faster than me at implementation. But they do *scale*, whereas I do not. 

If I have to review all of their code line-by-line, I’d rather just write it myself. 

 * I don't have enough time to review the Rust code base line-by-line.
 * If I want a safer and more intuitive Rust, no one is going to build it for me.
 * I either get LLMs to do it, or it never gets done.  Period.

The goal wasn’t to try LLMs and find a reason not to use them... The goal was to find a way *TO* use them effectively.

If I have to review *EVERYTHING* LLMs write line-by-line, the bottle neck is me.  The entire goal of LLM development is to get the bottleneck NOT to be me - i.e. to scale.

You can’t scale yourself... but *maybe* you can scale with LLMs.

So, rather than say:

> I’ll just insert myself as a bottleneck and review everything line-by-line with caution… 

I thought:

> What if I put a system in place that makes it very hard for them to poke holes in?

## What does the system look like?

 * Save almost everything to docs/agents (compressed)
   - This gives LLMs a review signal to see if what was implemented is 1) fully implemented, and 2) matches the agreement
 * Competing sets of tests. An individual LLM that touches more than 1 set of tests when not *specifically* asked immediately warrants manual review.
   - At a minimum, I need to know that they didn’t put an exception in for their new feature to be allowed to leak memory or segfault… Because they regularly try to do that rather than write working code.
 * Mutation tests
   - This helps you find all of their do-nothing tests that are giving you an illusion of safety, rather than providing any real value
   - Typically, I trust myself to be able to write tests, so I don’t mutant test my own codebase.
   - Where I work - they don’t trust me. We have mutant testing. More than once, I’ve found more than once that I’ve written a do nothing test, so, hey, maybe we should all be mutant testing anyway!
 * Tooling & Reporting
   - I’ll cover this next
 * Review
   - I’ve found the typical review process looks like:
   - LLM screams done
   - I ask a different LLM to check the spec and see if it’s done
   - The LLM points out 2-3 major things NOT implemented, 2-3 things extremely poorly implemented, and 10+ things that are almost certainly bugs
   - Feed that back to the implementation LLM
   - Repeat for 3-5 rounds
   - Only here do I look at anything they’ve done.
   - This is typically ~20k lines of code per week... 
   - I can't look it over with a jade-handled spyglass inquisitively.
   - I need to be able to pinpoint the things that *NEED* to be reviewed so I can review them.

## Tooling & Reporting

Tooling & Reporting in general is a sweet spot for LLMs.  They are very good at getting things *nearly* working.

The problem is: most things need to *actually* work.

In some cases, you are far better off with nothing than something that has very bad failure methods.

If you’re using a report to give out a billion dollars, you probably want a report that *actually* works.

But if you want a report that just gives you a probability of how much AI slop there is in a commit, and how dangerous that AI slop might be... something is far better than nothing.

LLMs typically change ~20k lines of code per week on my codebase. I cannot (and have no intention ever to) review every single line.

That entirely defeats the purpose of trying to use LLMs to scale.

Instead, I will continue to invest in layers of defense to protect myself from their common pitfalls and accept that 1) almost no software is perfect, even compilers, and 2) the system I have in place with LLMs is doing at least 10x better than I could do on my own.

Interestingly, I’m trying to build a language that has the syntax to make the vast majority of bugs simply impossible to represent, and - when possible - the compiler can autogenerate all the failure methods that might unfold, so you can see exactly where a bug *might* be.

I wanted to do this *before* working with LLMs.  Now I want it more than ever before!

The question is: can LLMs ever get this language to work?

Time will tell... but - what I can tell you is - there’s not a shot in hell I’d ever get this done myself.

It at least seems *possible* with LLMs.
