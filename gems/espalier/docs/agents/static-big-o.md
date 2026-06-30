# Static Big-O Complexity Analysis in Espalier

## Overview
This document outlines a proposed architecture for adding **Static Big-O Complexity Analysis** to Espalier. Unlike empirical runtime measurements (which suffer heavily from JIT noise, GC pauses, and the need for scaling benchmark data), a static approach mathematically analyzes the AST of a method to compute a theoretical worst-case time complexity.

Espalier is uniquely positioned to achieve this because it can ingest concrete type evidence from `nil-kill`. By combining `fact-mine`'s structural AST extraction with `nil-kill`'s type resolution, Espalier can accurately resolve method calls to their host classes (even with dynamic dispatch and operator overloading) and apply algorithmic complexity rules.

## Core Architecture

The static Big-O analyzer relies on three pillars:
1. **The Stdlib Complexity Registry**
2. **Type Resolution via Nil-kill**
3. **AST Complexity Multiplication**

### 1. The Stdlib Complexity Registry
To statically evaluate Big-O, Espalier must know the complexity of standard library functions that execute non-linear C-loops in the Ruby VM.

Because we assume an implicit default of $O(1)$ for unknown operations, we do not need to map the entire standard library. We only need to map the ~150 core methods that operate in $O(N)$ or worse.

A YAML registry (`stdlib_complexity.yml`) will map these behaviors:
```yaml
Array:
  each: O(N)
  map: O(N)
  select: O(N)
  flatten: O(N)
  sort: O(N log N)
  "-": O(N * M) # Subtraction
String:
  scan: O(N)
  gsub: O(N)
  split: O(N)
  "+": O(N)
Hash:
  merge: O(N)
  transform_values: O(N)
```
*(All unmapped methods like `Hash#[]` or `Integer#+` default to $O(1)$).*

### 2. Type Resolution (Handling Operator Overloading)
When Espalier encounters an AST node for `a + b`, it cannot blindly apply a complexity rule. If `a` is an `Integer`, it is $O(1)$. If `a` is a `String`, it is $O(N)$.

Espalier will use the injected `nil-kill` evidence (`--nil-kill FILE`) to query the resolved type of `a`. 
- If `nil-kill` proves `a` is `String`, Espalier consults the registry for `String#+` and assigns $O(N)$.
- If `nil-kill` cannot prove the type (or it resolves to `Integer`), it defaults to $O(1)$.

### 3. AST Complexity Multiplication
The analysis walks the AST of a given method from the inside out, multiplying complexities when nested inside block constructs.

**Rules:**
1. **Sequential Statements:** Added together. $O(N) + O(1) = O(N)$.
2. **Standard Loops (`while`, `for`):** The body's complexity is multiplied by $O(N)$.
3. **Block Iterators (`.each do`, `.map do`):** The registry flags the iterator as $O(N)$. The AST engine multiplies the iterator's complexity by the complexity of the block's body.
   - Example: `.each { |x| x.gsub(...) }` $\rightarrow O(N_{each}) \times O(N_{gsub}) = O(N^2)$.
4. **User-Defined Method Calls:** If a method calls another user-defined method, Espalier looks up the pre-calculated Big-O of the callee and substitutes it.

## Output and Diagnostics
Espalier will rank methods by their theoretical complexity and emit architectural warnings for highly non-linear constraints. 

**Example Report Output:**
> **[Complexity Constraint]** `SyntaxOracle#project_document` is $O(N^2)$. 
> **Why:** The method calls `Array#each` ( $O(N)$ ) on `line 42`, which internally calls `String#scan` ( $O(N)$ ) on `line 44`. This forces the caller to manage quadratic scaling. Consider memoization or a specialized parser.

## Why This Works Here
Building static Big-O analyzers for dynamic languages is traditionally impossible because of the lack of static types (which breaks stdlib mapping). By leveraging `nil-kill` as a type-oracle, Espalier bypasses the dynamic dispatch problem entirely, making this an extremely high-leverage architectural addition.
