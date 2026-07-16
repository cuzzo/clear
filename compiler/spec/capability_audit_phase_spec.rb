# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/annotator/phases/capability_audit_phase"

RSpec.describe Annotator::Phases::CapabilityAuditPhase do
  def token(value = "program")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  it "runs directly on the typed session and preserves the exact typed-program input" do
    source = ""
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    resolution = Annotator::Phases::ResolutionPhase.run(
      program: program,
      importer: nil,
      source_dir: Dir.pwd,
      source_code: source
    )
    session = SemanticAnnotator.new(source_code: source)
    typed_program = Annotator::Phases::TypeAnalysisPhase.run(resolution: resolution, session: session)
    audit_session = Annotator::Phases::CapabilityAuditSession.new(
      typed_program: typed_program,
      inputs: session.release_capability_audit_inputs!,
      source_code: source,
      language_mode: session.language_mode,
      strict_test: session.strict_test?
    )

    report = described_class.run(typed_program: typed_program, session: audit_session)

    expect(report.typed_program).to equal(typed_program)
    expect(report).to be_success
  end

  it "publishes an audit report for real CLEAR whole-program facts" do
    source = <<~CLEAR
      FN read(value: Int64) RETURNS Int64 ->
        RETURN value;
      END

      FN main() RETURNS Int64 ->
        RETURN read(1);
      END
    CLEAR
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    annotator = SemanticAnnotator.new(source_code: source)

    annotator.annotate!(ast)
    products = annotator.annotation_products
    report = products.capability_audit

    expect(report).to be_a(Annotator::Phases::CapabilityAuditReport)
    expect(T.must(report).typed_program).to equal(products.typed_program)
    expect(T.must(report).checked_functions).to contain_exactly("read", "main")
    expect(T.must(report).checked_call_sites).to be >= 1
  end

  it "does not publish an audit report when a typed program fails capability validation" do
    source = <<~CLEAR
      FN consume(value: Int64) RETURNS Void REQUIRES value: ATOMIC ->
        RETURN;
      END

      FN main() RETURNS Void ->
        consume(1);
        RETURN;
      END
    CLEAR
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    annotator = SemanticAnnotator.new(source_code: source)

    expect { annotator.annotate!(ast) }.to raise_error(CompilerError, /requires parameter 'value'/)
    expect(annotator.annotation_products.typed_program).to be_a(Annotator::Phases::TypedProgramFacts)
    expect(annotator.annotation_products.capability_audit).to be_nil
  end
end
