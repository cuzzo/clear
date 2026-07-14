# frozen_string_literal: true

require_relative "../ruby/ast/lexer" unless defined?(Lexer)

RSpec.describe Lexer::Token do
  describe "checked payload accessors" do
    it "returns textual payloads only for textual token kinds" do
      expect(described_class.new(:TYPE_ID, "Widget", 2, 4).text!).to eq("Widget")
      expect(described_class.new(:STRING, "body", 2, 4).text!).to eq("body")
    end

    it "returns integer payloads only for integer token kinds" do
      expect(described_class.new(:INT64, 42, 2, 4).integer!).to eq(42)
      expect(described_class.new(:BYTE, 255, 2, 4).integer!).to eq(255)
    end

    it "returns float payloads only for float token kinds" do
      expect(described_class.new(:NUMBER, 1.5, 2, 4).float!).to eq(1.5)
      expect(described_class.new(:FLOAT32, 2.5, 2, 4).float!).to eq(2.5)
    end

    it "rejects a payload whose kind does not match the accessor" do
      token = described_class.new(:INT64, 42, 7, 9)

      expect { token.text! }.to raise_error(
        Lexer::TokenPayloadError,
        /:INT64 token at 7:9 has no text payload \(expected String, got Integer\)/,
      )
    end

    it "rejects a payload whose Ruby class violates the token-kind contract" do
      token = described_class.new(:TYPE_ID, 42, 7, 9)

      expect { token.text! }.to raise_error(Lexer::TokenPayloadError, /got Integer/)
      expect { token.integer! }.to raise_error(Lexer::TokenPayloadError, /has no integer payload/)
      expect { token.float! }.to raise_error(Lexer::TokenPayloadError, /has no float payload/)
    end
  end
end
