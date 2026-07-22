(method_invocation
  object: (identifier) @recv_id (#eq? @recv_id "Class")
  name: (identifier) @name (#eq? @name "forName")) @hazard.java_metaprogramming

(method_invocation
  object: (identifier) @recv_id (#eq? @recv_id "ClassLoader")
  name: (identifier) @name (#eq? @name "loadClass")) @hazard.java_metaprogramming

(method_invocation
  object: (identifier) @recv_id (#match? @recv_id "^(?i)(Proxy)$")
  name: (identifier) @name (#eq? @name "newProxyInstance")) @hazard.java_metaprogramming

(method_invocation
  object: [
    (method_invocation name: (identifier) @recv_method (#eq? @recv_method "getClass"))
    (field_access field: (identifier) @recv_field (#eq? @recv_field "class"))
    (identifier) @recv_id (#match? @recv_id "^(Class|Method|Constructor|Field|ClassLoader)$")
  ]
  name: (identifier) @name
  (#match? @name "^(getMethod|getDeclaredMethod|getField|getDeclaredField|getConstructor|getDeclaredConstructor|newInstance|invoke)$")) @hazard.java_metaprogramming

;; Candidate form for declared locals and aliases. The Rust consumer retains
;; this capture only when the receiver is resolved to a reflection framework
;; type; variable spelling is deliberately irrelevant.
(method_invocation
  object: (identifier) @typed_reflection_receiver
  name: (identifier) @typed_reflection_method
  (#match? @typed_reflection_method "^(forName|loadClass|getMethod|getDeclaredMethod|getField|getDeclaredField|getConstructor|getDeclaredConstructor|newInstance|invoke)$")) @hazard.java_metaprogramming
