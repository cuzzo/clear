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

(
  (invocation_expression
    function: (member_access_expression
      name: (identifier) @method_name)) @hazard.csharp_metaprogramming
  (#match? @method_name "^(Load|LoadFrom|LoadFile|GetType|GetMethod|GetMethods|GetField|GetFields|GetProperty|GetProperties|GetConstructor|GetConstructors|Invoke|GetValue|SetValue|CreateInstance)$")
)

(
  (identifier) @hazard.csharp_metaprogramming
  (#eq? @hazard.csharp_metaprogramming "dynamic")
)
