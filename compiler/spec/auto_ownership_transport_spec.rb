require "rspec"
require_relative "../ruby/backends/transpiler"

RSpec.describe "automatic ownership transport" do
  before { FixCollector.enable! }
  after { FixCollector.disable! }

  def transpile(source, mode: :default)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(
      source,
      source_dir: Dir.pwd,
      ownership_mode: mode,
    )
  end

  it "borrows a local non-mutating alias and keeps the source live" do
    zig = transpile(<<~CLEAR)
      STRUCT User { name: String }
      FN main() RETURNS Void ->
        x = User{ name: "Ada" };
        y = x;
        ASSERT y.name == "Ada";
        ASSERT x.name == "Ada";
      END
    CLEAR

    expect(zig).to include("const y = x;")
    expect(zig).not_to match(/cleanupValue\([^\n]*y/)
  end

  it "allows source mutation after the inferred alias last use" do
    expect {
      transpile(<<~CLEAR)
        STRUCT User { id: Int64 }
        FN main() RETURNS Void ->
          MUTABLE x = User{ id: 1 };
          y = x;
          ASSERT y.id == 1;
          x.id = 2_i64;
          ASSERT x.id == 2;
        END
      CLEAR
    }.not_to raise_error
  end

  it "does not treat assignment of an implicitly Copy value as aliasing" do
    expect {
      transpile(<<~CLEAR, mode: :strict)
        STRUCT Point { x: Int64 }
        FN main() RETURNS Void ->
          MUTABLE source = Point{ x: 1 };
          snapshot = source;
          source.x = 2_i64;
          ASSERT snapshot.x == 1;
        END
      CLEAR
    }.not_to raise_error
  end

  it "tracks chained aliases back to one root" do
    source = <<~CLEAR
      STRUCT User { id: Int64, name: String }
      FN main() RETURNS Void ->
        MUTABLE x = User{ id: 1, name: "Ada" };
        y = x;
        z = y;
        x.id = 2_i64;
        ASSERT z.id == 1;
      END
    CLEAR
    expect { transpile(source) }.to raise_error(/Aliasing Error.*z.*x/m)
  end

  it "requires explicit identity semantics for Rc mutation overlap" do
    source = <<~CLEAR
      STRUCT User { id: Int64, name: String }
      FN main() RETURNS Void ->
        MUTABLE x = User{ id: 1, name: "Ada" } @multiowned;
        y = x;
        x.id = 2_i64;
        ASSERT y.id == 2;
      END
    CLEAR
    expect { transpile(source) }.to raise_error(/Aliasing Error.*COPY x.*CLONE x/m)
    finding = FixCollector.drain.find { |item| item.message.include?("Aliasing Error") }
    expect(finding&.fixes&.map { |fix| fix.edits.first.replacement }).to contain_exactly("COPY ", "CLONE ")
  end

  it "does not conflate mutually exclusive branch uses and mutations" do
    source = <<~CLEAR
      STRUCT User { id: Int64, name: String }
      FN main(flag: Bool) RETURNS Void ->
        MUTABLE x = User{ id: 1, name: "Ada" };
        y = x;
        IF flag THEN
          x.id = 2_i64;
        ELSE
          ASSERT y.id == 1;
        END
      END
    CLEAR
    expect { transpile(source) }.not_to raise_error
  end

  it "accounts for loop backedges when an alias outlives the loop body" do
    source = <<~CLEAR
      STRUCT User { id: Int64, name: String }
      FN main() RETURNS Void ->
        MUTABLE x = User{ id: 1, name: "Ada" };
        y = x;
        MUTABLE i = 0_i64;
        WHILE i < 2 DO
          ASSERT y.id >= 1;
          x.id = x.id + 1;
          i = i + 1;
        END
      END
    CLEAR
    expect { transpile(source) }.to raise_error(/Aliasing Error/)
  end

  it "rejects overlapping mutation in DEFAULT and EASY" do
    source = <<~CLEAR
      STRUCT User { id: Int64, name: String }
      FN main() RETURNS Void ->
        MUTABLE x = User{ id: 1, name: "Ada" };
        y = x;
        x.id = 2_i64;
        ASSERT y.id == 1;
      END
    CLEAR

    [:default, :easy].each do |mode|
      expect { transpile(source, mode: mode) }
        .to raise_error(/Aliasing Error.*COPY x/m)
    end
    finding = FixCollector.drain.find { |item| item.message.include?("Aliasing Error") }
    expect(finding).not_to be_nil
    expect(finding&.fixes&.map { |fix| fix.edits.first.replacement }).to include("COPY ")
  end

  it "derives mutation from stdlib and user signature metadata" do
    stdlib_source = <<~CLEAR
      FN main() RETURNS Void ->
        MUTABLE x: Int64[]@list = [1];
        y = x;
        x.append(2);
        ASSERT y[0] == 1;
      END
    CLEAR
    expect { transpile(stdlib_source) }.to raise_error(/Aliasing Error/)

    user_source = <<~CLEAR
      STRUCT User { id: Int64, name: String }
      FN replaceId!(MUTABLE user: User, id: Int64) RETURNS Void ->
        user.id = id;
      END
      FN main() RETURNS Void ->
        MUTABLE x = User{ id: 1, name: "Ada" };
        y = x;
        x.replaceId!(2);
        ASSERT y.id == 1;
      END
    CLEAR
    expect { transpile(user_source) }.to raise_error(/Aliasing Error/)

    readonly_source = <<~CLEAR
      STRUCT User { id: Int64 }
      FN readId(user: User) RETURNS Int64 -> RETURN user.id; END
      FN main() RETURNS Void ->
        x = User{ id: 1 };
        y = x;
        ASSERT x.readId() == 1;
        ASSERT y.id == 1;
      END
    CLEAR
    expect { transpile(readonly_source) }.not_to raise_error
  end

  it "rejects mutation through any resolved MUTABLE function parameter" do
    source = <<~CLEAR
      STRUCT Foo { value: Int64, label: String }
      FN mutate!(MUTABLE value: Foo) RETURNS Void ->
        value.value = value.value + 1;
      END
      FN main() RETURNS Void ->
        MUTABLE x = Foo{ value: 1, label: "original" };
        y = x;
        mutate!(x);
        ASSERT y.value == 1;
      END
    CLEAR

    %i[default easy].each do |mode|
      expect { transpile(source, mode: mode) }
        .to raise_error(/Aliasing Error.*mutat/m)
    end
  end

  it "rejects mutation through the inferred alias as well as through its source" do
    source = <<~CLEAR
      STRUCT Foo { value: Int64, label: String }
      FN main() RETURNS Void ->
        x = Foo{ value: 1, label: "original" };
        MUTABLE y = x;
        y.value = 2_i64;
        ASSERT x.value == 1;
      END
    CLEAR

    expect { transpile(source) }.to raise_error(/Aliasing Error/m)
  end

  it "rejects mutable alias overlap across pinned and ordinary execution boundaries" do
    %w[plain local multiowned].each do |capability|
      construction = case capability
      when "local" then 'Foo{ value: 1, label: "original" } @local'
      when "multiowned" then 'Foo{ value: 1, label: "original" } @multiowned'
      else 'Foo{ value: 1, label: "original" }'
      end
      source = <<~CLEAR
        STRUCT Foo { value: Int64, label: String }
        FN mutate!(MUTABLE value: Foo) RETURNS Void ->
          value.value = value.value + 1;
        END
        FN main() RETURNS !Void ->
          MUTABLE x = #{construction};
          y = x;
          pending: ~Void = BG { mutate!(x); };
          ASSERT y.value == 1;
          NEXT pending;
          RETURN;
        END
      CLEAR

      expect { transpile(source) }
        .to raise_error(/Aliasing Error/m), "expected #{capability} capture mutation to reject the live alias"
    end
  end

  it "allows mutation-free reads to cross an execution boundary" do
    expect {
      transpile(<<~CLEAR)
        STRUCT Foo { value: Int64, label: String }
        FN read(value: Foo) RETURNS Int64 -> RETURN value.value; END
        FN main() RETURNS !Void ->
          x = Foo{ value: 1, label: "original" };
          y = x;
          pending: ~Int64 = BG { read(x); };
          ASSERT y.value == 1;
          result = NEXT pending;
          ASSERT result == 1;
          RETURN;
        END
      CLEAR
    }.not_to raise_error
  end

  it "preserves explicit affine moves in STRICT" do
    source = <<~CLEAR
      STRUCT User { name: String }
      FN main() RETURNS Void ->
        x = User{ name: "Ada" };
        y = x;
        ASSERT y.name == "Ada";
        ASSERT x.name == "Ada";
      END
    CLEAR

    expect { transpile(source, mode: :strict) }
      .to raise_error(/USE AFTER MOVE.*`x`/m)
  end

  it "automatically materializes a live value passed to TAKES" do
    zig = transpile(<<~CLEAR)
      STRUCT User { name: String }
      FN consume(TAKES user: User) RETURNS Int64 ->
        RETURN user.name.length();
      END
      FN main() RETURNS Void ->
        x = User{ name: "Ada" };
        n = consume(x);
        ASSERT n == 3;
        ASSERT x.name == "Ada";
      END
    CLEAR

    expect(zig).to match(/__copy_src = x/)
    expect(zig).to match(/consume\(rt, __hoist_/)
  end

  it "automatically materializes live values stored into owning destinations" do
    zig = transpile(<<~CLEAR)
      STRUCT User { name: String }
      STRUCT Holder { user: User }
      FN main() RETURNS Void ->
        x = User{ name: "Ada" };
        holder = Holder{ user: x };
        ASSERT holder.user.name == "Ada";
        ASSERT x.name == "Ada";
      END
    CLEAR
    expect(zig).to match(/dupeValue|dupe/)

    expect {
      transpile(<<~CLEAR, mode: :strict)
        STRUCT User { name: String }
        STRUCT Holder { user: User }
        FN main() RETURNS Void ->
          x = User{ name: "Ada" };
          holder = Holder{ user: x };
          ASSERT holder.user.name == "Ada";
          ASSERT x.name == "Ada";
        END
      CLEAR
    }.to raise_error(/USE AFTER MOVE.*`x`/m)
  end

  it "makes a STRICT TAKES transfer produce a fixable use-after-move error" do
    source = <<~CLEAR
      STRUCT User { name: String }
      FN consume(TAKES user: User) RETURNS Void -> RETURN; END
      FN main() RETURNS Void ->
        x = User{ name: "Ada" };
        consume(x);
        ASSERT x.name == "Ada";
      END
    CLEAR

    expect { transpile(source, mode: :strict) }
      .to raise_error(/USE AFTER MOVE.*`x`/m)
    finding = FixCollector.drain.find { |item| item.message.include?("USE AFTER MOVE") }
    expect(finding&.fixes&.map(&:description)&.join("\n")).to include("COPY")
  end

  it "implicitly retains an explicitly Rc-backed value in DEFAULT without GIVE" do
    zig = transpile(<<~CLEAR)
      STRUCT User { name: String }
      FN main() RETURNS Void ->
        x = User{ name: "Ada" } @multiowned;
        y = x;
        ASSERT y.name == "Ada";
        ASSERT x.name == "Ada";
      END
    CLEAR

    expect(zig).to match(/retain|cloneRc|rcClone|\.clone\(/i)
  end

  it "materializes a borrowed parameter when its alias escapes by return" do
    zig = transpile(<<~CLEAR)
      STRUCT User { name: String }
      FN snapshot(user: User) RETURNS User ->
        result = user;
        RETURN result;
      END
      FN main() RETURNS Void ->
        x = User{ name: "Ada" };
        y = snapshot(x);
        ASSERT y.name == "Ada";
      END
    CLEAR

    expect(zig).to match(/dupeValue|dupe/)
  end
end
