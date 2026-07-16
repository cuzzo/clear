# typed: strict
require_relative "analysis_result"
require_relative "../backends/transpiler"  # loads Lexer, ClearParser, SemanticAnnotator, FixCollector

module LSP
  # Runs the canonical CLEAR compiler frontend on a source string and
  # returns the captured FixableFindings (plus any unrecoverable
  # CompilerError/ParserError as a synthetic finding so the client
  # still sees a diagnostic).
  #
  # Mirrors the `run_compiler_and_drain` lambda in `bin/clear` (used
  # by `clear fix`) — the LSP and the CLI take exactly the same
  # analysis path so behaviour stays consistent.
  #
  # FixCollector is module-global state. The Server serialises
  # `Analyzer.run` calls behind a mutex so concurrent analyses don't
  # interleave their findings.
  module Analyzer
    extend T::Sig
    # Pseudo-token shape used when we can't extract a real token from
    # a raised CompilerError/ParserError (synthetic frontend errors,
    # EOF errors, etc.). Exposes the fields Diagnostics expects.
    SyntheticToken = Struct.new(:line, :column, :value, keyword_init: true)

    # Result of one analysis pass.
    # Run the lexer, parser, and annotator on `source`. Returns a
    # Result with the FixCollector findings and an optional
    # `fatal_error` (a synthetic FixableFinding) if the parser or
    # annotator raised.
    sig { params(source: String).returns(LSP::AnalysisResult) }
    def self.run(source)
      FixCollector.enable!
      findings = []
      fatal = nil
      begin
        tokens    = Lexer.new(source).tokenize
        ast       = ClearParser.new(tokens, source).parse
        annotator = SemanticAnnotator.new(source_code: source)
        annotator.annotate!(ast)
      rescue CompilerError, ParserError => e
        fatal = synthetic_finding_from(e)
      rescue => e
        # Lexer / unforeseen errors. Don't lose them — surface as a
        # generic synthetic diagnostic at line 1 col 1.
        fatal = SyntheticFinding.new(
          level: :error,
          message: "Internal compiler error: #{e.class}: #{e.message}",
          token: SyntheticToken.new(line: 1, column: 1, value: ""),
          category: :type,
          fixes: [],
        )
      ensure
        findings = FixCollector.drain
        FixCollector.disable!
      end
      LSP::AnalysisResult.new(findings: findings, fatal_error: fatal)
    end

    # Internals --------------------------------------------------

    # Lightweight stand-in for FixableFinding so the Diagnostics
    # converter can treat both uniformly. Has the same surface
    # (level, message, token, category, fixes).
    SyntheticFinding = Struct.new(:level, :message, :token, :category, :fixes, keyword_init: true) do
      extend T::Sig
      sig { returns(T.any(Lexer::Token, SyntheticToken)) }
      def token
        self[:token]
      end

      sig { returns(T::Boolean) }
      def fatal?
        level == :error
      end
    end

    sig { params(err: SourceError).returns(SyntheticFinding) }
    def self.synthetic_finding_from(err)
      tok = err.token ? err.token : SyntheticToken.new(line: 1, column: 1, value: "")
      SyntheticFinding.new(
        level: :error,
        message: err.original_message,
        token: tok,
        category: err.is_a?(ParserError) ? :syntax : :type,
        fixes: [],
      )
    end
  private_class_method :synthetic_finding_from

end
end
