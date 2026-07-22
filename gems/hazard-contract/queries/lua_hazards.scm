(
  (function_call
    name: (identifier) @func_name
  ) @hazard.lua_metaprogramming
  (#match? @func_name "^(load|loadstring|loadfile|dofile|setmetatable|getmetatable|rawget|rawset|rawequal)$")
)

(
  (field
    name: (identifier) @key
  ) @hazard.lua_metaprogramming
  (#match? @key "^(__index|__newindex|__call)$")
)

(
  (dot_index_expression
    field: (identifier) @key
  ) @hazard.lua_metaprogramming
  (#match? @key "^(__index|__newindex|__call)$")
)
