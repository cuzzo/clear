require "open3"
require "rbconfig"

RSpec.describe "attr RBI generator" do
  it "leaves SymbolEntry lifecycle and flow accessors to their explicit sigged definitions" do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "tools/gen_attr_rbi.rb")

    expect(status).to be_success, stderr
    # These accessors are explicit methods with sigs in symbol_entry.rb, so
    # generating untyped stubs for them would shadow the real signatures.
    expect(stdout).not_to include("def storage; end")
    expect(stdout).not_to include("def storage=(value); end")
    expect(stdout).not_to include("def non_escaping; end")
    expect(stdout).not_to include("def valid; end")
    expect(stdout).not_to include("sig { params(value: Type).returns(Type) }\n  def type=(value); end")
  end

  it "qualifies lexically resolved sibling types in flattened class declarations" do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "tools/gen_attr_rbi.rb")

    expect(status).to be_success, stderr
    expect(stdout).to include("sig { returns(Annotator::Phases::AnnotationProducts) }")
    expect(stdout).to include("sig { returns(T.nilable(Annotator::Phases::ResolutionFacts)) }")
    expect(stdout).to include("sig { returns(Annotator::Phases::DeclarationIndex) }")
    expect(stdout).to include("sig { returns(Annotator::Phases::TypedProgramFacts::BodySummaries) }")
  end
end
