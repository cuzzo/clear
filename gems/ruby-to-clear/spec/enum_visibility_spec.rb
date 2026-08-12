# frozen_string_literal: true

RSpec.describe "Sorbet enum visibility" do
  it "exports enum types for signatures in required CLEAR packages" do
    source = <<~RUBY
      class Mode < T::Enum
        enums do
          Read = new("read")
          Write = new("write")
        end
      end
    RUBY

    expect(RubyToClear.transpile(source)).to include("PUB ENUM Mode { Read, Write }")
  end

  it "exports generated constructors with modular declarations" do
    source = <<~RUBY
      class Entry
        def initialize(value)
          @value = value
        end
      end
    RUBY
    config = RubyToClear::HelperConfig.new("export_declarations" => true)

    expect(RubyToClear::Transpiler.new(source, helper_config: config).transpile(Prism.parse(source).value))
      .to include("PUB FN entry__new")
  end
end
