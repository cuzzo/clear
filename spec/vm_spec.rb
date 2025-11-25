require 'rspec'
require_relative '../vm' # Adjust path to your parser.rb
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

  describe "Smoke Tests" do
    context "Variable Assignment to 42" do
      let(:source) {
        <<~FLUX
          VAR x = 42;
          x;
        FLUX
      }

      it "is 42" do
        resp = run(source)
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
        FLUX
      }

      it "is 7" do
        resp = run(source)
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
        resp = run(source)
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
        resp = run(source)
        expect(resp).to eq("Hello World")
      end
    end
  end
end

