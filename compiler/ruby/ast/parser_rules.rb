# typed: strict
require "sorbet-runtime"
require_relative "./lexer"

class ClearParser
  extend T::Sig

  class PatternStep < T::Struct
    const :kind, Symbol
    const :value, T.untyped, default: nil
    const :action, T.nilable(Symbol), default: nil
  end

  class ParserRule < T::Struct
    const :type, Symbol
    const :value, T.nilable(String), default: nil
    const :action, Symbol
    const :pattern, T::Array[PatternStep], default: []
    const :inject, T::Array[T.untyped], default: []
  end

  Pattern = T.type_alias { T::Array[PatternStep] }

  sig do
    params(
      type: Symbol,
      value: T.nilable(String),
      action: Symbol,
      pattern: T::Array[PatternStep],
      inject: T::Array[T.untyped],
    ).returns(ParserRule)
  end
  def self.rule(type, value = nil, action:, pattern: [], inject: [])
    ParserRule.new(type: type, value: value, action: action, pattern: pattern, inject: inject)
  end

  sig { params(value: String).returns(PatternStep) }
  def self.lit(value)
    PatternStep.new(kind: :literal, value: value)
  end

  sig { params(action: Symbol).returns(PatternStep) }
  def self.capture(action)
    PatternStep.new(kind: :capture, action: action)
  end

  sig { params(trigger: String, action: Symbol).returns(PatternStep) }
  def self.optional_capture(trigger, action)
    PatternStep.new(kind: :optional_capture, value: trigger, action: action)
  end

  sig { params(type: Symbol, value: T.nilable(String)).returns(String) }
  def self.rule_key(type, value)
    type.to_s + "\0" + (value || "\1")
  end

  sig { params(token: Lexer::Token).returns(String) }
  def self.token_rule_key(token)
    value = token.value
    return rule_key(token.type, value) if value.is_a?(String)

    rule_key(token.type, nil)
  end

  sig { params(rules: T::Array[ParserRule]).returns(T::Hash[String, ParserRule]) }
  def self.index_rules(rules)
    index = T.let({}, T::Hash[String, ParserRule])
    rules.each do |rule|
      key = rule_key(rule.type, rule.value)
      raise "Duplicate parser rule for #{key}" if index.key?(key)

      index[key] = rule
    end
    index.freeze
  end
end
