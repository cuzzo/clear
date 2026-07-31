require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# V5-2d: KEEP (a refcount retain of a retained carrier) is optional in EVERY
# mode including STRICT -- the declaration already chose the cost. A COPY
# (payload deep-copy of a plain value) stays explicit in STRICT so no hidden
# allocation occurs (design acceptance #5).
RSpec.describe "KEEP optional in STRICT" do
  def transpile(source, mode:)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd, ownership_mode: mode)
  end

  it "does not require an explicit KEEP for an implicit retain of an @multiowned value in STRICT" do
    src = <<~CLEAR
      STRUCT User { name: String }
      FN observe(u: User) RETURNS Int64 -> RETURN u.name.length(); END
      FN main() RETURNS Void ->
        MUTABLE s = User{ name: "Ada" } @multiowned;
        t = s;
        WITH s { ASSERT observe(s) == 3; }
        WITH t { ASSERT observe(t) == 3; }
        RETURN;
      END
    CLEAR
    expect { transpile(src, mode: :strict) }.not_to raise_error
  end
end

RSpec.describe "COPY still explicit in STRICT" do
  def transpile(source, mode:)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd, ownership_mode: mode)
  end

  it "still requires explicit COPY for an implicit payload copy of a plain value in STRICT" do
    src = <<~CLEAR
      STRUCT User { name: String }
      FN main() RETURNS Void ->
        x = User{ name: "Ada" };
        y = x;
        ASSERT y.name == "Ada";
        ASSERT x.name == "Ada";
        RETURN;
      END
    CLEAR
    expect { transpile(src, mode: :strict) }.to raise_error(StandardError)
  end
end
