# typed: strict

require "sorbet-runtime"
require "set"

require_relative "../ast/ast"

# Compatibility shell while the incorrect graph/provenance implementation is
# being deleted. This file must not grow new placement logic. The real
# replacement belongs in EscapeAnalysis as a small AST sink walker that writes
# only SymbolEntry#storage.
module EscapeGraph
  extend T::Sig
  module_function

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }

  sig { params(_fn_nodes: FnNodes, _schema_lookup: T.nilable(Proc)).returns([T::Set[String], T::Set[String]]) }
  def apply!(_fn_nodes, _schema_lookup = nil)
    Kernel.raise "EscapeGraph was intentionally deleted. Implement the simple " \
                 "AST-bound escape placement pass in src/mir/escape_analysis.rb; " \
                 "downstream graph/provenance placement is forbidden."
  end
end
