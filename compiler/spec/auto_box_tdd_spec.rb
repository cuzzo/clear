require "rspec"
require_relative "../ruby/backends/transpiler"

# Active RED specification for automatic layout transport. These examples are
# intentionally not pending or quarantined: the suite defines the language
# contract before element-level @indirect and box/unbox moves are implemented.
RSpec.describe "automatic box transport — TDD contract" do
  before { FixCollector.enable! }
  after { FixCollector.disable! }

  def transpile(source, mode: :easy)
    ZigTranspiler.new(source_dir: Dir.pwd).transpile(
      source,
      source_dir: Dir.pwd,
      ownership_mode: mode,
    )
  end

  def expect_compile(source, mode: :easy)
    expect { transpile(source, mode: mode) }.not_to raise_error
  end

  def boxed_list_program(body, item_type: "Foo@indirect", mode: :easy)
    source = <<~CLEAR
      STRUCT Foo { name: String }
      FN main() RETURNS Void ->
        MUTABLE items: #{item_type}[]@list = [];
        #{body}
      END
    CLEAR
    transpile(source, mode: mode)
  end

  describe "element layout is distinct from list layout" do
    it "models T@indirect[]@list as an inline list header containing boxed elements" do
      zig = boxed_list_program('ASSERT items.length() == 0;')

      expect(zig).to include("std.ArrayListUnmanaged(*Foo)")
      expect(zig).not_to include("*std.ArrayListUnmanaged(Foo)")
    end

    it "keeps T[]@list:indirect as a boxed list header containing inline elements" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        FN main() RETURNS Void ->
          MUTABLE items: Foo[]@list:indirect = [];
          items.append(Foo{ name: COPY "inline" });
        END
      CLEAR
      zig = transpile(source)

      expect(zig).to include("*std.ArrayListUnmanaged(Foo)")
      expect(zig).not_to include("std.ArrayListUnmanaged(*Foo)")
    end
  end

  describe "automatic boxing into an explicit boxed destination" do
    it "allocates a box and moves an inline TAKES payload into a boxed-element list" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        FN add!(TAKES f: Foo, MUTABLE items: Foo@indirect[]@list) RETURNS Void ->
          items.append(f);
        END
        FN main() RETURNS Void ->
          MUTABLE items: Foo@indirect[]@list = [];
          f = Foo{ name: COPY "inline" };
          add!(f, items);
          ASSERT items.length() == 1;
        END
      CLEAR
      zig = transpile(source)

      expect(zig).to include("std.ArrayListUnmanaged(*Foo)")
      expect(zig).to match(/create\(Foo\).*f/m)
      expect(zig).not_to match(/dupeValue\(Foo.*f/m)
    end

    it "boxes a temporary directly into a boxed-element list without an intermediate owner" do
      zig = boxed_list_program('items.append(Foo{ name: COPY "temporary" }); ASSERT items.length() == 1;')

      expect(zig).to include("std.ArrayListUnmanaged(*Foo)")
      expect(zig).to include("box_move")
      expect(zig).to match(/create\(Foo\)/)
    end

    it "moves an existing box pointer into a boxed-element list without reboxing" do
      zig = boxed_list_program(<<~CLEAR)
        f = Foo{ name: COPY "boxed" } @indirect;
        items.append(f);
        ASSERT items.length() == 1;
      CLEAR

      expect(zig.scan(/localCreate\(Foo/).length).to eq(1)
      expect(zig).not_to include("box_move")
      expect(zig).not_to match(/dupeValue\(Foo/)
    end

    it "contextually boxes a returned inline payload for an explicit indirect return" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        FN make() RETURNS !Foo@indirect ->
          RETURN Foo{ name: COPY "returned" };
        END
        FN main() RETURNS !Void ->
          f = make() OR_ELSE RAISE;
          ASSERT f.name == "returned";
          RETURN;
        END
      CLEAR

      zig = transpile(source)
      expect(zig).to match(/fn make.*!\*Foo/m)
      expect(zig).to match(/create\(Foo\).*returned/m)
    end

    it "contextually boxes present optional payloads but performs no allocation for NIL" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        STRUCT Holder { item: ?Foo@indirect }
        FN main() RETURNS Void ->
          empty = Holder{ item: NIL };
          full = Holder{ item: Foo{ name: COPY "present" } };
          ASSERT empty.item == NIL;
          ASSERT full.item?.name == "present";
        END
      CLEAR

      expect_compile(source)
    end

    it "specializes a generic TAKES append to the boxed element representation" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        FN add!<T>(TAKES value: T, MUTABLE items: T@indirect[]@list) RETURNS Void ->
          items.append(value);
        END
        FN main() RETURNS Void ->
          MUTABLE items: Foo@indirect[]@list = [];
          value = Foo{ name: COPY "generic" };
          add!(value, items);
          ASSERT items.length() == 1;
        END
      CLEAR

      expect_compile(source)
    end
  end

  describe "automatic unboxing into an explicit inline destination" do
    it "moves a boxed payload into an inline list and releases only the empty box shell" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        FN add!(TAKES f: Foo@indirect, MUTABLE items: Foo[]@list) RETURNS Void ->
          items.append(f);
        END
        FN main() RETURNS Void ->
          MUTABLE items: Foo[]@list = [];
          f = Foo{ name: COPY "boxed" } @indirect;
          add!(f, items);
          ASSERT items.length() == 1;
          ASSERT items[0]?.name == "boxed";
        END
      CLEAR

      zig = transpile(source)
      expect(zig).to match(/unboxMove\(Foo/)
      expect(zig).not_to match(/dupeValue\(Foo.*f/m)
    end
  end

  describe "operations that remain explicit errors" do
    it "rejects an implicit boxed-element allocation in DEFAULT with an @indirect fix" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        FN main() RETURNS Void ->
          MUTABLE items: Foo@indirect[]@list = [];
          f = Foo{ name: COPY "default" };
          items.append(f);
        END
      CLEAR

      expect { transpile(source, mode: :default) }
        .to raise_error(/Layout Error.*@indirect/m)
    end

    it "rejects an implicit boxed-element allocation in STRICT with an @indirect fix" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        FN main() RETURNS Void ->
          MUTABLE items: Foo@indirect[]@list = [];
          f = Foo{ name: COPY "strict" };
          items.append(f);
        END
      CLEAR

      expect { transpile(source, mode: :strict) }
        .to raise_error(/Layout Error.*@indirect/m)
    end

    it "contextually constructs an explicit indirect field in every mode" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        STRUCT Holder { item: Foo@indirect }
        FN main() RETURNS Void ->
          holder = Holder{ item: Foo{ name: COPY "field" } };
          ASSERT holder.item.name == "field";
        END
      CLEAR

      %i[easy default strict].each { |mode| expect_compile(source, mode: mode) }
    end

    it "contextually constructs an explicit indirect return ABI in every mode" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        FN make() RETURNS !Foo@indirect ->
          RETURN Foo{ name: COPY "return" };
        END
        FN main() RETURNS !Void ->
          value = make() OR_ELSE RAISE;
          ASSERT value.name == "return";
          RETURN;
        END
      CLEAR

      %i[easy default strict].each { |mode| expect_compile(source, mode: mode) }
    end

    it "requires COPY when an inline source remains live after insertion into boxed elements" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        FN main() RETURNS Void ->
          MUTABLE items: Foo@indirect[]@list = [];
          f = Foo{ name: COPY "still-live" };
          items.append(f);
          ASSERT f.name == "still-live";
        END
      CLEAR

      expect { transpile(source) }
        .to raise_error(/COPY.*still live|still live.*COPY|implicit.*deep copy/im)
    end

    it "rejects a boxed-element list where a concrete inline-element list is required" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        FN add!(TAKES f: Foo, MUTABLE items: Foo[]@list) RETURNS Void ->
          items.append(f);
        END
        FN main() RETURNS Void ->
          MUTABLE items: Foo@indirect[]@list = [];
          f = Foo{ name: COPY "mismatch" };
          add!(f, items);
        END
      CLEAR

      expect { transpile(source) }
        .to raise_error(/element layout|Foo@indirect|expected.*Foo\[\]@list/im)
    end

    it "does not coerce node, RC, shared, or link identity into unique boxes" do
      sources = [
        ["@node", "node"],
        ["@multiowned", "multiowned"],
        ["@shared", "shared"],
      ]

      sources.each do |capability, label|
        source = <<~CLEAR
          STRUCT Foo { name: String }
          FN main() RETURNS Void ->
            MUTABLE items: Foo@indirect[]@list = [];
            value = Foo{ name: COPY "#{label}" } #{capability};
            items.append(value);
          END
        CLEAR
        expect { transpile(source) }
          .to raise_error(/identity|capability|@indirect|Layout Error/im)
      end
    end

    it "rejects element-level @indirect on primitives as pointless indirection" do
      source = <<~CLEAR
        FN main() RETURNS Void ->
          MUTABLE values: Int64@indirect[]@list = [];
          values.append(1);
        END
      CLEAR

      expect { transpile(source) }
        .to raise_error(/@indirect.*primitive|primitive.*@indirect/im)
    end

    it "rejects bare recursive layout in EASY with costed topology fixes" do
      source = <<~CLEAR
        STRUCT Node { value: Int64, next: ?Node }
        FN main() RETURNS Void -> RETURN; END
      CLEAR

      expect { transpile(source) }
        .to raise_error(/@indirect.*@node|@node.*@indirect/im)
    end

    it "rejects multiple recursive layout choices with indirect, node, and shared alternatives" do
      source = <<~CLEAR
        STRUCT Node { value: Int64, left: ?Node, right: ?Node }
        FN main() RETURNS Void -> RETURN; END
      CLEAR

      expect { transpile(source) }
        .to raise_error(/multiple cycle-breaking choices.*@node.*@indirect.*shared/im)
    end

    it "accepts every topology representation offered by the recursive-type diagnostic" do
      %w[@node @indirect @multiowned @shared @link].each do |capability|
        source = <<~CLEAR
          STRUCT Node { value: Int64, next: ?Node#{capability} }
          FN main() RETURNS Void -> RETURN; END
        CLEAR
        expect_compile(source, mode: :default)
      end
    end

    it "never uses boxing to resolve overlapping alias mutation" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        FN main() RETURNS Void ->
          MUTABLE items: Foo@indirect[]@list = [];
          MUTABLE value = Foo{ name: COPY "before" };
          alias = value;
          items.append(value);
          value.name = COPY "after";
          ASSERT alias.name == "before";
        END
      CLEAR

      expect { transpile(source) }
        .to raise_error(/Aliasing Error.*COPY.*CLONE/im)
    end
  end

  describe "machine-applicable layout fixes" do
    it "offers @indirect and @node edits for a recursive field without rewriting during build" do
      source = <<~CLEAR
        STRUCT Node { value: Int64, next: ?Node }
        FN main() RETURNS Void -> RETURN; END
      CLEAR

      expect { transpile(source) }.to raise_error(CompilerError)
      replacements = FixCollector.drain.flat_map(&:fixes).flat_map(&:edits).map(&:replacement)
      expect(replacements.join(" ")).to include("@indirect")
      expect(replacements.join(" ")).to include("@node")
    end

    it "offers a local construction edit for DEFAULT boxed-element insertion" do
      source = <<~CLEAR
        STRUCT Foo { name: String }
        FN main() RETURNS Void ->
          MUTABLE items: Foo@indirect[]@list = [];
          value = Foo{ name: COPY "fix" };
          items.append(value);
        END
      CLEAR

      expect { transpile(source, mode: :default) }.to raise_error(CompilerError)
      replacements = FixCollector.drain.flat_map(&:fixes).flat_map(&:edits).map(&:replacement)
      expect(replacements.join(" ")).to include("@indirect")
    end
  end
end
