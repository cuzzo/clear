# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require_relative "spec_helper"

# Typed Ruby raises map onto CLEAR's recoverable error channel
# (`RAISE Input, <Type>, msg`) and typed rescues onto per-clause function
# CATCH arms. Programmer-error classes (ArgumentError, TypeError, ...)
# remain panics. Handlers that READ their `=> e` binding stay unsupported —
# CLEAR CATCH arms filter by kind/type/message, they do not bind the error.
RSpec.describe "rescue to CATCH translation" do
  def transpile(source)
    RubyToClear.transpile(source)
  end

  it "maps typed raises to RAISE and typed rescues to CATCH arms" do
    clear = transpile(<<~RUBY)
      # typed: strict
      require "sorbet-runtime"

      class ParseError < StandardError; end
      class BudgetExceeded < StandardError; end

      module Guard
        extend T::Sig

        sig { params(x: Integer).returns(Integer) }
        def self.parse_it(x)
          raise ParseError, "negative" if x < 0
          raise BudgetExceeded, "too big" if x > 100
          x * 2
        end

        sig { params(x: Integer).returns(Integer) }
        def self.guarded(x)
          parse_it(x)
        rescue ParseError
          -1
        rescue BudgetExceeded => e
          -2
        end
      end
    RUBY

    expect(clear).to include('RAISE Input, ParseError, "negative";')
    expect(clear).to include('RAISE Input, BudgetExceeded, "too big";')
    expect(clear).to include("CATCH ParseError\n  RETURN -1;")
    expect(clear).to include("CATCH BudgetExceeded\n  RETURN -2;")
  end

  it "keeps programmer-error raises as panics" do
    clear = transpile(<<~RUBY)
      # typed: strict
      require "sorbet-runtime"

      module Check
        extend T::Sig

        sig { params(x: Integer).returns(Integer) }
        def self.must_be_positive(x)
          raise ArgumentError, "bad input" if x < 0
          x
        end
      end
    RUBY

    expect(clear).to include('panic("bad input")')
    expect(clear).not_to include("RAISE Input, ArgumentError")
  end

  it "leaves handlers that read the error binding unsupported" do
    source = <<~RUBY
      # typed: strict
      require "sorbet-runtime"

      class ParseError < StandardError; end

      module Guard
        extend T::Sig

        sig { params(x: Integer).returns(String) }
        def self.describe(x)
          (x * 2).to_s
        rescue ParseError => e
          e.message
        end
      end
    RUBY

    expect {
      RubyToClear.transpile(source, raise_on_error: true)
    }.to raise_error(RubyToClear::Transpiler::TranspilationError, /rescue/)
  end

  it "keeps the CATCH clause outside a WITH POLYMORPHIC self wrapper on an aliasable instance method" do
    clear = transpile(<<~RUBY)
      # typed: strict
      require "sorbet-runtime"

      class Node
        extend T::Sig

        sig { params(other: Node).returns(T::Boolean) }
        def risky?(other)
          other.equal?(self)
        rescue
          false
        end
      end
    RUBY

    # The CATCH clause is a function-body-level construct (the parser
    # accepts it, alongside END, only as a body terminator) - it must not
    # be nested inside the self-unwrap block's braces.
    expect(clear).not_to match(/WITH POLYMORPHIC self AS \w+ \{[^}]*CATCH/m)
    expect(clear).to match(/^\}\nCATCH Transient, Input, System, NotFound, Permission, Canceled\n  RETURN FALSE;\nEND/m)
  end
end
