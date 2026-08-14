require "spec_helper"

# A `&blk` argument forwards a block someone else wrote: it is a
# BlockArgumentNode, not a BlockNode, so it has no parameter list to inspect.
# Helpers that reach for `node.block.parameters` must decline instead of
# raising NoMethodError.
RSpec.describe "forwarded block arguments" do
  it "does not crash on each_with_object with a forwarded block" do
    expect { RubyToClear.transpile(<<~RUBY) }.not_to raise_error
      def collect(xs, &blk)
        xs.each_with_object([], &blk)
      end
    RUBY
  end

  it "reports unsupported syntax rather than crashing on a forwarded with_object block" do
    source = <<~RUBY
      def collect(xs, &blk)
        xs.each_with_index.with_object([], &blk)
      end
    RUBY
    expect { RubyToClear.transpile(source) }
      .to raise_error(RubyToClear::Transpiler::TranspilationError, /each_with_index without a block/)
  end
end
