require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# C-3b/C-3c: a MONOMORPHIC parameter is emitted anytype and threads the caller's
# actual carrier; Zig monomorphizes per carrier. Field access comptime-unwraps
# the payload, KEEP resolves to retainOne-or-copy at comptime, and the callee's
# universal comptime cleanup releases whatever carrier arrived.
RSpec.describe "MONOMORPHIC carrier threading + KEEP (v5)" do
  def transpile(src)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(src, source_dir: Dir.pwd, ownership_mode: :default)
  end

  it "emits the param anytype, threads the handle (no detach), and comptime-cleans it" do
    zig = transpile(<<~CLEAR)
      STRUCT User { id: Int64 }
      FN consume(TAKES u: MONOMORPHIC User) RETURNS Int64 -> RETURN u.id; END
      FN main() RETURNS Void ->
        m = User{ id: 2 } @multiowned;
        ASSERT consume(m) == 2, "x";
        RETURN;
      END
    CLEAR
    expect(zig).to match(/fn consume\(rt: \*Runtime, u: anytype\)/)
    expect(zig).to match(/CheatLib\.cleanup\(@TypeOf\(u\)/)
    # the retained handle is threaded (moved), not detached to a plain payload
    expect(zig).to match(/consume\(rt, m\)/)
    expect(zig).not_to match(/consume\(rt, __tmp.*dupeValue/m)
    # field access comptime-unwraps the carrier
    expect(zig).to match(/@hasDecl\(@TypeOf\(u\), "__clear_ref_carrier"\)\) u\.ctrl\.data\.\* else u\)\.id/)
  end

  it "resolves KEEP on a MONOMORPHIC param to a comptime retain-or-copy" do
    zig = transpile(<<~CLEAR)
      STRUCT User { id: Int64 }
      FN cache(TAKES u: MONOMORPHIC User) RETURNS Int64 -> RETURN u.id; END
      FN distribute(TAKES u: MONOMORPHIC User) RETURNS Int64 ->
        a = cache(KEEP u);
        b = cache(u);
        RETURN a + b;
      END
      FN main() RETURNS Void ->
        m = User{ id: 2 } @multiowned;
        ASSERT distribute(m) == 4, "x";
        RETURN;
      END
    CLEAR
    expect(zig).to match(/try CheatLib\.dupeValue\(@TypeOf\(u\), u,/)
  end
end

RSpec.describe "MONOMORPHIC gap fixes (v5)" do
  def transpile(src)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(src, source_dir: Dir.pwd, ownership_mode: :default)
  end
  def annotate(src)
    require_relative "../ruby/ast/lexer" unless defined?(Lexer)
    require_relative "../ruby/ast/parser" unless defined?(ClearParser)
    require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
    ast = ClearParser.new(Lexer.new(src).tokenize, src).parse
    SemanticAnnotator.new.annotate!(ast)
  end

  it "KEEP on a MONOMORPHIC param uses carrier-generic dupeValue (deep-copies a heap payload)" do
    zig = transpile(<<~CLEAR)
      STRUCT User { name: String }
      FN cache(TAKES u: MONOMORPHIC User) RETURNS Int64 -> RETURN u.name.length(); END
      FN distribute(TAKES u: MONOMORPHIC User) RETURNS Int64 -> a = cache(KEEP u); b = cache(u); RETURN a + b; END
      FN main() RETURNS Void -> p = User{ name: COPY "hi" }; ASSERT distribute(p) == 4, "x"; RETURN; END
    CLEAR
    expect(zig).to match(/try CheatLib\.dupeValue\(@TypeOf\(u\), u,/)
    expect(zig).not_to match(/@hasDecl\(@TypeOf\(u\), "__clear_ref_carrier"\)\) CheatLib\.retainOne\(@TypeOf\(u\), u\) else u\)/)
  end

  it "projects the receiver payload at comptime for a method on a MONOMORPHIC param" do
    zig = transpile(<<~CLEAR)
      STRUCT User { id: Int64 }
      IMPLEMENTATION User { METHOD bump(self) RETURNS Int64 -> RETURN self.id + 1; END }
      FN consume(TAKES u: MONOMORPHIC User) RETURNS Int64 -> RETURN u.bump(); END
      FN main() RETURNS Void -> m = User{ id: 2 } @multiowned; ASSERT consume(m) == 3, "x"; RETURN; END
    CLEAR
    expect(zig).to match(/@hasDecl\(@TypeOf\(u\), "__clear_ref_carrier"\)\) u\.ctrl\.data\.\* else u\)/)
  end

  it "allows OWN COPY on a MONOMORPHIC param (comptime project + deep copy)" do
    zig = transpile(<<~CLEAR)
      STRUCT User { id: Int64 }
      FN sink(TAKES u: User) RETURNS Int64 -> RETURN u.id; END
      FN relay(TAKES u: MONOMORPHIC User) RETURNS Int64 -> r = sink(OWN COPY u); RETURN r; END
      FN main() RETURNS Void -> m = User{ id: 2 } @multiowned; ASSERT relay(m) == 2, "x"; RETURN; END
    CLEAR
    # comptime payload projection deep-copied into a fresh plain owner
    expect(zig).to match(/@hasDecl\(@TypeOf\(u\), "__clear_ref_carrier"\)\) u\.ctrl\.data\.\* else u\)/)
    expect(zig).to match(/dupeValue\(User,/)
  end

  it "binds a consuming call to a temp in RETURN position (marks flush before return)" do
    zig = transpile(<<~CLEAR)
      STRUCT User { id: Int64 }
      FN cache(TAKES u: MONOMORPHIC User) RETURNS Int64 -> RETURN u.id; END
      FN distribute(TAKES u: MONOMORPHIC User) RETURNS Int64 -> RETURN cache(KEEP u); END
      FN main() RETURNS Void -> m = User{ id: 2 } @multiowned; ASSERT distribute(m) == 2, "x"; RETURN; END
    CLEAR
    # the KEEP'd call is bound to a __ret temp; its move-mark precedes the return
    expect(zig).to match(/const __ret_\d+ = cache\(/)
  end

  it "warns when a function has >= 3 MONOMORPHIC parameters (variant explosion)" do
    src = <<~CLEAR
      STRUCT User { id: Int64 }
      FN big(TAKES a: MONOMORPHIC User, TAKES b: MONOMORPHIC User, TAKES c: MONOMORPHIC User) RETURNS Int64 -> RETURN a.id + b.id + c.id; END
      FN main() RETURNS Void -> RETURN; END
    CLEAR
    expect { annotate(src) }.to output(/3 MONOMORPHIC parameters.*27 \(3\^3\)/m).to_stderr
  end

  it "rejects forwarding a MONOMORPHIC param bare into a concrete plain parameter" do
    src = <<~CLEAR
      STRUCT User { id: Int64 }
      FN bar(TAKES u: User) RETURNS Int64 -> RETURN u.id; END
      FN foo(TAKES u: MONOMORPHIC User) RETURNS Int64 -> r = bar(u); RETURN r; END
      FN main() RETURNS Void -> m = User{ id: 2 } @multiowned; ASSERT foo(m) == 2, "x"; RETURN; END
    CLEAR
    expect { annotate(src) }.to raise_error(/RETAINED_NEEDS_OWN_COPY|cannot fill the plain parameter/)
  end
end
