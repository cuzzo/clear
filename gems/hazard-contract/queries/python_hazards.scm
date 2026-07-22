(
  (call
    function: (identifier) @func_name
  ) @hazard.python_metaprogramming
  (#match? @func_name "^(getattr|setattr|delattr|hasattr|eval|exec)$")
)

(
  (call
    function: (identifier) @func_name
    arguments: (argument_list (_) (_) (_))
  ) @hazard.python_metaprogramming
  (#eq? @func_name "type")
)

(
  (function_definition
    name: (identifier) @method_name
  ) @hazard.python_metaprogramming
  (#match? @method_name "^(__getattr__|__getattribute__|__setattr__)$")
)
