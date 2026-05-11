# What I learned (the hard way) Building a Memory Safe Programming Language with LLMs over the last 6 months

## Background
I wanted a language like Rust, but substantially safer, and substantially more intuitive.

I thought this was not a terrible problem to outsource to LLMs, especially since my goal was to get an understanding of what they are capable of, where they excel, and where they don't - and my expectations were low.

A compiler is notoriously difficult to verify correctness. There are obviously harder problems, but compilers are not known to be easy. Since you control the language, you can control your problem space - but at least for my goals, I don’t think this would rank high on the list of problems for LLMs (and still I’m blown away by what they’ve done - even if my dream is never fully reached).

The language is [CLEAR](https://github.com/cuzzo/clear), and these are my learnings from this wild 6-month adventure.

## Where LLMs excel
* Giving you a lot of ideas / signals
* Filtering / reducing signals
* Finding problems
* Making optimizations (with major guardrails)

## Where LLMs are decent, but not as good as I expected
* Refactoring - especially re-architecting

## Where LLMs do not excel
* Getting things correct
* Obeying design principals
* Resolving merge conflicts

As it turns out, it is much easier to find a hole in a ship, than to build a ship that won’t ever have a hole.

It becomes hard to understand how to balance the pros of LLMs with their cons. In my experience, the most challenging part of extracting high value from LLMs is being disciplined. They make it so easy to kid yourself, to cut corners - even if that isn’t your goal.

When you have no ideas, LLMs can flood you with them. Typically, you can weed out the bad ones.

When you're flooded with data, and you need to sort it, LLMs can do a decent job, though they will obviously make some mistakes.

You can solve a lot of problems by having LLMs generate scripts that produce tons of data, and having them sift through the data. 
* I’m planning to release a tool that allows LLMs to run through a loop until they fully type a Ruby codebase
  - They did this for a ~40k line transpiler in a day after the tooling. 
  - The tooling took another 1-2 days to build.
  - You can see it in [nil-kill](https://github.com/cuzzo/clear/blob/master/tools/nil-kill.rb) in my repo, though, I’ll release this as a standalone Gem shortly.
* I would never be able to find the signal in that data without spending more and more time on tooling to get the signal out of it.
  - And certainly without LLMs, I’d not spend the time to build all the tooling by hand! 
* LLMs will miss things for sure, there will be bugs in the tooling, but they can find a shocking amount of signal in data (even buggy data) that is easy to generate and almost impossible for ME to derive value from.

When correctness is utterly important (most of building a language), LLMs are very bad here. They are very good at getting *close* to correct, very fast. But very bad at getting *actually* correct *on their own*.

The goal of using any tool is to get as much value from it as you can, without any negatives.

You can derive a lot of value from a hammer if you use it to hit nails. You will not do so well with a hammer if you try to use it to knit a sweater.

## Where to use LLMs aggressively

**LLMs can prototype things unbelievably fast.** This has tons of value. In many cases, a prototype is fine to be *sort of* correct. It is worth thinking twice before prototyping even with an LLM, though. 
* If you want to see how fast something could be - AND it needs to be correct - that could have pretty big implications on performance.
* If you want to see how much simpler something could be - a lot of the prototype’s simplicity can come from its incompleteness and incorrectness.

**Second opinions generally**
Two heads are usually better than one. LLM reviews of commits may be a lot of noise, but I find the signal to be well worth it when it’s there.

**Second opinions specifically for reasons to reject something**
Again, you may get a lot of noise, but a signal on a critical bug is worth tons of noise in my opinion.
In general, I have had a lot of success having LLMs hunt for bugs. If even 1 in 10 is a signal, that’s a massive win. I’ve typically had rates closer to 1 in 3. It’s easy for LLMs to find bugs in their own code. They’re not good at writing correct code.

**Second opinions on design**
I’ve had several designs that I’ve been very excited for get completely shattered by an LLM pointing out a real flaw I hadn’t considered.
I’ve never built a language before. I didn’t have a clue what I was doing when I started, and even after 6 months, I still mostly feel that way.
I’m sure if I was working in a space where I *am* an expert, my first attempts at a design would be less terrible.

## Where to use LLMs with caution

**Starting points**
If you ask an LLM to design something for you, it may be better than nothing, but it’s not very good. 
* *Work around:* treat this as your initial idea, feed it to other LLMs, tell them you want to move in this direction, but you think this particular design is bad, and you can’t articulate why, but you have a feeling there must be a better design. 

You’ve just turned one of their biggest weaknesses into a strength. They’re a good second opinion. They do much better if you start with a better first opinion (i.e. a good one of your own). But you can iterate ideas between two to three LLMs and achieve decent results, assuming you have any clue what you’re doing.

**Testing their own code**
They will regularly test that things are broken correctly.
Even in review, LLMs will regularly miss this and say, yes, this in fact is broken correctly, this is a great commit.
* *Work around 1:* don’t ask an LLM to test the code it wrote. Ask an LLM (ideally a different one) - what is the ideal strategy to test code LIKE this. They will give you good starting points. There’s more to testing than just unit tests and integration tests - especially in systems programming
* *Work around 2:* second opinions again -> ask other LLMs to review code, say that you think it’s poorly implemented, infested with bugs, etc. They will produce a lot of signal, but they’ll likely find several bugs (even if you go through this loop 2 or 3 times).

## Where to use LLMs as a last resort

**Following directions**
LLMs will not always run your tests even if you tell them to. If you need anything done, you must have tooling in place to make sure it is done. Don’t wait to integrate GitHub actions. LLMs can do it in 1 minute. They will not reliably run your tests.

**Verifying correctness**
I could not be more disappointed with LLMs on this front. I just can’t really wrap my head around how they can do so much - draw pelicans riding bicycles as SVGs - but they can’t get even relatively simple things correct - like how many rs in strawberry.
* *Work Around 1:* LLMs are good at search. You can tell them you’re struggling to verify something is correct, and what are the best ways to do that. Remember, this is a Starting Point - they aren’t great here.
* *Work Around 2:* Feed this iteratively back and forth to LLMs, you will eventually arrive at something much better than you probably could have on your own, and probably pretty quickly.
* *Work Around 3:* You have to build tooling that gives you a lot of signal to noise to the quality of their work. Code Coverage is okay. It’s a decent starting point, but see the point about them testing code that is broken correctly. You can ask them for ideas specific for your project on what tooling you can build to give you better insight. Again, this is a Starting Point. Their first solutions will be better than nothing, but not good. Iteratively get better input.

## What LLMs I use and how

| Model | Implementation | Speed | Design | Signal to Noise for Review |
| :--- | :--- | :--- | :--- | :--- |
| **Codex** | B+ | A+ | C | D |
| **Claude Code** | A- | D | B | B |
| **Gemini CLI** | C | D | B | B+ |

AFAIK, Gemini Cli is free. Unless I’m mistaken, I can’t recommend it enough as a second opinion.

I haven’t yet tried Open Code and DeepSeek, but I’ve heard great things about implementation, though not such great things about design.

For cost sensitive folks, I suspect the best path is:
* **Claude Code Opus Max** for design ONLY
* **Codex** for all implementation
* **Gemini Cli** for all review & second opinion
* **DeepSeek** is so cheap it would likely be well worth a 3rd opinion

## What are the magic words I’ve found

**For design and design review:**
> "I suspect this design is inherently unsafe, unscalable and/or will not integrate nicely into the existing system, but I can’t articulate why. Please look for all the holes in this design, especially where it’s clearly wrong and there’s an obvious better solution."

**For code review (On tests):**
> "Please carefully review the tests in this commit. Ignore the actual implementation. Are the tests testing that the code is CORRECT or are they testing that it is successfully broken? Are the tests testing robust and critical invariants of the system, or are they just testing specific points that are only marginally helpful?"
*(For concurrent tasks, I wrote a whole document on how to get LLMs to test concurrent code better.)*

**For code review (On implementation):**
> "Please carefully review the implementation in this commit. Try to find any bugs in it. If you can find a bug, add a test that proves there is a bug. Carefully consider if this code is introducing parallel systems to ones that already exist. Should it be integrating with a better system that already exists and is the authority? Or has it improved a system that others should be migrated to and now rely on? Look for tech debt. Did this implementation introduce hacks that only work by chance? Or is this the correct and ideal solution to the problem it’s trying to solve?"

## What has helped in CLAUDE.md / AGENTS.md 

See my [CLAUDE.md](https://github.com/cuzzo/clear/blob/master/CLAUDE.md) - everything below the “Contributing” section. The sections below “Output” should be safe to copy directly (and are not my own - I’ve unfortunately lost where I got them from to give credit where it’s due).  The sections between “Contributing” and “Output” would need to be tailored to your specific project.

Everything above that is relevant to my project and should obviously not be used for yours.


## In Summary

LLMs can easily fool you into thinking you can increase your velocity 100 - 1000x, but currently it’s probably closer to the 10x range.

The great thing about LLMs is that if your work can be parallelized (compiler, runtime, tooling, VM) - you can get close to multiplying that 10x. If you have 4 parallel work streams, you may be able to get close to 40x or more.

However, LLMs are impressively bad at resolving merge conflicts.
They will regularly say, there were 800 failures on master before this merge, and there are 800 now, so I’m going to commit this, and I’m going to press forward for hours with all of those errors, and wonder why there’s so many bugs and it’s so hard to get anything to work. So, unless your work parallelizes very well, each stream will likely be slowed down considerably by the final merging.

LLMs are notorious for changing tons of code they don’t need to, especially comments, no matter how many times you tell them not to. This is part of the reason they are so bad.
* *Work Around:* at the end of their commit, tell them to cut comment changes that aren’t exceptionally high value, tell them to cut out any changes that aren’t directly relevant to correctness of the feature in question.

## The Biggest Mistake I Made
My assumption going into this was that LLMs would be pretty good at rearchitecture. So in the beginning, I had them just build me a massive pile of crap (assuming that’s all I’d ever get), and then telling them: “make the crappy pile better”.

As it turns out, LLMs are unimaginably skilled at building piles of crap. They are not very good at turning a pile of crap into a functioning programming language.

I probably could’ve saved >66% of the headache, and >33% of the total time, by spending more time up-front to have guardrails in place to make sure they were doing a decent job on design.

## The Second Biggest Mistake I Made
Going faster than I needed to.

Almost every time I had LLMs blitz through features, it ended up being worse than going through them slowly - 1) in terms of time, but 2) in terms of headaches.

It’s easier to give advice than it is to take it. I still find myself prematurely merging in features where I did not follow my previous learnings from mistakes - and that costing me 2-3x more time (and 10x more headaches) than just doing it right the first time.

I suppose we make this mistake even without LLMs. LLM mistakes tend to be much worse than the mistakes I would typically make - thus the 10x headache factor. Worst of all, for me, personally, I feel like I make this more often with LLMs than without - no matter how hard I try to avoid it.

The appeal to delivering at 100-200x instead of 10-20-30x is just too hard to resist.

## The Third Biggest Mistake I Made
Inevitable - but not understanding what LLMs are good and bad at BEFORE getting started.

In hind sight, I would have had LLMs generate a much more robust test set from the beginning
* They break architectural invariants / design principals on a whim like it’s nothing.
* We’re used to not doing this, and not needing to develop tests to make sure we don’t break these in early stages.
* LLMs are different. They can generate massive amounts of testing frameworks insanely quickly - this certainly won’t be bullet proof, and there’s no guarantee in later commits they won’t add a hole for them to bypass to put a hack in that breaks all your goals. But it’s much better than nothing.
* It gives you some fortress files you can keep an eye on in review to make sure nothing suspicious happens there.

## Why I Don’t See LLMs as an Imminent Threat to Software Jobs
The bottleneck in coding was never typing speed. It has always been making sure code actually works the way you want it to.

LLMs could’ve generated the code for my project in 1 or 2 days. The bottleneck is review speed. Their code still needs to be reviewed. And I’m skeptical this is a problem that will be solved in the next 3 years.

At the end of the day, most engineers are lucky to spend 1/3rd of their time actually writing code. Assume LLMs take 100% of that job. That’s 1/3rd of engineers. But cheaper code will likely increase demand for engineers as more things become automated.

Ultimately, the market is going to lag what’s possible by 5-10 years. I would guess that close to ~90% of code could be outsourced to LLMs at this point. My guess is that <33% of code at big companies currently is. I suspect that number won’t hit 90% for 5 years.

At that point, LLMs may be closing the gap on their ability to review code, follow design principals, etc. But the market will lag on that front by 5-10 years as well. And the scope of engineering will grow massively over that time.

Anything is possible. There could be less engineers in 5 years in the job market than there are today. But even if LLMs are writing 90% of code in 5 years (of which I’m skeptical, even though I think they probably could do that today, already) - I can’t see a market where there’s dramatically less engineers, like 50% less. It’s just too small of a part of the job.

As with every disruption, the pain will be asymmetric. There could be 50% less startup jobs, even if there’s more startups, as they more quickly embrace LLM development (mostly out of necessity). There could be 50% less new grad jobs, as companies expect devs to become even more productive instead of hiring new grads. There could be 50% less managers, or maybe FAANG / MAG-7 cuts 50% of their engineers to increase profits even more. But the entire market? I really doubt it.

## In Closing
I’ve built a runtime decently competitive with Go and Rust, and a language I’m quite happy with, that is almost ready to start sharing with folks in 6 months of part time tinkering.

There is ZERO chance I could have done anything like this if LLMs weren’t a force multiplier of over 50x for me.

I can “code” while I walk my dog. I can “code” in between sets at the gym. I can “code” while I eat lunch at work. I can “code” before bed instead of doom scrolling.

Am I wasting my time trying to build a better Rust part time, mostly on my phone? Probably.

Am I endlessly impressed with what LLMs are able to do? Yes.

Do they also make me want to smash my head against a wall, when - despite their almost God-like powers - they do the dumbest imaginable things? Also, yes.

In some ways, I feel like I’ve become quite good at wielding this tool. In other ways, I just feel like I’m shaking a magic eight ball and hoping for the best.

No matter what, LLMs have been the most amazing tool I’ve had the pleasure to work with ever, and I’ve never been more excited about engineering, or about the future in general.
