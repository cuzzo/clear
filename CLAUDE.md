# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

**CLEAR** is a memory-safe programming language that combines the ease of Ruby/Python with Rust-like safety. It features arena-based memory management (no garbage collector), ownership semantics, and separates **Types** from **Capabilities**.

## Build & Test Commands

```bash
bundle install              # Install Ruby dependencies
bundle exec rspec           # Run all tests
```

## Architecture

The compiler is a 3-pass system written in Ruby:
1.  **Parsing:** `src/lexer.rb`, `src/parser.rb`
2.  **Semantic Analysis:** `src/annotator.rb`, `src/type.rb`, `src/scope.rb`, `src/ownership_tracker.rb`
3.  **Code Generation:** `src/transpiler.rb` (generates Zig code)

## Language Semantics

CLEAR distinguishes between **Types** (what data is) and **Capabilities** (how it's accessed).

### Key Sigils
- `&` = Borrow/reference
- `@` = Pipeline binding
- `!` = Mutation suffix
- `s>` = SMOOTH operator (safe pipeline with error propagation)
- `!!` = Explicit panic

### Ownership & Capabilities
- `multiowned` (Rc), `shared` (Arc), `alwaysMutable` (RefCell), `indirect` (Box).
- Functions take **Types**, not Capabilities.
- Capabilities are unwrapped at the call site using `WITH` blocks.
- `GIVE` - Transfer ownership to callee.
- `TAKES` - Function receives ownership.

## Design Principles

- **Immutability:** Default, explicit mutation with `MUTABLE`/`SET`.
- **Arena Memory:** Variables live for their function scope; large objects escape via RVO or page handoffs.
- **Local Reasoning:** `WITH RESTRICT` ensures that mutable "poisoning" is always visible and scoped.
- **Fortress Architecture:** Public APIs must be strictly defined and handle all errors.
