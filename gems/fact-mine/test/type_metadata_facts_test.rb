# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/fact_mine/syntax"

class TypeMetadataFactsTest < Minitest::Test
  def test_fact_document_exposes_type_definitions
    document = FactMine::Syntax::FactDocument.new(
      {
        "file" => "service.rb",
        "language" => "ruby",
        "type_definitions" => [
          {
            "language" => "ruby",
            "kind" => "method_signature",
            "name" => "call",
            "owner" => "Service",
            "line" => 2,
            "type_system" => "sorbet"
          }
        ]
      }
    )

    assert_equal 1, document.type_definitions.size
    assert_equal "method_signature", document.type_definitions.first.kind
  end

  def test_ruby_provider_emits_sorbet_method_type_definitions
    document = OpenStruct.new(
      file: "service.rb",
      language: :ruby,
      lines: [
        "class Service\n",
        "  sig { params(client: Client).returns(Result) }\n",
        "  def call(client)\n",
        "  end\n",
        "end\n"
      ],
      function_defs: [
        OpenStruct.new(file: "service.rb", owner: "Service", name: "call", line: 3, signature: "")
      ],
      owner_defs: [],
      state_declarations: [],
      call_sites: []
    )

    definition = FactMine::Syntax.language_profile(:ruby).type_definitions(document).first

    assert_equal "method_signature", definition["kind"]
    assert_equal "sorbet", definition["type_system"]
    assert_equal "Result", definition["return_type"]
    assert_equal [{ "name" => "client", "type" => "Client" }], definition["params"]
  end

  def test_ruby_provider_emits_tlet_state_declarations
    document = OpenStruct.new(
      file: "service.rb",
      language: :ruby,
      lines: [
        "class Service\n",
        "  def initialize(client)\n",
        "    @client = T.let(client, Client)\n",
        "  end\n",
        "end\n"
      ],
      function_defs: [],
      owner_defs: [OpenStruct.new(name: "Service", span: [1, 0, 5, 0])],
      state_declarations: [],
      call_sites: []
    )

    declaration = FactMine::Syntax.language_profile(:ruby).typed_state_declarations(document).first

    assert_equal "@client", declaration.field
    assert_equal "Service", declaration.owner
    assert_equal "Client", declaration.type
  end

  def test_python_provider_emits_typing_method_and_alias_definitions
    document = OpenStruct.new(
      file: "service.py",
      language: :python,
      lines: [
        "from typing import TypeAlias\n",
        "ClientAlias: TypeAlias = Client\n",
        "class Service:\n",
        "    def call(self, client: ClientAlias) -> Result:\n",
        "        pass\n"
      ],
      function_defs: [
        OpenStruct.new(file: "service.py", owner: "Service", name: "call", line: 4, signature: "")
      ],
      owner_defs: [OpenStruct.new(name: "Service", span: [3, 0, 5, 0])],
      state_declarations: [],
      call_sites: []
    )

    definitions = FactMine::Syntax.language_profile(:python).type_definitions(document)
    method = definitions.find { |definition| definition["kind"] == "method_signature" }
    alias_definition = definitions.find { |definition| definition["kind"] == "type_alias" }

    assert_equal "Result", method["return_type"]
    assert_equal [{ "name" => "client", "type" => "ClientAlias" }], method["params"]
    assert_equal "Client", alias_definition["target"]
  end

  def test_python_provider_emits_typed_state_declarations
    document = OpenStruct.new(
      file: "worker.py",
      language: :python,
      lines: [
        "class Worker:\n",
        "    def __init__(self, items: list[str]):\n",
        "        self.items: list[str] = items\n"
      ],
      function_defs: [],
      owner_defs: [OpenStruct.new(name: "Worker", span: [1, 0, 3, 37])],
      state_declarations: [],
      call_sites: []
    )
    profile = FactMine::Syntax.language_profile(:python)

    typed_state = profile.typed_state_declarations(document).first
    document.state_declarations = [typed_state]
    definitions = profile.type_definitions(document)
    state_field = definitions.find { |definition| definition["kind"] == "state_field" }

    assert_equal "items", typed_state.field
    assert_equal "Worker", typed_state.owner
    assert_equal "list[str]", typed_state.type
    assert_equal "@items", state_field["name"]
    assert_equal "list[str]", state_field["declared_type"]
  end

  def test_typescript_provider_emits_typed_state_declarations_and_interface_definitions
    document = OpenStruct.new(
      file: "service.ts",
      language: :typescript,
      lines: [
        "class Service {\n",
        "  private client: Client;\n",
        "}\n",
        "interface Loader {\n",
        "  load(client: Client): Result;\n",
        "}\n"
      ],
      function_defs: [],
      owner_defs: [OpenStruct.new(name: "Service", span: [1, 0, 3, 0])],
      state_declarations: [],
      call_sites: []
    )
    profile = FactMine::Syntax.language_profile(:typescript)

    typed_state = profile.typed_state_declarations(document).first
    definitions = profile.type_definitions(document)
    method = definitions.find { |definition| definition["kind"] == "method_signature" }

    assert_equal "client", typed_state.field
    assert_equal "Client", typed_state.type
    assert_equal "Loader", method["owner"]
    assert_equal "Result", method["return_type"]
  end
end
