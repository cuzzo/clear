require "spec_helper"

require_relative "../ruby/annotator/annotator" unless defined?(SemanticAnnotator::ReceiverState)

RSpec.describe "annotator builtin environment" do
  it "registers globals and builtin resource types from stdlib environment data" do
    annotator = SemanticAnnotator.new(source_code: "")
    scope = annotator.semantic_root_scope

    argv = scope.resolve_entry("argv")
    expect(argv).not_to be_nil
    expect(T.must(argv).type.resolved).to eq(:String)
    expect(T.must(argv).storage).to eq(:heap)

    expect(scope.resolve_type("append").resolved).to eq(:Intrinsic)

    range = scope.resolve_type_definition(:Range)
    expect(range).to be_a(Schemas::StructSchema)
    expect(T.must(range).fields.keys).to contain_exactly("start", "end")

    file = scope.resolve_type_definition(:File)
    expect(file).to be_a(Schemas::ResourceSchema)
    expect(T.must(file).static_methods.keys).to contain_exactly("open", "create")

    server = scope.resolve_type_definition(:TCPServer)
    expect(server).to be_a(Schemas::ResourceSchema)
    expect(T.must(server).static_methods.keys).to eq(["listen"])

    client = scope.resolve_type_definition(:TCPClient)
    expect(client).to be_a(Schemas::ResourceSchema)
    expect(T.must(client).static_methods.keys).to eq(["connect"])
  end
end
