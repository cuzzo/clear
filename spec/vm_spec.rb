require 'rspec'
require_relative '../src/vm'
require_relative 'support/ast_matchers'
require "byebug"

RSpec.configure do |c|
  c.include AstMatchers
end

RSpec.describe VM do
  # Helper to compile source directly to a Chunk
  def run(source)
    vm = VM.new
    vm.run_code(source)
  end

  describe "Integeration Tests" do
    let(:resp) {
       `bundle exec ruby src/vm.rb examples/#{script}.flux`
          .lines
          .map(&:chomp)
    }

    context "boolean logic" do
      let(:script) { 'boolean-logic' }
      it "runs" do
         output = [
           "STDOUT > \"1\"",
           "STDOUT > false",
           "STDOUT > true",
           "STDOUT > \"1\"",
           "__vm_unwind_signal__" # TODO: Error
         ]
         expect(resp).to eq(output)
      end
    end

    context "if" do
      let(:script) { 'if' }
      it "runs" do
         output = [
           "STDOUT > -100.0",
           "__vm_unwind_signal__" # TODO: Error
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
           "10.0" # TODO: Error
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
           "__vm_unwind_signal__" # TODO: Error
        ]
        expect(resp).to eq(output)
      end
    end

    context "while" do
      let(:script) { 'while' }
      it "runs" do
        output = (1...10)
           .map { |x| "STDOUT > #{x.to_f}" }
           .push("__vm_unwind_signal__") # TODO: Error
        expect(resp).to eq(output)
      end
    end

    context "simple func" do
      let(:script) { 'simple-func' }
      it "runs" do
        output = [
          "STDOUT > 10.0",
          "STDOUT > \"HI\""
        ]
        resp.pop() # TODO: ERROR
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
          "1.0"
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
          "__vm_unwind_signal__" # TODO: Error
        ]
        expect(resp).to eq(output)
      end
    end
  end

  describe "Smoke Tests" do
    let(:resp) { run(source).first }

    context "Variable Assignment to 42" do
      let(:source) {
        <<~FLUX
          VAR x = 42;
          x;
        FLUX
      }

      it "is 42" do
        expect(resp).to eq(42)
      end
    end

    context "condition goes to 7" do
      let(:source) {
        <<~FLUX
          VAR x = 42;
          IF x > 100 THEN
            SET x = 100;
          ELSE
            SET x = 7;
          END
          x;
        FLUX
      }

      it "is 7" do
        expect(resp).to eq(7)
      end
    end

    context "named function returns 'Hello World'" do
      let(:source) {
        <<~FLUX
          FN x %() -> RETURN "Hello World"; END
          x();
        FLUX
      }

      it "is 'Hello World'" do
        expect(resp).to eq("Hello World")
      end
    end

    # TODO: Need to implement Lambda assignment to variables
    context "lambda returns 'Hello World'" do
      let(:source) {
        <<~FLUX
          VAR x = %(y)-> "Hello World";
          x(1);
        FLUX
      }

      it "is 'Hello World'" do
        expect(resp).to eq("Hello World")
      end
    end
  end
end

