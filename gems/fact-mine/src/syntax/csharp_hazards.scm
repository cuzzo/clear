(lock_statement) @hazard.csharp_concurrency

(
  (invocation_expression function: (member_access_expression expression: (identifier) @class name: (identifier) @method)) @hazard.csharp_concurrency
  (#match? @class "^(Task|ThreadPool|Parallel|Monitor|Interlocked|Volatile)$")
)

(
  (invocation_expression function: (member_access_expression expression: (member_access_expression expression: (identifier) @c1 name: (identifier) @c2) name: (identifier) @method)) @hazard.csharp_concurrency
  (#eq? @c1 "Task")
  (#eq? @c2 "Factory")
  (#eq? @method "StartNew")
)

(
  (object_creation_expression type: (identifier) @type) @hazard.csharp_concurrency
  (#eq? @type "Thread")
)

(
  (identifier) @hazard.csharp_concurrency
  (#match? @hazard.csharp_concurrency "^(ConcurrentDictionary|ConcurrentQueue|ConcurrentBag|BlockingCollection|SemaphoreSlim|Mutex|ReaderWriterLockSlim|SpinLock)$")
)

(unsafe_statement) @hazard.csharp_unsafe_memory
(fixed_statement) @hazard.csharp_unsafe_memory
(stackalloc_expression) @hazard.csharp_unsafe_memory

(
  (invocation_expression function: (member_access_expression expression: (identifier) @class)) @hazard.csharp_unsafe_memory
  (#match? @class "^(Marshal|Unsafe|MemoryMarshal)$")
)

(
  (identifier) @hazard.csharp_unsafe_memory
  (#match? @hazard.csharp_unsafe_memory "^(IntPtr|UIntPtr|GCHandle)$")
)

(pointer_type) @hazard.csharp_unsafe_memory

(
  (prefix_unary_expression) @hazard.csharp_unsafe_memory
  (#match? @hazard.csharp_unsafe_memory "^\\*")
)

;; Refined C# Metaprogramming queries for precision
(
  (invocation_expression
    function: (member_access_expression
      expression: (identifier) @recv_id
      name: (identifier) @method_name)) @hazard.csharp_metaprogramming
  (#match? @recv_id "^(?i)(Assembly|asm)$")
  (#match? @method_name "^(Load|LoadFrom|LoadFile)$")
)

(
  (invocation_expression
    function: (member_access_expression
      expression: (typeof_expression)
      name: (identifier) @method_name)) @hazard.csharp_metaprogramming
  (#match? @method_name "^(GetMethod|GetMethods|GetField|GetFields|GetProperty|GetProperties|GetConstructor|GetConstructors)$")
)

(
  (invocation_expression
    function: (member_access_expression
      expression: _ @recv
      name: (identifier) @method_name)) @hazard.csharp_metaprogramming
  (#match? @recv "^(?i).*(Type|t|typeof|clazz|class|declaringType).*$")
  (#match? @method_name "^(GetType|GetMethod|GetMethods|GetField|GetFields|GetProperty|GetProperties|GetConstructor|GetConstructors|CreateInstance)$")
)

(
  (invocation_expression
    function: (member_access_expression
      expression: _ @recv
      name: (identifier) @method_name)) @hazard.csharp_metaprogramming
  (#match? @recv "^(?i).*(Method|Field|Property|Constructor|info|mi|fi|pi|member).*$")
  (#match? @method_name "^(Invoke|GetValue|SetValue)$")
)

(
  (invocation_expression
    function: (member_access_expression
      expression: (identifier) @recv_id
      name: (identifier) @method_name)) @hazard.csharp_metaprogramming
  (#eq? @recv_id "Activator")
  (#eq? @method_name "CreateInstance")
)

(
  (identifier) @hazard.csharp_metaprogramming
  (#eq? @hazard.csharp_metaprogramming "dynamic")
)
