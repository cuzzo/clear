# Function Pointer & Callback Hazard Detection Gaps

This document identifies the known gaps in the unified callback/FP hazard detection system implemented in `fact-mine`. It describes cases where dynamic callback or function pointer invocations can bypass the detector, their frequency in real-world codebases, and recommendations for future mitigations.

---

## Summary of Current Detection Rules

To understand the gaps, it helps to review what the detector **does** catch:
1. **Direct Parameter Calls**: `cb()` or `fp()` where the target is a declared parameter or callback parameter of the enclosing function.
2. **Explicit Callback Dispatches on Parameters**: `cb.call()` or `listener.onEvent()` where the receiver is a parameter, and the call is either a standard invoker (`call`, `invoke`, `apply`, `run`, `perform`) or the parameter's name/type matches callback heuristics.
3. **Local Variable Function Invocations**: Local variables with explicit function types (e.g., containing `fn`, `func`, `->`, or `function`).
4. **Complex Targets**: Direct invocations of complex expressions (containing `[`, `(`, `*`, `->`) such as `arr[10]()`, `(*fp)()`, and parenthesized expressions `(foo.bar.baz)()`.

---

## Known Gaps

### 1. Unparenthesized Nested Callback Members (`foo.bar.baz()`)
* **Description**: A callback is stored as a nested member of a struct, class, or object, and is called directly as a member method.
* **Examples**:
  * **C**: `foo.bar.baz()` (where `baz` is a function pointer member).
  * **Python/JS**: `self.config.on_error()` (where `on_error` is a callback).
* **Why it is missed**: The receiver is `"foo.bar"` or `"self.config"`, which does not match a simple parameter identifier in the parameters list.
* **Prevalence**: 
  * **C**: **High**. Since C lacks object-oriented methods, *every* member invocation of this form is a function pointer call.
  * **Rust/JS/TS/Python**: **Medium**. Usually, nested configuration objects are resolved to local variables before call, but direct chaining is common.
* **Mitigation**:
  * For C: Flag any member call where the receiver is not empty/self/this.
  * For OOP languages: Trace type definitions or resolve nested member paths in the receiver to check if the leaf field is a callback.

---

### 2. Collection Iteration Dispatches (`listeners.each { |l| l.on_event }`)
* **Description**: The callback parameter is a collection (array, list, map) of callbacks. The code iterates over the collection and invokes each callback.
* **Examples**:
  ```ruby
  # Ruby
  def notify_all(listeners)
    listeners.each { |l| l.on_event }
  end
  ```
  ```rust
  // Rust
  fn notify_all(callbacks: &[fn()]) {
      for cb in callbacks {
          cb();
      }
  }
  ```
* **Why it is missed**: 
  * In the Ruby example, `l` is a block variable, not a parameter of the method `notify_all`.
  * **Ruby Static Ambiguity**: In Ruby, it is statically impossible to determine whether `l.on_event` represents a variable lookup, a safe field access, or a dynamic function call due to Ruby's implicit method call receiver design and dynamic typing.
  * In the Rust example, `cb` is a loop variable. Unless type inference successfully publishes the function type to the local scope of `cb`, the direct call `cb()` is not recognized as a parameter call.
* **Prevalence**: **High** in event-driven systems, observers, and pub-sub architectures.
* **Mitigation**: 
  * In Ruby, we can **cross-reference nil-kill runtime profile databases** (or Lineage trace databases) to resolve type info at runtime and detect dynamic dispatches.
  * Track local variables assigned from parameter iterations or collections.
  * If a parameter name or type suggests it is a collection of callbacks (e.g., `listeners`, `callbacks`), flag iterations or element accesses on it.

---

### 3. Local Variable Aliasing and Untyped Assignments
* **Description**: A callback parameter or function pointer is assigned to a local variable (potentially through multiple hops or intermediate functions) before being called.
* **Examples**:
  ```go
  // Go
  func test(cb func()) {
      my_cb := cb
      my_cb() // Missed if type-inference does not resolve my_cb's type name
  }
  ```
* **Why it is missed**: The call is made on `my_cb`, which is not in the parameter list. If local type-inference doesn't explicitly publish that `my_cb` has a function signature type (e.g. in dynamic languages or weak type environments), the local type check fails.
* **Feasibility & Implementation Complexity**: **Low-Medium**. Since `fact-mine` already generates local dataflow facts (see `local_flow.rs` and `fact_oracle.rs`), we can query the local dataflow graph (DFG) to trace local variable assignments back to parameters. Tracing reachability from a call receiver back to parameter nodes is a basic reachability lookup on the existing local DFG.
* **Prevalence**: **Low-Medium**. Re-binding parameters is generally discouraged but happens in wrapper methods.
* **Mitigation**: Enhance local data-flow tracking to propagate the "callback/FP origin" state along local assignment edges.

---

### 4. Indirect Library Passes (Callbacks passed but not called)
* **Description**: A callback parameter is passed directly into a standard library or external dependency function, which executes the callback asynchronously or internally.
* **Examples**:
  ```java
  // Java
  public void runLater(Runnable cb) {
      this.executor.submit(cb); // cb is passed, but never called directly in this method
  }
  ```
* **Status**: **Acceptable**. This pattern represents consuming/passing an interface rather than direct dynamic execution of arbitrary function pointers inside the function itself, which is considered safe for our current hazard model.
* **Prevalence**: **High** in concurrent and asynchronous frameworks.

---

### 5. C++ Functors / Operator Overloads (`cb()`)
* **Description**: A parameter is a C++ class instance that overloads `operator()`. Calling `cb()` invokes the overloaded operator.
* **Examples**:
  ```cpp
  // C++
  struct MyFunctor {
      void operator()() { ... }
  };
  void test(MyFunctor cb) {
      cb(); // Invokes operator()
  }
  ```
* **Status**: **Acceptable**. This represents a standard C++ method overload resolution pattern rather than dynamic function pointer invocation, and is considered outside the scope of callback/FP hazards.
* **Prevalence**: **Medium** in template-heavy C++ codebases.
