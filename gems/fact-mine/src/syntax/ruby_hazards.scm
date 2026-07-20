(
  (call
    method: (identifier) @method_name
  ) @hazard.ruby_metaprogramming
  (#match? @method_name "^(send|public_send|instance_variable_get|instance_variable_set|class_variable_get|class_variable_set|define_method|undef_method|remove_method|eval|class_eval|module_eval|instance_eval|const_get|const_set)$")
)

(
  (method
    name: (identifier) @method_name
  ) @hazard.ruby_metaprogramming
  (#match? @method_name "^(method_missing|respond_to_missing\?)$")
)

(
  (global_variable) @hazard.ruby_metaprogramming
  (#match? @hazard.ruby_metaprogramming "^\\$([1-9]|~|&|\\+)$")
)
