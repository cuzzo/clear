# typed: false

require "rspec"
require_relative "frontend_adapter"

RSpec.describe "portable frontend oracle POC" do
  let(:adapter) { RubyFrontendAdapter.new }
  let(:fixtures) { File.join(__dir__, "fixtures/frontend_oracles") }

  it "matches negative diagnostic and range snapshots" do
    JSON.parse(File.read(File.join(fixtures, "diagnostics.json"))).each do |test_case|
      expect(adapter.diagnostic_snapshot(test_case.fetch("source")))
        .to eq(test_case.fetch("snapshot")), test_case.fetch("name")
    end
  end

  it "matches the syntax AST golden snapshot" do
    source = File.read(File.join(fixtures, "smoke.clear"))
    expected = File.read(File.join(fixtures, "smoke.ast.json"))
    expect(adapter.syntax_snapshot(source, ranges: false)).to eq(expected)
  end

  it "preserves syntax AST under parse-format-parse" do
    source = File.read(File.join(fixtures, "smoke.clear"))
    formatted = adapter.format(source)
    expect(formatted).not_to be_nil
    expect(adapter.syntax_snapshot(T.must(formatted), ranges: false))
      .to eq(adapter.syntax_snapshot(source, ranges: false))
  end

  it "preserves source slices and monotonic ranges for adjacent token pairs" do
    atoms = %w[( ) [ ] { } , ; : ? ! + - * / == != <= >= ..< ..<= -> |> .]
    atoms.product(atoms).each do |left, right|
      source = "#{left}#{right}"
      tokens = adapter.tokens(source).reject { |token| token.type == :EOF }
      tokens.each_cons(2) { |a, b| expect(a.end_offset).to be <= b.start_offset }
      tokens.each do |token|
        next if token.start_offset == token.end_offset
        expect(source.byteslice(token.start_offset...token.end_offset)).not_to be_empty
      end
    rescue Lexer::Error
      # A diagnostic is a valid oracle result for an invalid adjacency.
    end
  end

  it "diagnoses every generated malformed delimiter shape without crashing" do
    opens = { "(" => ")", "[" => "]", "{" => "}" }
    malformed = []
    opens.each do |opening, closing|
      malformed << "value = #{opening}1_i64;"
      (opens.values - [closing]).each do |wrong|
        malformed << "value = #{opening}1_i64#{wrong};"
      end
    end
    opens.keys.repeated_permutation(3).each do |prefix|
      malformed << "value = #{prefix.join}1_i64#{opens.fetch(prefix.first)};"
    end

    malformed.each do |source|
      snapshot = adapter.diagnostic_snapshot(source)
      expect(%w[ParserError Lexer::Error]).to include(snapshot.fetch("class")), source
    end
  end
end
