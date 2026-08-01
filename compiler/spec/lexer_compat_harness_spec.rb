require "rspec"
require "tmpdir"
require "fileutils"

require_relative "../../tools/lexer_compat"

RSpec.describe LexerCompat do
  it "registers the complete ruby-to-CLEAR package closure for generated lexers" do
    Dir.mktmpdir("lexer-compat-packages") do |dir|
      root = File.join(dir, "compiler", "src")
      FileUtils.mkdir_p(File.join(root, "ast"))
      lexer = File.join(root, "ast", "lexer.clear")
      budget = File.join(root, "ast", "frontend_resource_budget.clear")
      token = File.join(root, "ast", "token.clear")
      budget_name = "rtoc_#{"ast/frontend_resource_budget.clear".unpack1("H*")}"
      token_name = "rtoc_#{"ast/token.clear".unpack1("H*")}"

      File.write(lexer, %(REQUIRE "pkg:#{budget_name}" AS budget\n))
      File.write(budget, %(REQUIRE "pkg:#{token_name}" AS token\nSTRUCT Budget {}\n))
      File.write(token, "STRUCT Token {}\n")

      expect(described_class.generated_package_args(lexer)).to eq([
        "--pkg", "#{budget_name}=#{budget}",
        "--pkg", "#{token_name}=#{token}",
      ])
      inline = described_class.generated_inline_source(lexer)
      expect(inline).to include("STRUCT Token {}")
      expect(inline).not_to include("REQUIRE \"pkg:")
      token_position = inline.index("STRUCT Token {}")
      budget_position = inline.index("STRUCT Budget {}")
      expect(token_position).not_to be_nil
      expect(budget_position).not_to be_nil
      expect(token_position).to be < budget_position
    end
  end

  it "ignores malformed generated package identifiers" do
    expect(described_class.decode_generated_package_name("rtoc_not-hex")).to be_nil
    expect(described_class.decode_generated_package_name("ordinary")).to be_nil
  end

  it "unwraps generated optional token payloads before union refinement" do
    source = Dir.mktmpdir("generated-lexer") do |dir|
      root = File.join(dir, "compiler", "src")
      FileUtils.mkdir_p(File.join(root, "ast"))
      lexer = File.join(root, "ast", "lexer.clear")
      File.write(lexer, "STRUCT Token { value: ?TokenValue }\n")
      described_class.clear_harness_source(
        [{ "name" => "empty", "source" => "" }],
        lexer_path: lexer,
        generated: true,
      )
    end

    expect(source).to include("IF token.value == NIL THEN RETURN \"nil\"; END")
    expect(source).to include("payload = UNWRAP token.value;")
    expect(source).to include("IF payload IS_A TokenValue.Str AS value")
    expect(source).not_to include("token.value IS_A TokenValue.Str")
  end
end
