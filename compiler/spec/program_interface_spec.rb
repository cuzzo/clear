# frozen_string_literal: true

require "msgpack"

require_relative "spec_helper"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/annotator/phases/resolution_phase"

RSpec.describe Annotator::Phases::ProgramInterface do
  def resolve(source)
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    Annotator::Phases::ResolutionPhase.run(
      program: program,
      importer: nil,
      source_dir: Dir.pwd,
      source_code: source
    )
  end

  it "publishes deterministic portable contracts without compiler object graphs" do
    source = <<~CLEAR
      STRUCT Box<T> { value: T }
      EXTERN STRUCT Native { value: Int64 }
      ENUM Shade { Light, Dark }
      UNION Choice<T> { Some: T, None }
      PROTOCOL Sized { METHOD size(self: Self) RETURNS Int64; }

      FN identity(value: Int64) RETURNS Int64 ->
        RETURN value;
      END
    CLEAR

    first = resolve(source).program_interface
    second = resolve(source).program_interface
    packed = MessagePack.pack(first.to_h)

    expect(MessagePack.unpack(packed)).to eq(first.to_h)
    expect(first.to_h).to eq(second.to_h)
    expect(first.functions.fetch("identity").return_type_key).to include("Int64")
    expect(first.types.transform_values(&:kind)).to include(
      "Box" => "struct",
      "Native" => "extern_struct",
      "Shade" => "enum",
      "Choice" => "union",
      "Sized" => "protocol"
    )
    expect(first.types.fetch("Box").members.fetch("value")).to include("T")
    expect(first.types.fetch("Shade").members).to eq("Dark" => nil, "Light" => nil)
    expect(first).to be_frozen
    expect(first.functions).to be_frozen
    expect(first.types).to be_frozen
  end

  it "provides an empty portable interface for compatibility products" do
    interface = described_class.empty

    expect(interface.functions).to be_empty
    expect(interface.types).to be_empty
    expect(interface.to_h).to eq("functions" => {}, "types" => {})
  end
end
