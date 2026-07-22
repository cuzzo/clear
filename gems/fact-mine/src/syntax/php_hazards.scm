(function_call_expression
  function: (name) @func_name
  (#match? @func_name "^(eval|call_user_func|call_user_func_array|class_alias|create_function)$")) @hazard.php_metaprogramming

(object_creation_expression
  (name) @class_name
  (#match? @class_name "^(ReflectionClass|ReflectionMethod|ReflectionFunction|ReflectionProperty|ReflectionClassConstant)$")) @hazard.php_metaprogramming

(dynamic_variable_name) @hazard.php_metaprogramming

(method_declaration
  name: (name) @method_name
  (#match? @method_name "^(__get|__set|__call|__callStatic|__isset|__unset)$")) @hazard.php_metaprogramming
