# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "nil-kill Sorbet feedback parsing" do
  def infer
    NilKill::Infer.allocate.tap { |instance| instance.instance_variable_set(:@store, NilKill::Store.new) }
  end

  def fixture(name)
    File.read(File.join(__dir__, "fixtures", "sorbet", name))
  end

  it "parses 7002 argument widening feedback at the signature location" do
    feedback = infer.send(:parse_sorbet_feedback, fixture("7002.txt"))

    expect(feedback).to include(a_hash_including(
      "code" => "7002",
      "path" => "lib/example.rb",
      "line" => 8,
      "arg" => "name",
      "expected" => "String",
      "found" => "T.nilable(String)"
    ))
  end

  it "parses 7005 result widening feedback at the signature location" do
    feedback = infer.send(:parse_sorbet_feedback, fixture("7005.txt"))

    expect(feedback).to include(a_hash_including(
      "code" => "7005",
      "path" => "lib/example.rb",
      "line" => 8,
      "message" => include("widening return")
    ))
  end

  it "parses 7034 safe-navigation feedback at the origin location" do
    feedback = infer.send(:parse_sorbet_feedback, fixture("7034.txt"))

    expect(feedback).to include(a_hash_including(
      "code" => "7034",
      "path" => "lib/example.rb",
      "line" => 18,
      "site_line" => 25
    ))
  end

  it "strips ANSI color while parsing nil origins" do
    output = "\e[31mlib/example.rb:25: Method `name` does not exist on `NilClass` https://srb.help/7003\e[0m\n" \
      "  lib/origin.rb:4:\n"

    origins = infer.send(:parse_nil_origins, output)

    expect(origins).to eq([{ "origin" => "lib/origin.rb:4", "count" => 1 }])
  end
end
