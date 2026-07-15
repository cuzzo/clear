# typed: false

require "json"
require_relative "../../ruby/ast/parser"
require_relative "../../ruby/tools/formatter"

# Deliberately tiny portability seam for the frontend oracle POC. A self-hosted
# adapter only needs to implement these five methods and return plain hashes.
class RubyFrontendAdapter
  SEMANTIC_FIELDS = %i[
    full_type coerced_type symbol matched_signature matched_stdlib_def
    then_drops else_drops deferred_drops cleanup_plan mir_binding_entry
    token name_token arrow_token return_type_token
  ].freeze

  def tokens(source, file: "oracle.clear")
    Lexer.new(source, file: file).tokenize
  end

  def parse(source, file: "oracle.clear")
    budget = FrontendResourceBudget.new
    stream = Lexer.new(source, file: file, budget: budget).tokenize
    ClearParser.new(stream, source, budget: budget).parse
  end

  def format(source)
    Formatter.format(source)
  end

  def syntax_snapshot(source, ranges: true)
    @include_ranges = ranges
    JSON.pretty_generate(normalize(parse(source))) + "\n"
  end

  def diagnostic_snapshot(source)
    parse(source)
    { "class" => "none" }
  rescue Lexer::Error => error
    { "class" => error.class.name, "message" => error.message }
  rescue ParserError => error
    token = error.token
    {
      "class" => error.class.name,
      "message" => error.original_message,
      "file" => token&.file,
      "start" => token && [token.line, token.column, token.start_offset],
      "end" => token && [token.end_line, token.end_column, token.end_offset],
    }
  end

  private

  def normalize(value)
    case value
    when AST::Locatable
      fields = {}
      value.class.members.each do |member|
        next if SEMANTIC_FIELDS.include?(member)
        child = value[member]
        next if child.nil? || (child.is_a?(Array) && child.empty?) || child.equal?(false)
        fields[member.to_s] = normalize(child)
      end
      range = value.source_range
      head = { "node" => value.class.name.sub("AST::", "") }
      head["range"] = [range.start_offset, range.end_offset] if @include_ranges
      head.merge(fields)
    when Lexer::Token
      token = { "token" => value.type.to_s, "value" => value.value }
      token["range"] = [value.start_offset, value.end_offset] if @include_ranges
      token
    when Type
      { "type" => TypeExpressionPrinter.inline(value.shape.expression) }
    when TypeExpression
      { "type_syntax" => TypeExpressionPrinter.inline(value) }
    when Array
      value.map { |item| normalize(item) }
    when Hash
      value.keys.sort_by(&:to_s).to_h { |key| [key.to_s, normalize(value[key])] }
    when Struct
      value.class.members.each_with_object({}) do |member, fields|
        next if SEMANTIC_FIELDS.include?(member)
        child = value[member]
        next if child.nil? || (child.is_a?(Array) && child.empty?) || child.equal?(false)
        fields[member.to_s] = normalize(child)
      end
    when Symbol
      value.to_s
    else
      value
    end
  end
end
