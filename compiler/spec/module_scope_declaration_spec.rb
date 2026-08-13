require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# A container-scope declaration cannot carry a statement suffix: Zig reads
# `var x: i64 = 11; _ = &x;` at module scope as a malformed field list. The
# unused-binding suppression only belongs inside a function body.
RSpec.describe "module-scope declarations" do
  it "omits the unused-binding suppression from a module-level global" do
    out = ZigTranspiler.new.transpile_as_module(<<~CLEAR)
      MUTABLE next_id: Int64 = 11;

      PUB FN seed() RETURNS Int64 ->
        RETURN next_id;
      END
    CLEAR

    expect(out).to include("next_id: i64 = 11;")
    expect(out).not_to include("_ = &next_id;")
  end

  it "still suppresses an unused binding inside a function body" do
    out = ZigTranspiler.new.transpile_as_module(<<~CLEAR)
      PUB FN seed() RETURNS Int64 ->
        MUTABLE buf: []Int64 = List[];
        &buf.append(1_i64);
        RETURN buf.length();
      END
    CLEAR

    expect(out).to include("_ = &buf;")
  end
end
