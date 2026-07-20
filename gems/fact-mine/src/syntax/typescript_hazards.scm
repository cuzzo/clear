(
  (call_expression
    function: (identifier) @func_name
  ) @hazard.typescript_metaprogramming
  (#eq? @func_name "eval")
)

(
  (new_expression
    constructor: (identifier) @constructor
  ) @hazard.typescript_metaprogramming
  (#match? @constructor "^(Function|Proxy)$")
)

(
  (call_expression
    function: (member_expression
      object: (identifier) @obj
      property: (property_identifier) @prop
    )
  ) @hazard.typescript_metaprogramming
  (#eq? @obj "Reflect")
  (#match? @prop "^(get|set|apply)$")
)
