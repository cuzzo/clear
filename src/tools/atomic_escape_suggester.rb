# typed: strict
require_relative "../ast/lexer"
require_relative "../ast/parser"
require_relative "../annotator"
require_relative "../ast/fixable_error"

# Doctor-side static detector for atomic escape patterns. The compiler already
# rejects code that captures `@shared:atomic` into a destination outliving its
# declaring scope
# (long-lived queue push, struct-field store, RETURN without
# `RETURNS x:T`). This tool runs the annotator with `FixCollector`
# enabled, drains the resulting `:escape`-category findings, and
# returns them in a doctor-friendly shape so `clear doctor` can
# explain the rejection in plain language and suggest `@shared:locked`
# alongside lock-profile output.
#
# Returns Array of finding hashes:
#   { line:, col:, message:, kind: :return | :store }
# Empty when the source compiles cleanly (no atomic-escape errors).
# Empty on parse error too -- the caller falls back to its existing
# diagnosis stream.
module AtomicEscapeSuggester

  def self.analyze(source)
    tokens = Lexer.new(source).tokenize
    ast    = ClearParser.new(tokens, source).parse
    ann    = SemanticAnnotator.new
    ann.source_code = source

    FixCollector.enable!
    begin
      ann.annotate!(ast)
    rescue StandardError
      # Collector mode captures findings even when the annotator
      # raises after recording the first fatal one; drain what we
      # have. The annotator's flow is "raise on first :error in
      # non-collector mode, but raise_in_collector: true for the
      # fixables may still raise in collector mode after pushing the finding,
      # so the finding is available when we land here.
    end
    findings = FixCollector.drain
    FixCollector.disable!

    findings
      .select { |f| f.category == :escape }
      .map { |f| to_hash(f) }
  rescue StandardError
    FixCollector.disable!
    []
  end

  def self.to_hash(finding)
    msg = finding.message.to_s
    kind =
      if msg.include?("RETURN")
        :return
      else
        :store
      end
    {
      line:    finding.token&.line,
      col:     finding.token&.column,
      message: msg,
      kind:    kind,
    }
  end
end
