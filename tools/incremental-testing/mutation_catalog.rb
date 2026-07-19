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

        replacement = case token.type
        when :INT64
          (token.integer! + 1).to_s
        when :NUMBER, :FLOAT32
          (token.float! + 1.0).to_s
        when :STRING
          value = token.text!
          if value.match?(/\A[A-Za-z]+\z/) && !value.empty?
            replacement_value = value.dup
            replacement_value.setbyte(0, value.getbyte(0) == 97 ? 98 : 97)
            "\"#{replacement_value}\""
          end
        end
        return nil unless replacement
        return nil unless replacement.bytesize == end_offset - start_offset

        Mutation.new(
          description: "replace #{token.type} at #{token.line}:#{token.column}",
          start_offset: start_offset,
          end_offset: end_offset,
          replacement: replacement,
        )
      end
    end
  end
end
