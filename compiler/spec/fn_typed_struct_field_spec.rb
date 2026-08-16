require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# `resolved` on a function type is its RETURN type, so a bare `to_s` rendered
# `FN(Int64) -> Int64` as `Int64`. Storing a REENTRANT function in a plain
# FN-typed field then failed with "Field 'pick' expected Int64, got Int64" --
# an error that names neither the real difference (reentrancy) nor the fact
# that a function type is involved at all.
RSpec.describe "FN-typed struct field diagnostics" do
  def error_for(source)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(source, source_dir: Dir.pwd, ownership_mode: :default)
    nil
  rescue StandardError => e
    e.message
  end

  REENTRANT_INTO_PLAIN_FIELD = <<~CLEAR
    STRUCT Holder { pick: FN(Int64) -> Int64 }

    FN defaultPick(n: Int64) RETURNS Int64 EFFECTS REENTRANT ->
      RETURN n + 1;
    END

    FN main() RETURNS !Void ->
      h = Holder{ pick: defaultPick };
      print(h.name);
    END
  CLEAR

  it "names the function type and the reentrancy that differs" do
    message = error_for(REENTRANT_INTO_PLAIN_FIELD)

    expect(message).to include("FIELD_TYPE_MISMATCH")
    expect(message).to include("expected FN(Int64) -> Int64")
    expect(message).to include("got FN(Int64) -> Int64 EFFECTS REENTRANT")
  end

  it "accepts a non-reentrant function in the same field" do
    expect(error_for(<<~CLEAR)).to be_nil
      STRUCT Holder { pick: FN(Int64) -> Int64 }

      FN defaultPick(n: Int64) RETURNS Int64 ->
        RETURN n + 1;
      END

      FN callIt(h: Holder, n: Int64) RETURNS Int64 ->
        f = h.pick;
        RETURN f(n);
      END

      FN main() RETURNS !Void ->
        h = Holder{ pick: defaultPick };
        n = callIt(h, 1);
        print(n.toString());
      END
    CLEAR
  end
end
