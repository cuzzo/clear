require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# A DISTINCT fed by an owned SELECT builds its set with an ITERATION-scoped
# frame temp per element (the cross-allocator copy in the materializer). The
# insert loop therefore needs the same per-iteration rewind SELECT's own loop
# emits; without it the frame arena grows per element and the MIR checker
# rejects the program with FRAME_NO_REWIND.
#
# The position matrix cannot cover this: its DISTINCT ops exclude the `ret`
# position because a set is not a list, and the set-RETURNING shape is exactly
# the one that escapes and picks the cross-allocator path.
RSpec.describe "DISTINCT over an owned SELECT" do
  def transpile(source)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd, ownership_mode: :default)
    nil
  rescue StandardError => e
    e.message[/\[([A-Z_0-9]+)\]/, 1] || e.message.lines.reject { |l| l.strip.empty? }.first.to_s.strip[0, 120]
  end

  it "rewinds the insert loop when the set is returned" do
    expect(transpile(<<~CLEAR)).to be_nil
      FN build(names: []String) RETURNS [Set]String ->
        RETURN names |> SELECT _.toString() |> DISTINCT _;
      END
      FN main() RETURNS !Void ->
        print(build(["a"]).length().toString());
      END
    CLEAR
  end

  it "rewinds when the source is a fresh list and the set is returned" do
    expect(transpile(<<~CLEAR)).to be_nil
      FN build(names: []String, extra: String) RETURNS [Set]String ->
        RETURN ((names + [extra])) |> SELECT _.toString() |> DISTINCT _;
      END
      FN main() RETURNS !Void ->
        print(build(["a"], "b").length().toString());
      END
    CLEAR
  end
end
