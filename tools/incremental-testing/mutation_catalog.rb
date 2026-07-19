# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../compiler/ruby/ast/lexer"

module IncrementalTesting
  class Mutation < T::Struct
    extend T::Sig

    const :description, String
    const :start_offset, Integer
    const :end_offset, Integer
    const :replacement, String
    const :category, Symbol, default: :literal

    sig { params(source: String).returns(String) }
    def apply(source)
      prefix = source.byteslice(0...start_offset) || ""
      suffix = source.byteslice(end_offset..-1) || ""
      prefix + replacement + suffix
    end
  end

  class MutationCatalog
    extend T::Sig

    sig { params(source: String, limit: Integer).returns(T::Array[Mutation]) }
    def self.literal_mutations(source, limit:)
      Lexer.new(source).tokenize.filter_map do |token|
        mutation = mutation_for(token)
        mutation if mutation&.category == :literal
      end.first(limit)
    end

    sig { params(source: String, limit: Integer).returns(T::Array[Mutation]) }
    def self.mutations(source, limit:)
      Lexer.new(source).tokenize.filter_map do |token|
        mutation_for(token)
      end.first(limit)
    end

    class << self
      extend T::Sig

      private

      sig { params(token: Lexer::Token).returns(T.nilable(Mutation)) }
      def mutation_for(token)
        start_offset = token.start_offset
        end_offset = token.end_offset
        return nil unless start_offset && end_offset

        replacement, category = case token.type
        when :INT64
          [(token.integer! + 1).to_s, :literal]
        when :NUMBER, :FLOAT32
          [(token.float! + 1.0).to_s, :literal]
        when :STRING
          value = token.text!
          if value.match?(/\A[A-Za-z]+\z/) && !value.empty?
            replacement_value = value.dup
            replacement_value.setbyte(0, value.getbyte(0) == 97 ? 98 : 97)
            ["\"#{replacement_value}\"", :literal]
          end
        when :KEYWORD
          case token.value
          when "TRUE" then ["FALSE", :boolean]
          when "FALSE" then ["TRUE", :boolean]
          end
        when :CHAR
          {
            "+" => "-", "-" => "+",
            "<" => ">", ">" => "<",
            "<=" => ">=", ">=" => "<=",
            "==" => "!=", "!=" => "==",
          }[token.value]&.then { |operator| [operator, :operator] }
        end
        return nil unless replacement

        Mutation.new(
          description: "replace #{token.type} at #{token.line}:#{token.column}",
          start_offset: start_offset,
          end_offset: end_offset,
          replacement: replacement,
          category: category || :literal,
        )
      end
    end
  end
end
