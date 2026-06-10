# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"

module Annotator
  module Phases
    module ImportResolution
      extend T::Sig

      sig { params(node: AST::RequireNode).void }
      def visit_RequireNode(node)
        T.bind(self, SemanticAnnotator)
        importer = active_importer
        unless importer
          error!(node, :REQUIRE_NEEDS_IMPORTER)
        end

        importer = T.must(importer)
        mod = if node.kind == :package
          importer.compile_package(node.path, caller_dir: import_source_dir)
        else
          importer.compile_file(node.path, caller_dir: import_source_dir)
        end
        mod = T.must(mod)
        stamp_type!(node, :Void)

        same_dir = (node.kind != :package) && (mod.source_dir == import_source_dir)

        mod.global_scope.visible_entries.each do |name, entry|
          sig = entry.fn_signature
          next unless sig
          next if sig.module_alias

          vis = sig.visibility || :package
          importable = (vis == :pub) || (vis == :package && same_dir)
          next unless importable

          imported_sig = sig.dup
          imported_sig.module_alias = node.namespace
          current_scope.declare(name, nil, imported_sig, false, false, nil, :static)
        end

        mod.global_scope.types.each do |type_name, type_entry|
          schema = type_entry.schema
          vis = schema.visibility || :package
          next if vis == :private
          next unless (vis == :pub) || (vis == :package && same_dir)
          current_scope.declare_type(type_name, schema)
        end
        nil
      end
    end
  end
end
