# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require_relative "spec_helper"

# Ruby `ensure` (without rescue) maps to CLEAR's DEFER: the cleanup runs at
# scope exit on BOTH the success and error paths — exactly Ruby's contract.
# The DEFER is placed after the last body statement that assigns a local the
# cleanup reads, so the deferred restore never references an unbound name.
RSpec.describe "ensure clause translation" do
  def transpile(source)
    RubyToClear.transpile(source)
  end

  it "maps the save/set/call/restore idiom to DEFER after the save binding" do
    clear = transpile(<<~RUBY)
      # typed: strict
      require "sorbet-runtime"

      class ModeKeeper
        extend T::Sig

        sig { void }
        def initialize
          @mode = T.let(0, Integer)
        end

        sig { params(mode: Integer, blk: T.proc.returns(Integer)).returns(Integer) }
        def with_mode(mode, &blk)
          previous = @mode
          @mode = mode
          blk.call
        ensure
          @mode = previous
        end
      end
    RUBY

    body = clear[/FN modeKeeper__with_mode.*?\nEND/m]
    expect(body).to include("MUTABLE previous = rtoc_self_view.mode;")
    expect(body).to include("DEFER rtoc_self_view.mode = previous;")
    expect(body).to include("RETURN blk();")
    # DEFER comes after the save binding and before the mutation.
    expect(body.index("previous = rtoc_self_view.mode")).to be < body.index("DEFER")
    expect(body.index("DEFER")).to be < body.index("rtoc_self_view.mode = COPY mode")
  end

  it "wraps multi-statement ensure bodies in a DEFER block" do
    clear = transpile(<<~RUBY)
      # typed: strict
      require "sorbet-runtime"

      class TwoSlots
        extend T::Sig

        sig { void }
        def initialize
          @a = T.let(0, Integer)
          @b = T.let(0, Integer)
        end

        sig { params(blk: T.proc.returns(Integer)).returns(Integer) }
        def swap(&blk)
          prev_a = @a
          prev_b = @b
          @a = 1
          @b = 2
          blk.call
        ensure
          @a = prev_a
          @b = prev_b
        end
      end
    RUBY

    body = clear[/FN twoSlots__swap.*?\nEND/m]
    expect(body).to include("DEFER {")
    expect(body).to include("rtoc_self_view.a = prev_a;")
    expect(body).to include("rtoc_self_view.b = prev_b;")
    expect(body.index("prev_b = rtoc_self_view.b")).to be < body.index("DEFER {")
  end

  it "keeps conditional cleanup statement-valued in returning methods" do
    clear = transpile(<<~RUBY)
      # typed: strict
      require "sorbet-runtime"

      class ConditionalRestore
        extend T::Sig

        sig { params(value: T.nilable(Integer), blk: T.proc.returns(Integer)).returns(Integer) }
        def around(value, &blk)
          yield
        ensure
          restore(value) if value
        end

        sig { params(value: Integer).void }
        def restore(value)
          value
          nil
        end
      end
    RUBY

    body = clear[/FN conditionalRestore__around.*?\nEND/m]
    defer = body[/DEFER.*?\n\s*END/m]
    expect(defer).to include("conditionalRestore__restore")
    expect(defer).not_to include("RETURN")
  end
end
