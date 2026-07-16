# typed: strict

require "sorbet-runtime"

# Parser-owned, immutable type syntax. Semantic Type construction is performed
# by TypeSyntaxLowering after parsing and budget validation. TypeExpression is
# already the structural, capability-per-layer tree used by both accepted
# source syntaxes; this wrapper prevents parser APIs from leaking mutable Type.
class ParsedTypeSyntax < T::Struct
  const :expression, TypeExpression
  const :start_token, Lexer::Token
  const :end_token, Lexer::Token
  const :auto_token, T.nilable(Lexer::Token), default: nil
  const :auto, T::Boolean, default: false
end

class TypeSyntaxLowering
  extend T::Sig

  sig { params(syntax: ParsedTypeSyntax).returns(Type) }
  def self.lower(syntax)
    lowered = Type.new(syntax.expression, auto: syntax.auto)
    lowered.auto_token = syntax.auto_token if syntax.auto_token
    lowered
  end
end
