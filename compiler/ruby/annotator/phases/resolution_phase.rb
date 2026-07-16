# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "set"

require_relative "../../ast/source_error"
require_relative "../../ast/std_lib"
require_relative "../../compiler/module_importer"
require_relative "annotation_products"
require_relative "builtin_environment"
require_relative "import_resolution"
require_relative "signature_registration"
require_relative "type_registration"

module Annotator
  module Phases
    # Mutable state exists only for the duration of resolution.  It is not
    # installed on SemanticAnnotator and is unreachable after ResolutionFacts
    # is published, except through the deliberately exported scope/registry.
    class ResolutionSession
      extend T::Sig

      BUILTIN_TYPE_PARAMETER_NAMES = %i[Number Bool Byte Int64 Float64 String Any Void Range].freeze

      include ErrorHelper
      include ScopeHelper
      include BuiltinEnvironment
      include ImportResolution
      include SignatureRegistration
      include TypeRegistration

      sig { override.returns(T.nilable(String)) }
      attr_reader :source_code
      sig { returns(Scope) }
      attr_reader :root_scope
      sig { returns(Annotator::FunctionRegistry) }
      attr_reader :function_registry

      sig do
        params(
          importer: T.nilable(ModuleImporter),
          source_dir: String,
          source_code: T.nilable(String),
          root_scope: T.nilable(Scope),
          function_registry: T.nilable(Annotator::FunctionRegistry),
          install_builtins: T::Boolean
        ).void
      end
      def initialize(importer:, source_dir:, source_code:, root_scope: nil, function_registry: nil, install_builtins: true)
        @importer = T.let(importer, T.nilable(ModuleImporter))
        @source_dir = T.let(source_dir, String)
        @source_code = T.let(source_code, T.nilable(String))
        @root_scope = T.let(root_scope || Scope.new, Scope)
        @scope_stack = T.let([@root_scope], T::Array[Scope])
        @function_registry = T.let(function_registry || Annotator::FunctionRegistry.new, Annotator::FunctionRegistry)
        initialize_builtin_environment! if install_builtins
      end

      sig { override.returns(T::Array[Scope]) }
      def scope_stack
        @scope_stack
      end

      sig { returns(T.nilable(ModuleImporter)) }
      def active_importer
        @importer
      end

      sig { returns(String) }
      def import_source_dir
        @source_dir
      end

      sig do
        type_parameters(:Stamp)
          .params(node: AST::Locatable, value: T.type_parameter(:Stamp))
          .returns(T.type_parameter(:Stamp))
      end
      def stamp_type!(node, value)
        case value
        when nil
          raise "resolution stamp missing type for #{node.class}"
        end
        node.full_type = T.cast(value, AST::SyntheticTypeInput)
        node.full_type!(context: "resolution stamp")
        value
      end

      sig { returns(T::Array[AST::FunctionDef]) }
      def synthetic_function_definitions
        @function_registry.synthetic_definitions
      end

      sig { void }
      def clear_synthetic_function_definitions!
        @function_registry.clear_synthetic_definitions!
      end

      sig { params(node: AST::FunctionDef).returns(AST::FunctionDef) }
      def queue_synthetic_function!(node)
        @function_registry.add_synthetic_definition!(node)
      end

      sig { params(node: T.any(AST::StructDef, AST::UnionDef), type_params: T::Array[String], kind: String).void }
      def validate_type_param_list!(node, type_params, kind)
        seen = T.let(Set.new, T::Set[Symbol])
        type_params.each do |param|
          name = param.to_sym
          error!(node, :GENERIC_DUP_TYPE_PARAM_KIND, param: param, kind: kind, name: node.name) if seen.include?(name)
          error!(node, :GENERIC_TYPE_PARAM_SHADOWS, param: param) if BUILTIN_TYPE_PARAMETER_NAMES.include?(name)
          seen.add(name)
        end
      end

      sig { params(node: AST::FunctionDef).returns(T.nilable(String)) }
      def get_lifetime_path(node)
        lifetime = node.return_lifetime
        return nil if lifetime.nil? || lifetime == :wildcard
        sources = lifetime.is_a?(Array) ? lifetime : [lifetime]
        paths = sources.filter_map do |source|
          next unless source.respond_to?(:token)
          path = @root_scope.get_path_to_root(T.cast(source, AST::Node))
          path.join(".") unless path.empty?
        end
        paths.length == 1 ? paths.first : nil
      end

      sig { params(value: T.any(Type, Symbol, String)).returns(Type) }
      def to_type(value)
        value.is_a?(Type) ? value : Type.new(value)
      end

      sig { params(node: AST::UnionDef).void }
      def validate_union_methods!(node)
        requirements = T.cast(node.methods || [], T::Array[AST::UnionMethodRequirement])
        seen = T.let(Set.new, T::Set[String])
        requirements.each do |requirement|
          error!(requirement.token, :UNION_METHOD_DUPLICATE, union: node.name, method: requirement.name) if seen.include?(requirement.name)
          seen.add(requirement.name)
        end

        requirements.each { |requirement| validate_union_method!(node, requirement) }
      end

      sig { params(node: TypeDeclaration).void }
      def register_local_type_declaration(node)
        register_type_declaration(node)
      end

      sig { params(node: AST::ExternFnDecl).void }
      def register_local_extern_declaration(node)
        register_extern_function_signature(node)
      end

      private

      sig { params(node: AST::UnionDef, requirement: AST::UnionMethodRequirement).void }
      def validate_union_method!(node, requirement)
        entry = lookup_scope_for(requirement.name)&.resolve_entry(requirement.name)
        unless entry
          if requirement.has_default_body
            queue_synthetic_function!(AST::FunctionDef.new(
              requirement.token, requirement.name, requirement.params.map(&:to_param), [], requirement.return_type,
              nil, requirement.body, nil, nil, requirement.visibility, nil, nil
            ))
            return
          end
          error!(requirement.token, :UNION_METHOD_MISSING, union: node.name, method: requirement.name, fn: requirement.name)
        end

        signature = FunctionSignature.unwrap(entry.type)
        error!(requirement.token, :UNION_METHOD_MISSING, union: node.name, method: requirement.name, fn: requirement.name) unless signature
        validate_union_method_visibility!(node, requirement, signature)
        if requirement.params.length != signature.params.length
          error!(requirement.token, :UNION_METHOD_WRONG_ARITY, union: node.name, method: requirement.name,
            expected_arity: requirement.params.length, fn: requirement.name, got_arity: signature.params.length)
        end
        requirement.params.each_with_index do |param, index|
          actual = signature.params[index]
          next unless actual
          expected_name = to_type(param.type).resolved
          actual_name = to_type(actual[:type]).resolved
          next if expected_name == actual_name || expected_name == :Any || actual_name == :Any
          error!(requirement.token, :UNION_METHOD_PARAM_TYPE, union: node.name, method: requirement.name,
            index: index + 1, expected: expected_name, fn: requirement.name, got: actual_name)
        end
        return_type = requirement.return_type
        return unless return_type
        expected_return = to_type(return_type).resolved
        actual_return = signature.return_type.resolved
        return if expected_return == actual_return || expected_return == :Any || actual_return == :Any
        error!(requirement.token, :UNION_METHOD_RETURN_TYPE, union: node.name, method: requirement.name,
          expected: expected_return, fn: requirement.name, got: actual_return)
      end

      sig do
        params(
          node: AST::UnionDef,
          requirement: AST::UnionMethodRequirement,
          signature: FunctionSignature
        ).void
      end
      def validate_union_method_visibility!(node, requirement, signature)
        return if requirement.visibility == :package
        actual = signature.visibility || :package
        return if actual == requirement.visibility
        labels = { pub: "PUB", private: "PRIVATE", package: "package" }
        error!(requirement.token, :UNION_METHOD_WRONG_VISIBILITY, union: node.name, method: requirement.name,
          declared_vis: labels[requirement.visibility], fn: requirement.name, fn_vis: labels[actual])
      end
    end

    class ResolutionPhase
      extend T::Sig

      sig do
        params(
          program: AST::Program,
          importer: T.nilable(ModuleImporter),
          source_dir: String,
          source_code: T.nilable(String)
        ).returns(ResolutionFacts)
      end
      def self.run(program:, importer:, source_dir:, source_code:)
        session = ResolutionSession.new(importer: importer, source_dir: source_dir, source_code: source_code)
        declarations = DeclarationIndexer.index(program)

        declarations.imports.each { |node| session.visit_RequireNode(node) }
        session.register_type_declarations(declarations)
        session.register_program_signatures(declarations)

        root_scope = session.root_scope
        function_registry = session.function_registry

        ResolutionFacts.new(
          program: program,
          declarations: declarations,
          root_scope: root_scope,
          function_registry: function_registry,
          type_names: root_scope.types.keys,
          function_names: resolved_function_names(root_scope)
        )
      end

      sig { params(root_scope: Scope).returns(T::Array[String]) }
      def self.resolved_function_names(root_scope)
        root_scope.visible_entries.each_with_object(T.let([], T::Array[String])) do |(name, entry), names|
          names << name if entry.fn_signature
        end
      end
      private_class_method :resolved_function_names
    end
  end
end
