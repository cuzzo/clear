# typed: strict
# frozen_string_literal: true

require "digest"
require "json"
require "sorbet-runtime"
require "set"

require_relative "../../ast/ast"
require_relative "../helpers/function_signature"

module Annotator
  module Phases
    # Portable, caller-visible result of whole-program semantic finalization.
    # These facts deliberately exclude AST nodes, Type objects, scopes, and
    # registries so incremental caches and future workers can compare the
    # semantic contract without inspecting generated Zig.
    class DerivedFunctionFacts < T::Struct
      extend T::Sig

      const :name, String
      const :return_type_key, String
      const :needs_runtime, T::Boolean
      const :can_fail, T::Boolean
      const :allocation_fault, T::Boolean
      const :error_fallible, T::Boolean
      const :effects, T::Array[String]
      const :return_strategy, T.nilable(String)
      const :stack_tier, T.nilable(String)
      const :requires, T::Hash[String, T::Array[String]]
      const :heap_carry_return, T::Boolean
      const :reentrance_kind, T.nilable(String)

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        {
          "name" => name,
          "return_type_key" => return_type_key,
          "needs_runtime" => needs_runtime,
          "can_fail" => can_fail,
          "allocation_fault" => allocation_fault,
          "error_fallible" => error_fallible,
          "effects" => effects,
          "return_strategy" => return_strategy,
          "stack_tier" => stack_tier,
          "requires" => requires,
          "heap_carry_return" => heap_carry_return,
          "reentrance_kind" => reentrance_kind,
        }
      end

      sig { returns(String) }
      def fingerprint
        Digest::SHA256.hexdigest(JSON.generate(to_h))
      end
    end

    class DerivedProgramFacts
      extend T::Sig

      FunctionMap = T.type_alias { T::Hash[String, DerivedFunctionFacts] }

      sig { returns(FunctionMap) }
      attr_reader :functions

      sig { params(functions: FunctionMap).void }
      def initialize(functions:)
        @functions = T.let(functions.sort.to_h.freeze, FunctionMap)
        freeze
      end

      sig { returns(DerivedProgramFacts) }
      def self.empty
        new(functions: {})
      end

      sig { params(nodes: T::Hash[String, AST::FunctionDef]).returns(DerivedProgramFacts) }
      def self.capture(nodes)
        functions = T.let({}, FunctionMap)
        nodes.sort.each do |name, node|
          signature = FunctionSignature.unwrap(node.full_type!(context: "derived function facts for #{name}"))
          raise "missing finalized function signature for #{name}" unless signature

          functions[name] = capture_function(name, node, signature)
        end
        new(functions: functions)
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h
        { "functions" => functions.transform_values(&:to_h) }
      end

      class << self
        extend T::Sig

        private

        sig do
          params(
            name: String,
            node: AST::FunctionDef,
            signature: FunctionSignature,
          ).returns(DerivedFunctionFacts)
        end
        def capture_function(name, node, signature)
          requires = T.let({}, T::Hash[String, T::Array[String]])
          signature.requires.sort.each do |parameter, capabilities|
            requires[parameter] = capabilities.map(&:to_s).sort.freeze
          end

          DerivedFunctionFacts.new(
            name: name,
            return_type_key: signature.return_type.semantic_type_key,
            needs_runtime: signature.needs_rt == true,
            can_fail: signature.can_fail == true,
            allocation_fault: signature.alloc_fault == true,
            error_fallible: signature.error_fallible == true,
            effects: (signature.effects || Set.new).map(&:to_s).sort.freeze,
            return_strategy: signature.return_strategy&.to_s,
            stack_tier: signature.stack_tier&.to_s,
            requires: requires.freeze,
            heap_carry_return: signature.heap_carry_return == true,
            reentrance_kind: node.reentrance_kind&.to_s,
          ).freeze
        end
      end
    end
  end
end
