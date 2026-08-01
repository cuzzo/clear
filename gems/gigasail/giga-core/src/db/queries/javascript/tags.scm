(class_declaration name: (_) @name) @definition.class
(function_declaration name: (_) @name) @definition.function
(generator_function_declaration name: (_) @name) @definition.function
(method_definition name: (_) @name) @definition.function

(variable_declarator
  name: (_) @name
  value: [
    (arrow_function)
    (function_expression)
    (generator_function)
  ]) @definition.function

(variable_declarator
  name: (_) @name
  value: (class)) @definition.class

(field_definition
  [
    (property_identifier)
    (identifier)
    (private_property_identifier)
  ] @name
  value: [
    (arrow_function)
    (function_expression)
  ]) @definition.function
