(
  (call_expression
    function: (identifier) @func_name
  ) @hazard.javascript_metaprogramming
  (#eq? @func_name "eval")
)

(
  (new_expression
    constructor: (identifier) @constructor
  ) @hazard.javascript_metaprogramming
  (#match? @constructor "^(Function|Proxy)$")
)

(
  (call_expression
    function: (member_expression
      object: (identifier) @obj
      property: (property_identifier) @prop
    )
  ) @hazard.javascript_metaprogramming
  (#eq? @obj "Reflect")
  (#match? @prop "^(get|set|apply)$")
)
