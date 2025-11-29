require 'rspec'
require "byebug"

RSpec.describe "INTEGRATION" do
  describe "Integeration Tests" do
    let(:resp) {
       `bundle exec ruby src/cheat.rb examples/#{script}.flux`
          .lines
          .map(&:chomp)
    }

    context "SMOOTH error handling" do
      let(:script) { 'smooth-error' }
      it "runs" do
        output = [
          "STDOUT > \"1. Fetching User ID: 999.0\"",
          "STDOUT > \"ELSE\"",
          "STDOUT > \"404 Not Found\"",
          "0"
        ]
        expect(resp).to eq(output)
      end
    end

    context "boolean logic" do
      let(:script) { 'boolean-logic' }
      it "runs" do
         output = [
           "STDOUT > \"1\"",
           "STDOUT > false",
           "STDOUT > true",
           "STDOUT > \"1\"",
           "0"
         ]
         expect(resp).to eq(output)
      end
    end

    context "if" do
      let(:script) { 'if' }
      it "runs" do
         output = [
           "STDOUT > -100.0",
           "0"
         ]
         expect(resp).to eq(output)
      end
    end

    context "list access" do
      let(:script) { 'list-access' }
      it "runs" do
        output = [
           "STDOUT > 20.0",
           "STDOUT > 5.0",
           "0"
        ]
        expect(resp).to eq(output)
      end
    end

    context "not" do
      let(:script) { 'not' }
      it "runs" do
        output = [
           "STDOUT > 1.0",
           "STDOUT > true",
           "STDOUT > nil",
           "0"
        ]
        expect(resp).to eq(output)
      end
    end

    context "while" do
      let(:script) { 'while' }
      it "runs" do
        output = ((1...10).to_a + [1, 2, 4, 5])
           .map { |x| "STDOUT > #{x.to_f}" }
           .push("0")
        expect(resp).to eq(output)
      end
    end

    context "simple func" do
      let(:script) { 'simple-func' }
      it "runs" do
        output = [
          "STDOUT > 10.0",
          "STDOUT > \"HI\"",
          "0"
        ]
        expect(resp).to eq(output)
      end
    end

    context "prog" do
      let(:script) { 'prog' }
      it "runs" do
        output = [
          "STDOUT > 100.0",
          "STDOUT > \"HI\"",
          "STDOUT > [100.0, 200.0, 300.0]",
          "0"
        ]
        expect(resp).to eq(output)
      end
    end

    context "power modulo" do
      let(:script) { 'power-mod' }
      it "runs" do
        output = [
          "STDOUT > 256.0",
          "STDOUT > 1.0",
          "0"
        ]
        expect(resp).to eq(output)
      end
    end

    context "binding" do
      let(:script) { 'binding' }
      it "runs" do
        output = [
          "STDOUT > [20.0, 10.0, 19.0, 9.0]",
          "0"
        ]
        expect(resp).to eq(output)
      end
    end
  end
end

