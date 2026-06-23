# frozen_string_literal: true

module Demo
  RawBody = T.type_alias { T::Array[AST::Node] }
  ScopeType = T.type_alias do
    T.any(Schemas::EnumSchema, Schemas::StructSchema)
  end
end
