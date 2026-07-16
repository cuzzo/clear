# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/annotator/phases/capability_audit_phase"

RSpec.describe Annotator::Phases::CapabilityAuditPhase do
  def token(value = "program")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  it "keeps mutable capability-audit state behind one explicit operation" do
    public_operations = Annotator::Phases::CapabilityAuditSession.public_instance_methods - Object.public_instance_methods

    expect(public_operations).to contain_exactly(:audit!)
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
    session = Annotator::Phases::TypeAnalysisSession.new(source_code: source)
    handoff = Annotator::Phases::TypeAnalysisPhase.run(resolution: resolution, session: session)
    report = described_class.run(
      typed_program: handoff.typed_program,
      request: handoff.audit_request
    )

    expect(report.typed_program).to equal(handoff.typed_program)
    expect(report).to be_success
  end

  it "fails closed when an audit executor returns with deferred validations" do
    source = ""
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    resolution = Annotator::Phases::ResolutionPhase.run(
      program: program, importer: nil, source_dir: Dir.pwd, source_code: source
    )
    type_session = Annotator::Phases::TypeAnalysisSession.new(source_code: source)
    handoff = Annotator::Phases::TypeAnalysisPhase.run(resolution: resolution, session: type_session)
    handoff.audit_request.inputs.deferred_with_validations << T.unsafe(Object.new)
    audit_session = instance_double(Annotator::Phases::CapabilityAuditSession, audit!: nil)
    allow(Annotator::Phases::CapabilityAuditSession).to receive(:new).and_return(audit_session)

    expect {
      described_class.run(typed_program: handoff.typed_program, request: handoff.audit_request)
    }.to raise_error(RuntimeError, /left deferred validations pending/)
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

  it "audits a function whose runtime contract is introduced by PRE" do
    source = <<~CLEAR
      FN positive(value: Int64) RETURNS !Int64
        PRE: value > 0
      ->
        RETURN value;
      END
    CLEAR
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    annotator = SemanticAnnotator.new(source_code: source)

    annotator.annotate!(ast)

    expect(T.must(annotator.annotation_products.capability_audit).checked_functions).to contain_exactly("positive")
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
