(call_expression
  (simple_identifier) @name
  (#match? @name "^(NSClassFromString|performSelector|objc_msgSend|class_getInstanceMethod|Mirror)$")) @hazard.swift_metaprogramming

(navigation_suffix
  (simple_identifier) @name
  (#match? @name "^(performSelector|class_getInstanceMethod)$")) @hazard.swift_metaprogramming
