# typed: strict

require "sorbet-runtime"

# One budget may be threaded through lexing and parsing. Recursive frontend
# components use the same nesting counter, so moving grammar between lexer and
# parser cannot accidentally create an unbounded seam.
class FrontendResourceBudget
  extend T::Sig

  class Exceeded < StandardError
    extend T::Sig
    sig { returns(Symbol) }
    attr_reader :kind
    sig { returns(Integer) }
    attr_reader :limit

    sig { params(kind: Symbol, limit: Integer).void }
    def initialize(kind, limit)
      @kind = T.let(kind, Symbol)
      @limit = T.let(limit, Integer)
      super("frontend #{kind} budget exceeded (limit #{limit})")
    end
  end

  DEFAULT_MAX_NESTING = T.let(192, Integer)
  DEFAULT_MAX_TOKENS = T.let(1_000_000, Integer)
  DEFAULT_MAX_SOURCE_BYTES = T.let(32 * 1024 * 1024, Integer)

  sig { params(max_nesting: Integer, max_tokens: Integer, max_source_bytes: Integer).void }
  def initialize(max_nesting: DEFAULT_MAX_NESTING, max_tokens: DEFAULT_MAX_TOKENS,
                 max_source_bytes: DEFAULT_MAX_SOURCE_BYTES)
    @max_nesting = T.let(max_nesting, Integer)
    @max_tokens = T.let(max_tokens, Integer)
    @max_source_bytes = T.let(max_source_bytes, Integer)
    @nesting = T.let(0, Integer)
  end

  sig { params(source: String).void }
  def check_source!(source)
    raise Exceeded.new(:source_bytes, @max_source_bytes) if source.bytesize > @max_source_bytes
  end

  sig { params(count: Integer).void }
  def check_tokens!(count)
    raise Exceeded.new(:tokens, @max_tokens) if count > @max_tokens
  end

  sig { type_parameters(:Result).params(block: T.proc.returns(T.type_parameter(:Result))).returns(T.type_parameter(:Result)) }
  def nested(&block)
    @nesting += 1
    raise Exceeded.new(:nesting, @max_nesting) if @nesting > @max_nesting

    yield
  ensure
    @nesting -= 1
  end
end
