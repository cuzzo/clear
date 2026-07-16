# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../ast/ast"

module Annotator
  class ProtocolProjectionIssue < T::Struct
    const :code, Symbol
    const :arguments, T::Hash[Symbol, String]
  end

  class ProtocolProjectionResult < T::Struct
    const :expression, TypeExpression
    const :issues, T::Array[ProtocolProjectionIssue]
  end

  # Resolves `T::Item` against T's declared protocol bounds without depending
  # on a traversal session. Declaration registration and function-body typing
  # therefore use exactly the same ambiguity and availability rules.
  class ProtocolProjectionResolver
    extend T::Sig

    sig { params(protocols: T::Hash[String, AST::ProtocolDef]).void }
    def initialize(protocols)
      @protocols = T.let(protocols, T::Hash[String, AST::ProtocolDef])
    end

    sig do
      params(
        expression: TypeExpression,
        parameters: T::Array[AST::GenericParamDecl],
      ).returns(ProtocolProjectionResult)
    end
    def resolve(expression, parameters)
      issues = T.let([], T::Array[ProtocolProjectionIssue])
      parameter_map = parameters.to_h { |parameter| [parameter.name.to_sym, parameter] }
      resolved = TypeExpressionTree.transform(expression) do |candidate|
        next candidate unless candidate.is_a?(TypeProjectionExpression)
        next candidate if candidate.protocol

        protocol = projection_protocol(candidate, parameter_map, issues)
        next candidate unless protocol

        TypeProjectionExpression.new(
          owner: candidate.owner,
          member: candidate.member,
          protocol: protocol.to_sym,
          capabilities: candidate.capabilities,
        )
      end
      ProtocolProjectionResult.new(expression: resolved, issues: issues)
    end

    private

    sig do
      params(
        projection: TypeProjectionExpression,
        parameters: T::Hash[Symbol, AST::GenericParamDecl],
        issues: T::Array[ProtocolProjectionIssue],
      ).returns(T.nilable(String))
    end
    def projection_protocol(projection, parameters, issues)
      parameter = parameters[projection.owner]
      unless parameter
        issues << issue(:GENERIC_PROJECTION_UNKNOWN_OWNER,
          owner: projection.owner, member: projection.member)
        return nil
      end

      bounds = parameter.bounds.map { |bound| protocol_base_name(bound.type) }
      if bounds.empty?
        suggestions = all_protocol_names.select do |name|
          associated_types(name).include?(projection.member)
        end
        suggested = suggestions.length == 1 ? T.must(suggestions.first) : "a protocol declaring #{projection.member}"
        issues << issue(:GENERIC_PROJECTION_NEEDS_PROTOCOL,
          owner: projection.owner, member: projection.member, protocol: suggested)
        return nil
      end

      matching = bounds.select { |name| associated_types(name).include?(projection.member) }
      if matching.empty?
        available = bounds.flat_map { |name| associated_types(name) }.uniq
        issues << issue(:GENERIC_UNKNOWN_ASSOCIATED_TYPE,
          owner: projection.owner, member: projection.member,
          protocol: bounds.join(" & "), available: available.empty? ? "none" : available.join(", "))
        return nil
      end
      if matching.length > 1
        issues << issue(:GENERIC_AMBIGUOUS_ASSOCIATED_TYPE,
          owner: projection.owner, member: projection.member, protocols: matching.join(", "))
        return nil
      end
      matching.first
    end

    sig { params(code: Symbol, values: T.untyped).returns(ProtocolProjectionIssue) }
    def issue(code, **values)
      ProtocolProjectionIssue.new(
        code: code,
        arguments: values.transform_values(&:to_s),
      )
    end

    sig { returns(T::Array[String]) }
    def all_protocol_names
      ["Map"] + @protocols.keys
    end

    sig { params(name: String).returns(T::Array[Symbol]) }
    def associated_types(name)
      return %i[Key Value] if name == "Map"

      protocol = @protocols[name]
      protocol ? protocol.associated_types.map { |type| type.name.to_sym } : []
    end

    sig { params(type: Type).returns(String) }
    def protocol_base_name(type)
      (type.generic_instance? ? type.generic_base : type.resolved).to_s
    end
  end
end
