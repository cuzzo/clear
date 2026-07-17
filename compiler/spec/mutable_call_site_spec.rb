require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)

RSpec.describe "explicit mutable call sites" do
  def parse(source, mode: :default)
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    program.language_mode = mode
    program
  end

  def annotate(source, mode: :default)
    program = parse(source, mode: mode)
    SemanticAnnotator.new.annotate!(program)
    program
  end

  let(:function_prefix) do
    <<~CLEAR
      FN update(MUTABLE value: Int64) RETURNS Void ->
        value = value + 1;
      END
    CLEAR
  end

  it "accepts & on a mutable binding passed to a MUTABLE parameter" do
    source = function_prefix + <<~CLEAR
      FN main() RETURNS Void ->
        MUTABLE value = 1;
        update(&value);
      END
    CLEAR
    expect { annotate(source) }.not_to raise_error
  end

  it "requires & for an existing binding in DEFAULT mode" do
    source = function_prefix + <<~CLEAR
      FN main() RETURNS Void ->
        MUTABLE value = 1;
        update(value);
      END
    CLEAR
    expect { annotate(source) }.to raise_error(CompilerError, /Pass 'value' as '&value'/)
  end

  it "requires the root binding to be MUTABLE for a field path" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }
      #{function_prefix}
      FN main() RETURNS Void ->
        box = Box{ value: 1 };
        update(&box.value);
      END
    CLEAR
    expect { annotate(source) }.to raise_error(CompilerError, /immutable variable 'box'/)
  end

  it "accepts an explicitly mutable field path" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }
      #{function_prefix}
      FN main() RETURNS Void ->
        MUTABLE box = Box{ value: 1 };
        update(&box.value);
      END
    CLEAR
    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("update(&box.value);")
  end

  it "accepts anonymous values without & and materializes calls as mutable temporaries" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN makeBox() RETURNS Box -> RETURN Box{ value: 1 }; END
      FN updateBox(MUTABLE box: Box) RETURNS Void -> box.value = 2; END
      FN main() RETURNS Void -> updateBox(makeBox()); END
    CLEAR
    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to match(/var __mutable_arg_\d+ = makeBox\(\);/)
    expect(zig).to match(/updateBox\(&__mutable_arg_\d+\);/)
  end

  it "rejects redundant & on an anonymous value" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }
      FN makeBox() RETURNS Box -> RETURN Box{ value: 1 }; END
      FN updateBox(MUTABLE box: Box) RETURNS Void -> PASS END
      FN main() RETURNS Void -> updateBox(&makeBox()); END
    CLEAR
    expect { annotate(source) }.to raise_error(CompilerError, /anonymous value/)
  end

  it "rejects & when the parameter is not MUTABLE" do
    source = <<~CLEAR
      FN inspect(value: Int64) RETURNS Void -> PASS END
      FN main() RETURNS Void -> value = 1; inspect(&value); END
    CLEAR
    expect { annotate(source) }.to raise_error(CompilerError, /is not MUTABLE/)
  end

  it "rejects & outside a call boundary" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        MUTABLE value = 1;
        other = &value;
      END
    CLEAR
    expect { annotate(source) }.to raise_error(CompilerError, /only valid on an argument/)
  end

  it "requires & before a mutating method receiver" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        MUTABLE values: []Int64 = [];
        values.append(1);
      END
    CLEAR
    expect { annotate(source) }.to raise_error(CompilerError, /Pass 'values' as '&values'/)
  end

  it "accepts & before a mutating method receiver" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        MUTABLE values: []Int64 = [];
        &values.append(1);
      END
    CLEAR
    expect { annotate(source) }.not_to raise_error
  end

  it "requires an explicitly addressed method receiver root to be MUTABLE" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        values: []Int64 = [];
        &values.append(1);
      END
    CLEAR
    expect { annotate(source) }.to raise_error(CompilerError, /immutable variable 'values'/)
  end

  it "offers one EASY fix for an implicit mutating method call" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        values: []Int64 = [];
        values.append(1);
      END
    CLEAR
    FixCollector.enable!
    begin
      annotate(source, mode: :easy)
      finding = FixCollector.drain.find { |item| item.message.include?("&values") }
      expect(finding).not_to be_nil
      expect(finding.fixes.first.edits.map(&:replacement)).to contain_exactly("&", "MUTABLE ")
    ensure
      FixCollector.disable!
    end
  end

  it "accepts a mutating method on an anonymous receiver without &" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }
      IMPLEMENTATION Box {
        METHOD update(MUTABLE self) RETURNS Void -> self.value = 2_i64; END
      }
      FN makeBox() RETURNS Box -> RETURN Box{ value: 1_i64 }; END
      FN main() RETURNS Void -> makeBox().update(); END
    CLEAR
    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to match(/var __mutable_(?:arg|receiver)_\d+ = makeBox\(\);/)
  end

  it "accepts a mutating method on an @alwaysMutable receiver without &" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }
      IMPLEMENTATION Box {
        METHOD update(MUTABLE self) RETURNS Void -> self.value = 2_i64; END
      }
      FN main() RETURNS Void ->
        box = Box{ value: 1_i64 } @alwaysMutable;
        box.update();
      END
    CLEAR
    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("update(&box.data);")
  end

  it "does not require & for an @alwaysMutable field" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      STRUCT Holder { item: Item@alwaysMutable }
      FN updateItem(MUTABLE item: Item) RETURNS Void -> item.value = 2; END
      FN main() RETURNS Void ->
        holder = Holder{ item: Item{ value: 1 } @alwaysMutable };
        updateItem(holder.item);
      END
    CLEAR
    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("updateItem(&holder.item.data);")
  end

  it "allows an explicit & on an @alwaysMutable field without upgrading its root" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      STRUCT Holder { item: Item@alwaysMutable }
      FN updateItem(MUTABLE item: Item) RETURNS Void -> item.value = 2; END
      FN main() RETURNS Void ->
        holder = Holder{ item: Item{ value: 1 } @alwaysMutable };
        updateItem(&holder.item);
      END
    CLEAR
    expect { annotate(source) }.not_to raise_error
  end

  it "does not require & for an @alwaysMutable binding" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      FN updateItem(MUTABLE item: Item) RETURNS Void -> item.value = 2; END
      FN main() RETURNS Void ->
        item = Item{ value: 1 } @alwaysMutable;
        updateItem(item);
      END
    CLEAR
    expect { annotate(source) }.not_to raise_error
  end

  it "allows an ordinary parameter to mutate one of its @alwaysMutable fields" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      STRUCT Holder { item: Item@alwaysMutable }
      FN updateItem(MUTABLE item: Item) RETURNS Void -> item.value = 2; END
      FN updateHolder(holder: Holder) RETURNS Void -> updateItem(holder.item); END
      FN main() RETURNS Void ->
        holder = Holder{ item: Item{ value: 1 } @alwaysMutable };
        updateHolder(holder);
      END
    CLEAR
    expect { annotate(source) }.not_to raise_error
  end

  it "allows direct mutation through an @alwaysMutable field on an ordinary parameter" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      STRUCT Holder { item: Item@alwaysMutable }
      FN updateHolder(holder: Holder) RETURNS Void -> holder.item.value = 2; END
      FN main() RETURNS Void ->
        holder = Holder{ item: Item{ value: 1 } @alwaysMutable };
        updateHolder(holder);
      END
    CLEAR
    zig = ZigTranspiler.new.transpile(source)
    expect(zig).to include("holder.item.data.value = 2;")
  end

  it "rejects direct nested-field mutation through an ordinary parameter" do
    source = <<~CLEAR
      STRUCT Item { value: Int64 }
      STRUCT Holder { item: Item }
      FN updateHolder(holder: Holder) RETURNS Void -> holder.item.value = 2; END
    CLEAR
    expect { annotate(source) }.to raise_error(CompilerError, /immutable.*holder|holder.*immutable/i)
  end

  it "offers an EASY fix for both the root and marker of a field path" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }
      #{function_prefix}
      FN main() RETURNS Void ->
        box = Box{ value: 1 };
        update(box.value);
      END
    CLEAR
    FixCollector.enable!
    begin
      annotate(source, mode: :easy)
      finding = FixCollector.drain.find { |item| item.message.include?("&box") }
      expect(finding).not_to be_nil
      expect(finding.fixes.first.edits.map(&:replacement)).to contain_exactly("&", "MUTABLE ")
    ensure
      FixCollector.disable!
    end
  end

  it "allows EASY mode to promote and implicitly address an existing binding" do
    source = function_prefix + <<~CLEAR
      FN main() RETURNS Void ->
        value = 1;
        update(value);
      END
    CLEAR
    expect { annotate(source, mode: :easy) }.not_to raise_error
  end

  it "offers one EASY autofix that inserts both MUTABLE and &" do
    source = function_prefix + <<~CLEAR
      FN main() RETURNS Void ->
        value = 1;
        update(value);
      END
    CLEAR
    FixCollector.enable!
    begin
      annotate(source, mode: :easy)
      finding = FixCollector.drain.find { |item| item.message.include?("&value") }
      expect(finding).not_to be_nil
      replacements = finding.fixes.first.edits.map(&:replacement)
      expect(replacements).to contain_exactly("&", "MUTABLE ")
    ensure
      FixCollector.disable!
    end
  end
end
