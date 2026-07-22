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

;; Reflection queries deliberately use API-shaped expressions. Receiver-name
;; guesses such as `t`, `clazz`, `.*info`, and `.*method` are not provenance:
;; they flag ordinary user objects and miss renamed real reflection values.
;; The broad name-based rules were removed; callers should use a typed
;; interface or an explicit allowlist when the receiver is not syntactically
;; one of these framework types.
(
  (invocation_expression
    function: (member_access_expression
      expression: (identifier) @assembly_type
      name: (identifier) @method_name)) @hazard.csharp_metaprogramming
  (#eq? @assembly_type "Assembly")
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
      expression: (identifier) @reflection_type
      name: (identifier) @method_name)) @hazard.csharp_metaprogramming
  (#match? @reflection_type "^(Type|MethodInfo|FieldInfo|PropertyInfo|ConstructorInfo|Assembly)$")
  (#match? @method_name "^(GetType|GetMethod|GetMethods|GetField|GetFields|GetProperty|GetProperties|GetConstructor|GetConstructors|CreateInstance)$")
)

;; Fully qualified framework type names are nested member-access expressions.
;; Keep the namespace/type pair explicit so an arbitrary `Foo.Type` is not
;; treated as System.Type provenance.
(
  (invocation_expression
    function: (member_access_expression
      expression: (member_access_expression
        expression: (identifier) @reflection_namespace
        name: (identifier) @qualified_reflection_type)
      name: (identifier) @qualified_method_name)) @hazard.csharp_metaprogramming
  (#eq? @reflection_namespace "System")
  (#eq? @qualified_reflection_type "Type")
  (#eq? @qualified_method_name "GetType")
)

(
  (invocation_expression
    function: (member_access_expression
      expression: (identifier) @member_info_type
      name: (identifier) @method_name)) @hazard.csharp_metaprogramming
  (#match? @member_info_type "^(MethodInfo|FieldInfo|PropertyInfo|ConstructorInfo|MemberInfo)$")
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

;; A `dynamic` declaration is ordinary syntax. The Rust consumer retains this
;; capture only when the receiver identifier is declared dynamic in scope.
(
  (invocation_expression
    function: (member_access_expression
      expression: (identifier) @dynamic_receiver
      name: (identifier) @dynamic_method)) @hazard.csharp_dynamic_dispatch
)
