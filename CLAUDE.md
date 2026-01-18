# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CHEAT is a memory-safe, interpreted programming language that combines Ruby/Python ease-of-use with Rust-like safety guarantees. It features arena-based memory management (no garbage collector), ownership semantics, and SQL-like declarative syntax with pipeline functionality.

## Build & Test Commands

```bash
bundle install              # Install Ruby dependencies
bundle exec rspec           # Run all tests
bundle exec rspec spec/lexer_spec.rb    # Run a single test file
bundle exec rspec spec/annotator_spec.rb:42  # Run specific line
```

## Architecture

The compiler is a 3-pass system written in Ruby:

**Pass 1: Parsing**
- `src/lexer.rb` - Tokenizes source code using StringScanner
- `src/parser.rb` - Rule-based parsing, tokens → AST

**Pass 2: Semantic Analysis**
- `src/annotator.rb` - Type inference, ownership verification (visitor pattern)
- `src/type.rb` - Type system with NaN-boxing, storage locations (:stack/:heap/:frame), ownership states
- `src/scope.rb` - Variable scoping with state tracking (:valid/:moved for affine types)
- `src/ownership_tracker.rb` - Move semantics, TAKES/GIVE validation, borrow checking
- `src/function_analysis.rb` - Arity, parameter types, mutability validation

**Pass 3: Code Generation**
- `src/transpiler.rb` - Generates Zig code
- `src/chunk.rb`, `src/opcodes.rb` - Register-based bytecode for VM

**Supporting Files**
- `src/ast.rb` - AST node definitions
- `src/std_lib.rb` - Standard library intrinsics
- `src/source_error.rb` - Error reporting with source locations

## Language Semantics

Key sigils that appear throughout the codebase:
- `%` = Heap allocation
- `&` = Borrow/reference
- `^` = Atomic (thread-safe)
- `@` = Pipeline binding
- `!` = Mutation suffix
- `s>` = SMOOTH operator (safe pipeline with error propagation)
- `?.` = Safe navigation
- `OR` = Error handling/recovery

Ownership keywords:
- `GIVE` - Transfer ownership to callee
- `TAKES` - Function receives ownership
- `MUTABLE` / `SET` - Explicit mutation

## File Locations

- Source code: `src/*.rb`
- Tests: `spec/*_spec.rb`
- Example programs: `examples/*.cht`
- Zig runtime: `zig/runtime-header.zig`, `zig/runtime-footer.zig`
- Documentation: `README.md`, `WALKTHROUGH.md`, `FUNCTION-ANATOMY.md`

## Design Principles

- Immutable by default, explicit mutation with `MUTABLE`/`SET`
- Arena-based memory - variables live as long as their function scope
- Affine types - values can only be used once unless Copy
- Fortress architecture - PUBLIC functions must return one type, handle all errors, accept only PUBLIC parameter types
