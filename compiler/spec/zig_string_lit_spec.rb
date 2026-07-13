require "rspec"
require_relative "../ruby/mir/mir_lowering" unless defined?(MIRLowering::OwnershipSurfaceScan)

# Direct unit tests for MIRLowering#zig_string_lit. The method only
# fires when a CLEAR PRE clause includes special characters in its
# source text (used to build the runtime error message). Exercising
# each escape branch via PRE-clause CLEAR source is fragile — the
# parser strips/reinterprets some characters before they reach the
# lowering. Direct invocation pins behavior at the actual escape
# layer.

RSpec.describe MIRLowering, "#zig_string_lit" do
  let(:lowering) { described_class.new }

  def escape(s)
    lowering.send(:zig_string_lit, s)
  end

  it "wraps an empty string in quotes" do
    expect(escape("")).to eq(%(""))
  end

  it "passes printable ASCII through verbatim" do
    expect(escape("hello world")).to eq(%("hello world"))
  end

  it "escapes a literal backslash" do
    expect(escape("a\\b")).to eq(%("a\\\\b"))
  end

  it "escapes a double quote" do
    expect(escape(%(say "hi"))).to eq(%("say \\"hi\\""))
  end

  it "escapes named control characters: newline, carriage return, tab" do
    expect(escape("a\nb")).to eq(%("a\\nb"))
    expect(escape("a\rb")).to eq(%("a\\rb"))
    expect(escape("a\tb")).to eq(%("a\\tb"))
  end

  it "hex-escapes other low-ASCII control bytes (0x00-0x1F)" do
    # 0x07 is BEL, 0x1B is ESC. Both fall into the generic
    # 0x00..0x1f range, which uses `\xNN` form.
    expect(escape("\x07")).to eq(%("\\x07"))
    expect(escape("\x1b")).to eq(%("\\x1b"))
  end

  it "hex-escapes DEL (0x7F)" do
    expect(escape("\x7f")).to eq(%("\\x7f"))
  end

  it "passes high UTF-8 bytes through (Zig accepts UTF-8 directly)" do
    # The em-dash (U+2014) is encoded in UTF-8 as 3 bytes: 0xE2 0x80 0x94.
    # All three are >= 0x20, so they pass through unchanged.
    expect(escape("a—b")).to eq(%("a\xE2\x80\x94b").b)
  end

  it "combines multiple escape kinds correctly" do
    expect(escape(%(line\n"q"\\\t))).to eq(%("line\\n\\"q\\"\\\\\\t"))
  end
end
