# frozen_string_literal: true

require "rspec"
require_relative "../../ruby/backends/transpiler" unless defined?(ZigTranspiler)

RSpec.describe "annotation phase pipeline integration" do
  def parse(source)
    ClearParser.new(Lexer.new(source).tokenize, source).parse
  end

  it "hands one program through resolution, type analysis, audit, and SemanticIndex" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }

      FN unwrap(box: Box) RETURNS Int64 ->
        RETURN box.value;
      END

      FN main() RETURNS Int64 ->
        box = Box{ value: 7 };
        RETURN unwrap(box);
      END
    CLEAR
    program = parse(source)
    annotator = SemanticAnnotator.new(source_code: source)

    annotator.annotate!(program)

    products = annotator.annotation_products
    resolution = T.must(products.resolution)
    typed_program = T.must(products.typed_program)
    audit = T.must(products.capability_audit)
    index = T.must(annotator.semantic_index)

    expect(products).to be_complete
    expect(products).to be_frozen
    expect(resolution.program).to equal(program)
    expect(typed_program.resolution).to equal(resolution)
    expect(audit.typed_program).to equal(typed_program)
    expect(index.annotation_products).to equal(products)
    expect(index.program).to equal(program)
    expect(index.body_summaries).to equal(typed_program.body_summaries)
  end

  it "stops before resolution publication when registration fails" do
    source = <<~CLEAR
      FN duplicate() RETURNS Void -> RETURN; END
      FN duplicate() RETURNS Void -> RETURN; END
    CLEAR
    annotator = SemanticAnnotator.new(source_code: source)

    expect { annotator.annotate!(parse(source)) }.to raise_error(CompilerError, /Duplicate function declaration/)
    expect(annotator.annotation_products.resolution).to be_nil
    expect(annotator.annotation_products.typed_program).to be_nil
    expect(annotator.semantic_index).to be_nil
  end

  it "routes imports through resolution before any product is published" do
    source = 'REQUIRE "missing.clear";'
    annotator = SemanticAnnotator.new(source_code: source)

    expect { annotator.annotate!(parse(source)) }.to raise_error(CompilerError, /REQUIRE/)
    expect(annotator.annotation_products.resolution).to be_nil
    expect(annotator.annotation_products.typed_program).to be_nil
  end

  it "preserves resolution but publishes no typed program after a body type error" do
    source = <<~CLEAR
      FN wrong() RETURNS Int64 ->
        RETURN "wrong";
      END
    CLEAR
    annotator = SemanticAnnotator.new(source_code: source)

    expect { annotator.annotate!(parse(source)) }.to raise_error(CompilerError, /expected to return 'Int64'/)
    expect(annotator.annotation_products.resolution).to be_a(Annotator::Phases::ResolutionFacts)
    expect(annotator.annotation_products.typed_program).to be_nil
    expect(annotator.annotation_products.capability_audit).to be_nil
    expect(annotator.semantic_index).to be_nil
  end

  it "preserves typed facts but publishes no audit or index after a capability error" do
    source = <<~CLEAR
      FN consume(value: Int64) RETURNS Void REQUIRES value: ATOMIC -> RETURN; END
      FN main() RETURNS Void ->
        consume(1);
        RETURN;
      END
    CLEAR
    annotator = SemanticAnnotator.new(source_code: source)

    expect { annotator.annotate!(parse(source)) }.to raise_error(CompilerError, /requires parameter 'value'/)
    expect(annotator.annotation_products.resolution).to be_a(Annotator::Phases::ResolutionFacts)
    expect(annotator.annotation_products.typed_program).to be_a(Annotator::Phases::TypedProgramFacts)
    expect(annotator.annotation_products.capability_audit).to be_nil
    expect(annotator.semantic_index).to be_nil
  end
end
