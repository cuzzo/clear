(class_declaration name: (_) @name) @definition.class
(abstract_class_declaration name: (_) @name) @definition.class
(interface_declaration name: (_) @name) @definition.class
(type_alias_declaration name: (_) @name) @definition.class
(enum_declaration name: (_) @name) @definition.class

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

(public_field_definition
  name: (_) @name
  value: [
    (arrow_function)
    (function_expression)
  ]) @definition.function
