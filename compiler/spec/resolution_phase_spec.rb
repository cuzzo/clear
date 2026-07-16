# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/annotator/phases/resolution_phase"

RSpec.describe Annotator::Phases::ResolutionPhase do
  def token(type, value)
    Lexer::Token.new(type, value, 1, 1)
  end

  it "owns resolution ordering without traversing function bodies" do
    body_value = AST::Literal.new(token(:INT64, "1"), :INT64, 1, :stack)
    body_type = body_value.full_type
    fn = AST::FunctionDef.new(token(:FN, "FN"), "main", [], [], Type.new(:Int64), nil, [body_value], nil, nil, nil, nil, nil)
    program = AST::Program.new(token(:PROGRAM, "program"), [fn])
    scope = Scope.new
    registry = Annotator::FunctionRegistry.new
    events = []
    operations = Annotator::Phases::ResolutionOperations.new(
      resolve_import: ->(_node) { events << :import; nil },
      register_types: ->(_declarations) { events << :types; nil },
      register_signatures: lambda do |_declarations|
        events << :signatures
        scope.declare("main", nil, FunctionSignature.new(params: [], return_type: Type.new(:Int64)), false, false, nil, :static)
        nil
      end,
      resolve_reentrance: ->(_node) { events << :reentrance; nil },
      resolve_sync_policy: ->(_node) { events << :sync; nil },
      seed_error_types: ->(_declarations) { events << :errors; nil }
    )

    result = described_class.run(program: program, root_scope: scope, function_registry: registry, operations: operations)

    expect(events).to eq([:types, :signatures, :reentrance, :sync, :errors])
    expect(result.function_names).to include("main")
    expect(body_value.full_type).to equal(body_type)
  end

  it "publishes real compiler resolution facts before body typing" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }

      FN identity(value: Int64) RETURNS Int64 ->
        RETURN value;
      END
    CLEAR
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    annotator = SemanticAnnotator.new(source_code: source)

    annotator.annotate!(ast)
    resolution = annotator.annotation_products.resolution

    expect(resolution).to be_a(Annotator::Phases::ResolutionFacts)
    expect(T.must(resolution).type_names).to include(:Box)
    expect(T.must(resolution).function_names).to include("identity")
    expect(T.must(resolution).declarations.function_declarations.map(&:name)).to eq(["identity"])
  end
end
