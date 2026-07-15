# frozen_string_literal: true

require_relative "../ruby/ast/lexer" unless defined?(Lexer)

RSpec.describe Lexer::Token do
  describe "checked payload accessors" do
    it "returns textual payloads only for textual token kinds" do
      Lexer::Token::TEXT_TYPES.each do |type|
        expect(described_class.new(type, "body", 2, 4).text!).to eq("body")
      end
    end

    it "returns integer payloads only for integer token kinds" do
      Lexer::Token::INTEGER_TYPES.each do |type|
        expect(described_class.new(type, 42, 2, 4).integer!).to eq(42)
      end
    end

    it "returns float payloads only for float token kinds" do
      Lexer::Token::FLOAT_TYPES.each do |type|
        expect(described_class.new(type, 1.5, 2, 4).float!).to eq(1.5)
      end
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

    it "rejects a correctly shaped payload when the token kind is wrong" do
      expect { described_class.new(:INT64, "42", 7, 9).text! }
        .to raise_error(Lexer::TokenPayloadError, /has no text payload/)
      expect { described_class.new(:STRING, 42, 7, 9).integer! }
        .to raise_error(Lexer::TokenPayloadError, /has no integer payload/)
      expect { described_class.new(:STRING, 1.5, 7, 9).float! }
        .to raise_error(Lexer::TokenPayloadError, /has no float payload/)
    end

    it "accepts String subclasses as textual payloads" do
      payload = Class.new(String).new("body")

      expect(described_class.new(:STRING, payload, 2, 4).text!).to equal(payload)
    end
  end
end
