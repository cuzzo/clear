(method_invocation
  object: (identifier) @recv_id (#match? @recv_id "^(?i)(Class|clazz)$")
  name: (identifier) @name (#eq? @name "forName")) @hazard.java_metaprogramming

(method_invocation
  object: (identifier) @recv_id (#match? @recv_id "^(?i)(ClassLoader|loader)$")
  name: (identifier) @name (#eq? @name "loadClass")) @hazard.java_metaprogramming

(method_invocation
  object: (identifier) @recv_id (#match? @recv_id "^(?i)(Proxy)$")
  name: (identifier) @name (#eq? @name "newProxyInstance")) @hazard.java_metaprogramming

(method_invocation
  object: [
    (method_invocation name: (identifier) @recv_method (#eq? @recv_method "getClass"))
    (field_access field: (identifier) @recv_field (#eq? @recv_field "class"))
    (identifier) @recv_id (#match? @recv_id "^(?i)(Class|Method|Constructor|Field|ClassLoader|clazz|method|constructor|field|loader)$")
  ]
  name: (identifier) @name
  (#match? @name "^(getMethod|getDeclaredMethod|getField|getDeclaredField|getConstructor|getDeclaredConstructor|newInstance|invoke)$")) @hazard.java_metaprogramming
