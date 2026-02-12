# RubyConf 2026 Proposal — Sessionize Submission

## Title

Giving Robots Free Will

## Session Format

Standard Session (30 minutes + Q&A)

## Theme

Living with the Robots

## Description

In 2005, I used Ruby to drive massive multi-computer air and missile defense simulations at Lockheed Martin — war-gaming conflict scenarios across networked systems at 76 transactions per second. Twenty years later, Ruby handles hundreds of thousands of transactions per second, and its dynamic runtime lets us do something the VRSIL never imagined: build AI agents that can perceive a problem, decide how to solve it, and write the code they need to get it done.

What happens when Ruby objects can write their own methods, markdown files become autonomous entities, and your entire agent architecture is modeled after the same cybernetic theory that governs viable organizations?

This talk explores building genuinely autonomous AI agents in Ruby — not wrappers around API calls, but systems that can decide what to do, how to do it, and even create capabilities they don't yet have. We'll combine four open-source gems into a working architecture:

- **vsm** — an implementation of Stafford Beer's Viable System Model that gives agents a recursive organizational structure with identity, governance, intelligence, coordination, and operations
- **prompt_objects** — markdown files with LLM-backed behavior that act as first-class autonomous entities capable of communicating with each other
- **self_agency** — runtime method generation where objects describe what they need and an LLM writes the implementation on the fly
- **chaos_to_the_rescue** — a safety-first approach to handling missing methods through LLM generation with allowlists, secret redaction, and disabled-by-default guardrails

You'll see how these pieces compose into agents that aren't just tools — they're systems with purpose, structure, and the ability to grow. We'll walk through a live demonstration of an agent that encounters a problem it wasn't built to solve, extends its own capabilities, and completes the task — all within a governance framework that keeps it from going off the rails.

You'll leave with:

- A practical architecture for building autonomous agents in Ruby
- An understanding of the Viable System Model and why it matters for agent design
- Concrete patterns for runtime method generation with appropriate safety controls
- The confidence to move beyond "AI as autocomplete" toward agents with genuine agency

No PhD in cybernetics required. Just Ruby.

## Notes for Reviewers

This talk sits at the intersection of Ruby metaprogramming and the emerging agent ecosystem. The core argument is that Ruby's dynamic runtime — method_missing, define_method, open classes — makes it uniquely suited for building agents that can modify their own behavior, and that Stafford Beer's Viable System Model from cybernetics provides the missing architectural discipline to do this safely.

**Structure (30 minutes):**

- (3 min) From war games to AI agents: in 2005 Ruby drove networked missile defense simulations at 76 TPS. In 2026, with hundreds of thousands of TPS available, the same dynamic runtime lets agents write their own code. The throughline — and why most Ruby AI tooling still sells the language short.
- (5 min) The Viable System Model — a 60-second primer on Beer's five systems and why recursive organizational structure matters for agents.
- (7 min) Building blocks — how vsm, prompt_objects, self_agency, and chaos_to_the_rescue each contribute a distinct layer of autonomy.
- (10 min) Live demo — an agent built on these gems encounters an unfamiliar task, generates the methods it needs, validates them against governance rules, and completes the work.
- (3 min) Safety and guardrails — the governance layer, allowlists, secret redaction, and why "free will" requires structure to be useful.
- (2 min) Where this is going — the roadmap for these tools and how attendees can get involved.

**Why this talk now:** The Ruby AI ecosystem has matured significantly in 2025-2026. We have ruby_llm, MCP support, and multiple agent frameworks. But most talks focus on *using* AI from Ruby. This talk focuses on *building AI systems* with Ruby's unique strengths — and gives attendees a concrete, composable architecture they can start using immediately.

**Speaker experience:** I am a previous RubyConf speaker — I presented "Ruby: Warrior with a Cause" at RubyConf 2011 in New Orleans (available on YouTube), covering Ruby's use in the Virtual Reality Systems Integration Lab (VRSIL) at Lockheed Martin Missiles and Fire Control, where I led the lab. That talk covered Ruby driving massive networked air and missile defense simulations; this talk is the natural continuation — the same language and dynamic runtime, now building AI systems that can extend themselves. I've been using Ruby professionally since 2005 (over 20 years) and am the author of self_agency, aia (AI Assistant CLI), and prompt_manager. I've been focused on the Ruby AI ecosystem since 2023.

**Collaboration:** This talk showcases gems from three authors (myself, Scott Werner of Sublayer, and Valentino Stoll), demonstrating the collaborative growth of Ruby's AI community. Both have been consulted on the talk content.

## Bio (100 words max)

Dewayne VanHoozer has been using Ruby professionally since 2005, starting at Lockheed Martin where he led the Virtual Reality Systems Integration Lab running networked air and missile defense simulations. A previous RubyConf speaker ("Ruby: Warrior with a Cause," 2011), he is the author of self_agency, aia, and prompt_manager. Now semi-retired, he consults with stealth startups and writes open-source Ruby gems exploring how cybernetic theory and Ruby's dynamic runtime can produce AI systems with genuine agency — safely.
