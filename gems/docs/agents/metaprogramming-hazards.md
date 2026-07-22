# Metaprogramming Hazards Design Document

## 1. Overview
Metaprogramming provides powerful capabilities to write code that writes, modifies, or dynamically dispatches code at runtime. While useful, it introduces significant hazards: it obscures control flow, evades static analysis, makes refactoring dangerous, and can lead to unexpected runtime crashes or security vulnerabilities if dynamic inputs are unconstrained.

Similar to how we detect concurrency hazards by identifying atomic operations (e.g., finding `.acquire` in Zig for atomic operations or mutex locks), our goal is to detect the **usage** of metaprogramming constructs in dynamic (and static) languages. 

This document outlines what constitutes a metaprogramming hazard language-by-language, what patterns are out of scope, and how developers can test or mitigate these hazards with actionable steps.

## 2. Scope & Principles

**In Scope:**
* Detection of *direct usage* of metaprogramming and reflection constructs (e.g., authoring a method that explicitly calls `send`, `method_missing`, or invokes a reflection API).
* Detection of random function pointer invocations.
* Actionable mitigation and testing strategies for each identified hazard.

**OUT OF SCOPE:**
* **Indirect/Transitive Usage:** We do *not* want to flag a hazard every time code calls a function or framework that uses metaprogramming internally. For example, standard Rails ActiveRecord method calls are out of scope. We only flag the *authoring* of the metaprogramming logic itself.
* **Compile-Time Metaprogramming:** Macros (C/C++, Rust) and compile-time templates are out of scope. They are resolved by the compiler and are distinct from runtime dynamic behavior.
* **Ubiquitous Dynamic Features in Untyped Languages:** In dynamic languages (JavaScript, Python), calling a variable as a function or accessing properties dynamically (e.g., `obj[key]`) is heavily used for standard dictionary/object lookups. 
  * **Static Analysis (Out of Scope):** Attempting to flag these purely via static analysis would result in intractable noise, so they are treated as out of scope unless they utilize a specialized reflection API.
  * **With Nil-Kill Data (In Scope):** However, if nil-kill test-tracing detects that a hash or array is actually acting as a struct or tuple in poor disguise, we *should* flag dynamic **read** accesses (e.g., `obj[dynamic_key]`) as a hazard. Because the underlying data is structurally a static shape, a dynamic read is technically an optional lookup (it could miss the struct's keys and return nil). Dynamic **writes** in this context are generally fine, but dynamic reads must be explicitly flagged and mitigated.

---

## 3. Language-by-Language Hazards & Detection

### 3.1. Ruby
Ruby relies heavily on metaprogramming. We detect the direct invocation of metaprogramming methods.
* **Hazards:**
  * `send` and `public_send`
  * `method_missing` and `respond_to_missing?`
  * `instance_variable_get`, `instance_variable_set`, `class_variable_get`, `class_variable_set`
  * `define_method`, `undef_method`, `remove_method`
  * `eval`, `class_eval`, `module_eval`, `instance_eval`
  * `const_get`, `const_set`
* **Detection Mechanism:** AST parsing for calls with an explicit `self` or core-module receiver (`Kernel`, `Object`, `Module`, or `Class`). Calls on arbitrary receivers and unqualified user-defined methods are not treated as proof of Ruby metaprogramming; local methods that shadow these names are excluded.

### 3.2. Python
Python’s reflective capabilities allow for extensive runtime modification.
* **Hazards:**
  * `getattr()`, `setattr()`, `delattr()`, `hasattr()`
  * Magic methods overrides specifically for dynamic dispatch: `__getattr__`, `__getattribute__`, `__setattr__`
  * `eval()`, `exec()`
  * Dynamic class generation using `type(name, bases, dict)`
* **Detection Mechanism:** AST parsing to detect function calls matching these built-ins or magic method definitions.

### 3.3. JavaScript / TypeScript
JavaScript's core is inherently dynamic, making some metaprogramming indistinguishable from standard code.
* **Hazards:**
  * `eval()` and `new Function(...)`
  * `Proxy` objects (specifically trapping `get`, `set`, `apply`)
  * The `Reflect` API (`Reflect.get`, `Reflect.set`, `Reflect.apply`)
* **Detection Mechanism:** AST scanning for `eval`, `Function`, `Proxy`, and `Reflect`.
* *(Note: Standard dynamic property access `obj[key]` is explicitly out of scope due to detection difficulty.)*

### 3.4. PHP
* **Hazards:**
  * `eval()`
  * `call_user_func()` and `call_user_func_array()`
  * Magic methods: `__call()`, `__callStatic()`, `__get()`, `__set()`
  * **Variable Functions:** Invoking a string variable as a function (e.g., `$func = 'my_function'; $func();`). This is PHP's native version of dynamic function pointers and is highly hazardous.
* **Detection Mechanism:** AST scanning for these reflective functions, magic methods, and variable-function call syntax.

### 3.5. Go
Go is statically typed, making reflection explicit and easily detectable.
* **Hazards:**
  * Usage of the `reflect` package, particularly methods like `reflect.ValueOf().MethodByName().Call(...)` or `.FieldByName()`.
* **Detection Mechanism:** AST scanning for imports of `reflect` coupled with method invocations like `.MethodByName`.

### 3.6. Java / C#
* **Hazards (Java):** `java.lang.reflect.*` (e.g., `Method.invoke()`, `Class.forName()`, `Field.get()`).
* **Hazards (C#):** `System.Reflection` (e.g., `MethodInfo.Invoke()`, `Activator.CreateInstance()`, `Type.GetType()`). The `dynamic` keyword is intentionally not classified by token name alone because it has no receiver or target provenance.
* **Detection Mechanism:** FactMine uses API-shaped reflection expressions and typed framework identifiers. Receiver-variable names are not treated as type or provenance evidence.

### 3.7. C / C++ (Static Function Pointers)
* **Hazards:**
  * **Random Function Pointers:** Dynamic function pointer invocation (e.g., `(*func_ptr)(args...)`). This is a prominent hazard in static languages, representing dynamic dispatch and control flow obfuscation. (Note: Detecting function pointers in dynamic languages is much harder and prone to noise, so we rely entirely on static types here).
  * **Dynamic Loading:** `dlsym()`, `dlopen()`, `GetProcAddress()` which load and invoke functions from shared libraries at runtime.
* **Detection Mechanism:** AST analysis to detect function pointer dereferences and explicit calls to dynamic linker APIs.

---

## 4. Actionable Testing and Mitigations

When a metaprogramming hazard is detected, it is rarely enough to just say "be careful." We must provide actionable solutions. If a hazard cannot be mitigated or adequately tested, it must be explicitly called out as an unmitigable risk. We will not invent pretend solutions.

### 4.1. Code Constraints (Prefixing and Scoping)
When dynamically invoking methods (like Ruby's `send`), the biggest risk is that an attacker or an unexpected state can invoke *any* method on the object.
* **Actionable Suggestion:** Use a static allowlist, a restricted receiver interface, or a generated dispatch table.
* **Important limitation:** Prefixing the string is only a naming convention. `send("process_#{user_input}")` can still invoke any existing private or dangerous `process_*` method, so it is not a complete mitigation by itself. If a prefix is retained as defense in depth, validate the resulting name against an allowlist before dispatch.

### 4.2. Runtime Telemetry and Exception Tracking
Because metaprogramming circumvents static types, failures (e.g., `NoMethodError`, `AttributeError`) occur strictly at runtime, often in unpredictable ways.
* **Actionable Suggestion:** Require the metaprogramming logic to be wrapped in a rescue/catch block that pushes telemetry to an exception tracker (e.g., Sentry, Datadog).
* **Why:** This acknowledges the hazard and guarantees that when dynamic dispatch misses or fails, engineers are actively alerted rather than the application failing silently.

### 4.3. Nil-Kill / Test-Tracing
Traditional unit tests often fail to thoroughly cover the permutations of dynamic paths created by `method_missing` or `__getattr__`.
* **Actionable Suggestion:** Leverage nil-kill runtime test-tracing as execution evidence.
* **Why:** By instrumenting the code during tests, you can observe which dynamic paths executed. This is line/site coverage only; it does **not** prove that eval input is safe, reflection targets are constrained, a native function pointer is valid, an allowlist is complete, or callback behavior is correct. Those claims require static constraints and, where applicable, sanitizer or type-specific evidence.

FactMine records this distinction in the shared `hazard-contract` manifest. Dynamic-dispatch, reflection, native-loader, and unresolved callback sites are review boundaries rather than automatically line-coverage obligations. Typed callbacks with a statically known callable type are ordinary interface calls and are not emitted as callback hazards.

### 4.4. Untestable / Unmitigable Hazards
Some metaprogramming paradigms are inherently unsafe and offer no reliable mitigation. If there is no good way to test or protect against them, we simply call them out as such.
* **Examples:**
  * Widespread `eval(user_input)`.
  * Using Python's `__getattribute__` to silently alter state on *every* attribute lookup without constraints.
  * Unconstrained `method_missing` blocks that act as catch-alls without falling back to `super`.
* **Actionable Suggestion:** Call these out as structurally unsafe. The actionable advice is to **rewrite without metaprogramming** (e.g., use explicit interfaces, factory patterns, or simple hash maps for dynamic lookups). If there is no alternative, it remains flagged as a permanent high-risk area.

---

## 5. Hazard Categorization (Language Agnostic)

To systemize our approach, we can categorize metaprogramming hazards into distinct, language-agnostic classes. Each class dictates whether it can be safely tested (e.g., via permutation testing like Loom/VOPR/Hammer) and whether prefixing or structural rewrite is the required mitigation.

### Class 1: Arbitrary Code Execution (e.g., `eval`, `exec`, `new Function`)
* **Description:** Executing arbitrary strings of code dynamically at runtime.
* **Testability:** **Untestable.** The state space of arbitrary strings is infinite; a Loom/VOPR/Hammer permutation test cannot reasonably permute or validate the possible side effects.
* **Work-around / Prefixing:** Not applicable. You cannot safely prefix or constrain a raw `eval` execution without effectively building your own parser/sandbox.
* **Actionable Recommendation:** **Replace Entirely.** There is virtually no modern, safe use case for `eval` on dynamic user input. It cannot be easily worked around and must be structurally removed unless the developer intentionally accepts an unmitigable risk (which is rarely advisable).

### Class 2: Unconstrained Dynamic Dispatch (e.g., `send(var)`, `call_user_func(var)`)
* **Description:** Invoking methods or functions where the method name itself is fully dynamic.
* **Testability:** **Difficult.** A Loom/VOPR/Hammer test could theoretically fuzz inputs to see if a crash occurs (e.g., a `NoMethodError`), but it cannot easily know *which* methods were intentionally exposed.
* **Work-around / Prefixing:** A prefix alone is not a mitigation: dangerous methods can share the prefix. Use a strict static allowlist, a restricted receiver interface, or a generated dispatch table; a prefix may only narrow the candidates before that check.

### Class 3: Dynamic State Mutation/Access (e.g., `instance_variable_get(var)`, `getattr(obj, var)`)
* **Description:** Reading or writing internal object state or properties using dynamic string keys.
* **Testability:** **Moderate to High.** Nil-kill tracing is highly effective here. If test-tracing identifies the object as a struct/tuple in disguise, it can test whether a dynamic read (`obj[var]`) results in a nullable miss.
* **Work-around / Prefixing:** A prefix narrows names but does not prove that every matching field is safe. Prefer a typed/restricted interface or a static allowlist of fields, with prefix validation only as an additional guard.

### Class 4: Catch-All Interception (e.g., `method_missing`, `__getattr__`)
* **Description:** Overriding the runtime's default behavior for missing methods or properties to intercept unhandled calls.
* **Testability:** **High.** A Loom/VOPR/Hammer test can permute method calls on the object to ensure the catch-all logic doesn't crash or silently swallow expected errors. Nil-kill tracing is also essential here to ensure the internal branches of the catch-all were physically exercised during tests.
* **Work-around / Prefixing:** Not applicable. The hazard is structural.
* **Actionable Recommendation:** The logic inside the catch-all must fall back to the language's default behavior (e.g., calling `super`) if the dynamic condition isn't met.

### Class 5: Dynamic Function Pointers
* **Description:** Passing around memory addresses or variable strings and executing them as functions (e.g., `(*func_ptr)()` in C/C++, `$func()` in PHP) without compile-time guarantees.
* **Testability:** **High (via Fuzzing/VOPR).** Permutation testing can execute the function pointer across different states to verify memory safety or crash resilience.
* **Work-around / Prefixing:** Usually requires a **structural rewrite**. In static languages, this should be replaced with Enums (Sum Types), virtual methods, or explicit interfaces. In dynamic languages, replacing it with a strategy pattern or hash-map of known closures is the correct approach.
