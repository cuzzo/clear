# typed: strict
require "sorbet-runtime"
require_relative "./lexer"

class ClearParser
  extend T::Sig

  class ParserRule < T::Struct
    const :type, Symbol
    const :value, T.nilable(String), default: nil
    const :action, Symbol
  end

  sig do
    params(
      type: Symbol,
      value: T.nilable(String),
      action: Symbol,
    ).returns(ParserRule)
  end
  def self.rule(type, value = nil, action:)
    ParserRule.new(type: type, value: value, action: action)
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
