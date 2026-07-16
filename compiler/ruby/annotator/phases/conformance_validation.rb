# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "conformance_registration"

module Annotator
  module Phases
    module ConformanceValidation
      extend T::Sig

      PROTOCOL_EFFECT_SUFFIXES = T.let({
        reentrant: "",
        reentrant_thunk: ":THUNK",
        reentrant_tail_call: ":TAIL_CALL",
        reentrant_not_logical: ":NOT_LOGICAL",
        reentrant_max_depth: ":MAX_DEPTH",
      }.freeze, T::Hash[Symbol, String])

      sig { params(resolutions: T::Array[ConformanceResolution]).void }
      def validate_conformances!(resolutions)
        T.bind(self, TypeAnalysisSession)

        resolutions.each do |resolution|
          failures = resolution.protocol.requirements.filter_map do |requirement|
            member = resolution.members[requirement.name]
            if member.nil?
              "#{requirement.name}: missing"
            else
              conformance_requirement_mismatch(requirement, member, resolution)
            end
          end
          extras = resolution.members.keys - resolution.protocol.requirements.map(&:name)
          failures.concat(extras.map { |name| "#{name}: not declared by #{resolution.protocol.name}" })
          next if failures.empty?

          error!(resolution.declaration, :CONFORMANCE_REQUIREMENTS,
            protocol: resolution.protocol.name, owner: resolution.owner_name, count: failures.length,
            details: failures.map { |failure| "\n  - #{failure}" }.join)
        end
      end

      sig do
        params(
          requirement: AST::ProtocolRequirement,
          member: AST::FunctionDef,
          resolution: ConformanceResolution,
        ).returns(T.nilable(String))
      end
      def conformance_requirement_mismatch(requirement, member, resolution)
        T.bind(self, TypeAnalysisSession)

        if requirement.is_method != member.is_method
          expected_kind = requirement.is_method ? "METHOD" : "FN"
          actual_kind = member.is_method ? "METHOD" : "FN"
          return "#{requirement.name}: expected #{expected_kind}, found #{actual_kind}"
        end
        if requirement.params.length != member.params.length
          return "#{requirement.name}: expected #{requirement.params.length} parameter(s), found #{member.params.length}"
        end

        substitutions = T.let(
          resolution.associated_types.merge(Self: resolution.declaration.owner_type),
          GenericAnalysis::GenericSubstitution,
        )
        requirement.params.each_with_index do |expected, index|
          actual = T.must(member.params[index])
          expected_type = apply_type_subst(expected.type, substitutions)
          if expected_type.semantic_type_key != actual.type.semantic_type_key ||
              expected.mutable != actual.mutable || expected.takes != actual.takes
            return "#{requirement.name}: parameter #{index + 1} is incompatible"
          end
        end
        expected_return = apply_type_subst(requirement.return_type, substitutions)
        actual_return = member.return_type || Type.new(:Void)
        unless expected_return.semantic_type_key == actual_return.semantic_type_key
          return "#{requirement.name}: expected RETURNS #{Type.surface_name(expected_return)}, " \
            "found #{Type.surface_name(actual_return)}"
        end

        actual_effect = member.reentrance_kind || member.effects_decl
        return nil if protocol_effect_accepts?(requirement.effects_decl, actual_effect)

        expected = requirement.effects_decl ? protocol_effect_name(T.must(requirement.effects_decl)) : "no reentrant effect"
        found = actual_effect ? protocol_effect_name(actual_effect) : "no reentrant effect"
        "#{requirement.name}: expected #{expected}, found #{found}"
      end
      private :conformance_requirement_mismatch

      sig { params(required: T.nilable(Symbol), actual: T.nilable(Symbol)).returns(T::Boolean) }
      def protocol_effect_accepts?(required, actual) = required == :reentrant ||
        (required.nil? ? actual.nil? : actual.nil? || actual == required)
      private :protocol_effect_accepts?

      sig { params(effect: Symbol).returns(String) }
      def protocol_effect_name(effect)
        suffix = PROTOCOL_EFFECT_SUFFIXES.fetch(effect, ":#{effect.to_s.upcase}")
        "EFFECTS REENTRANT#{suffix}"
      end
      private :protocol_effect_name
    end
  end
end
