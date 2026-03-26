require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../src/transpiler"
require_relative "../src/ast"

RSpec.describe SemanticAnnotator do
  def run(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    return ast
  end

  def get_last_type(source)
    run(source).statements.last.resolved_type
  end

  let(:ast) { run(code) }
  let(:result) { ast.statements.last.resolved_type }

  # ---------------------------------------------------------------------------
  # Capability Annotations: @multiowned, @shared, @locked, @writeLocked
  # ---------------------------------------------------------------------------

  describe "@multiowned (reference-counted Rc wrapper)" do
    def multiowned_decl(source)
      run(source).statements.find { |s| s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr) }
    end

    context "creating a @multiowned variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @multiowned;
        FLUX
      }

      it "annotates the variable as multiowned" do
        expect(multiowned_decl(code).type_info.multiowned?).to be true
      end

      it "preserves the base resolved type" do
        expect(multiowned_decl(code).type_info.resolved).to eq(:Counter)
      end
    end

    context "direct field access on a @multiowned variable (no WITH needed)" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 10 } @multiowned;
          v = c.value;
        FLUX
      }

      it "succeeds" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH on a plain (non-@multiowned) variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 };
          WITH c { }
        FLUX
      }

      it "raises a capability inference error" do
        expect { ast }.to raise_error(/cannot infer capability/i)
      end
    end

    context "WITH EXCLUSIVE on a @multiowned variable (wrong capability for mutex)" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @multiowned;
          WITH EXCLUSIVE c AS inner { }
        FLUX
      }

      it "raises an error requiring @locked or @writeLocked" do
        expect { ast }.to raise_error(/EXCLUSIVE capability requires a @locked or @writeLocked/i)
      end
    end

    context "capability annotation on a function parameter" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN bad(c: Counter @multiowned) RETURNS Number -> RETURN 0; END
        FLUX
      }

      it "raises a parser error: capabilities are not allowed on function parameters" do
        expect { ast }.to raise_error(/Capability annotations are not allowed on function parameters/i)
      end
    end
  end

  describe "@shared (atomically reference-counted Arc wrapper)" do
    def shared_decl(source)
      run(source).statements.find { |s| s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr) }
    end

    context "creating a @shared variable" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Number }
          p = Point{ x: 1 } @shared;
        FLUX
      }

      it "annotates the variable as shared" do
        expect(shared_decl(code).type_info.shared?).to be true
      end

      it "preserves the base resolved type" do
        expect(shared_decl(code).type_info.resolved).to eq(:Point)
      end
    end

    context "direct field access on a @shared variable (no WITH needed)" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Number }
          p = Point{ x: 5 } @shared;
          v = p.x;
        FLUX
      }

      it "succeeds" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH on a plain (non-@shared) variable" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Number }
          p = Point{ x: 1 };
          WITH p { }
        FLUX
      }

      it "raises a capability inference error" do
        expect { ast }.to raise_error(/cannot infer capability/i)
      end
    end

    context "capability annotation on a function parameter" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Number }
          FN bad(p: Point @shared) RETURNS Number -> RETURN 0; END
        FLUX
      }

      it "raises a parser error: capabilities are not allowed on function parameters" do
        expect { ast }.to raise_error(/Capability annotations are not allowed on function parameters/i)
      end
    end
  end

  describe "@locked (mutex-protected Locked(T) wrapper)" do
    def locked_decl(source)
      run(source).statements.find { |s| s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr) }
    end

    context "creating a @locked variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @locked;
        FLUX
      }

      it "annotates the variable as locked" do
        expect(locked_decl(code).type_info.locked?).to be true
      end

      it "preserves the base resolved type" do
        expect(locked_decl(code).type_info.resolved).to eq(:Counter)
      end
    end

    context "WITH EXCLUSIVE acquires the mutex and binds an alias" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN getVal(c: Counter) RETURNS Number -> RETURN c.value; END
          c = Counter{ value: 42 } @locked;
          WITH EXCLUSIVE c AS inner {
            getVal(inner);
          }
        FLUX
      }

      it "succeeds" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH (implicit) on a @locked variable infers EXCLUSIVE" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN getVal(c: Counter) RETURNS Number -> RETURN c.value; END
          c = Counter{ value: 0 } @locked;
          WITH c AS inner {
            getVal(inner);
          }
        FLUX
      }

      it "succeeds (infers EXCLUSIVE for @locked)" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH EXCLUSIVE on a plain (non-locked) variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 };
          WITH EXCLUSIVE c AS inner { }
        FLUX
      }

      it "raises an error: EXCLUSIVE requires @locked or @writeLocked" do
        expect { ast }.to raise_error(/EXCLUSIVE capability requires a @locked or @writeLocked/i)
      end
    end

    context "auto-lock: one-line field mutation on @locked without WITH block" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Int64 }
          FN cheatMain() RETURNS Void ->
            MUTABLE c = Counter{ value: 0 } @locked;
            c.value = c.value + 1;
            RETURN;
          END
        FLUX
      }

      it "succeeds and sets auto_lock on the assignment" do
        fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "cheatMain" }
        assign = fn.body.find { |s| s.is_a?(AST::Assignment) && s.name.is_a?(AST::GetField) }
        expect(assign).not_to be_nil
        expect(assign.auto_lock).to eq({ var: "c", sync: :locked })
      end
    end

    context "auto-lock: one-line field mutation on @writeLocked without WITH block" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Int64 }
          FN cheatMain() RETURNS Void ->
            MUTABLE c = Counter{ value: 0 } @writeLocked;
            c.value = c.value + 1;
            RETURN;
          END
        FLUX
      }

      it "succeeds and sets auto_lock with write_locked sync" do
        fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "cheatMain" }
        assign = fn.body.find { |s| s.is_a?(AST::Assignment) && s.name.is_a?(AST::GetField) }
        expect(assign).not_to be_nil
        expect(assign.auto_lock).to eq({ var: "c", sync: :write_locked })
      end
    end

    context "auto-lock: field mutation on plain struct does NOT set auto_lock" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Int64 }
          FN cheatMain() RETURNS Void ->
            MUTABLE c = Counter{ value: 0 };
            c.value = c.value + 1;
            RETURN;
          END
        FLUX
      }

      it "does not set auto_lock" do
        fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "cheatMain" }
        assign = fn.body.find { |s| s.is_a?(AST::Assignment) && s.name.is_a?(AST::GetField) }
        expect(assign).not_to be_nil
        expect(assign.auto_lock).to be_nil
      end
    end

    context "compound assignment += desugars to x = x + expr" do
      let(:code) {
        <<~FLUX
          FN cheatMain() RETURNS Void ->
            MUTABLE x = 10;
            x += 5;
            RETURN;
          END
        FLUX
      }

      it "succeeds and x ends up as Int64" do
        expect { ast }.not_to raise_error
      end
    end

    context "compound assignment on struct field" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Int64 }
          FN cheatMain() RETURNS Void ->
            MUTABLE c = Counter{ value: 0 };
            c.value += 10;
            RETURN;
          END
        FLUX
      }

      it "succeeds" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH EXCLUSIVE on a @shared variable (not a mutex)" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @shared;
          WITH EXCLUSIVE c AS inner { }
        FLUX
      }

      it "raises an error: EXCLUSIVE requires a sync variable" do
        expect { ast }.to raise_error(/EXCLUSIVE capability requires a @locked or @writeLocked/i)
      end
    end

    context "WITH (implicit) on a plain (non-locked, non-owned) variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 };
          WITH c { }
        FLUX
      }

      it "raises a capability inference error" do
        expect { ast }.to raise_error(/cannot infer capability/i)
      end
    end

    context "mutation through the EXCLUSIVE alias" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @locked;
          WITH EXCLUSIVE c AS inner {
            inner.value = 99;
          }
        FLUX
      }

      it "allows mutation through the alias" do
        expect { ast }.not_to raise_error
      end
    end

    context "capability annotation on a function parameter" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN bad(c: Counter @locked) RETURNS Number -> RETURN 0; END
        FLUX
      }

      it "raises a parser error: capabilities are not allowed on function parameters" do
        expect { ast }.to raise_error(/Capability annotations are not allowed on function parameters/i)
      end
    end
  end

  describe "@writeLocked (readers-writer RwLocked(T) wrapper)" do
    def write_locked_decl(source)
      run(source).statements.find { |s| s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr) }
    end

    context "creating a @writeLocked variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @writeLocked;
        FLUX
      }

      it "annotates the variable as write_locked" do
        expect(write_locked_decl(code).type_info.write_locked?).to be true
      end

      it "preserves the base resolved type" do
        expect(write_locked_decl(code).type_info.resolved).to eq(:Counter)
      end
    end

    context "WITH EXCLUSIVE acquires the write lock and binds an alias" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN getVal(c: Counter) RETURNS Number -> RETURN c.value; END
          c = Counter{ value: 7 } @writeLocked;
          WITH EXCLUSIVE c AS inner {
            getVal(inner);
          }
        FLUX
      }

      it "succeeds (write access)" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH (implicit) on a @writeLocked variable acquires a read lock" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN getVal(c: Counter) RETURNS Number -> RETURN c.value; END
          c = Counter{ value: 3 } @writeLocked;
          WITH c AS inner {
            getVal(inner);
          }
        FLUX
      }

      it "succeeds (read access)" do
        expect { ast }.not_to raise_error
      end
    end

    context "mutation through the EXCLUSIVE (write) alias" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @writeLocked;
          WITH EXCLUSIVE c AS inner {
            inner.value = 100;
          }
        FLUX
      }

      it "allows mutation through the write alias" do
        expect { ast }.not_to raise_error
      end
    end

    context "WITH EXCLUSIVE on a plain variable (not write-locked)" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 };
          WITH EXCLUSIVE c AS inner { }
        FLUX
      }

      it "raises an error: EXCLUSIVE requires @locked or @writeLocked" do
        expect { ast }.to raise_error(/EXCLUSIVE capability requires a @locked or @writeLocked/i)
      end
    end

    context "capability annotation on a function parameter" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN bad(c: Counter @writeLocked) RETURNS Number -> RETURN 0; END
        FLUX
      }

      it "raises a parser error: capabilities are not allowed on function parameters" do
        expect { ast }.to raise_error(/Capability annotations are not allowed on function parameters/i)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 6: Capability `:` join syntax
  # ---------------------------------------------------------------------------

  describe "capability `:` join at expression level" do
    def cap_join_decl(source)
      run(source).statements.find { |s| s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr) }
    end

    context "@shared:locked join (ownership then sync)" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @shared:locked;
        FLUX
      }

      it "parses and annotates without error" do
        expect { ast }.not_to raise_error
      end

      it "marks the variable as shared (Arc)" do
        expect(cap_join_decl(code).type_info.shared?).to be true
      end

      it "marks the variable as locked (mutex)" do
        expect(cap_join_decl(code).type_info.locked?).to be true
      end
    end

    context "@locked:shared join (sync then ownership, order-independent)" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @locked:shared;
        FLUX
      }

      it "parses and annotates without error" do
        expect { ast }.not_to raise_error
      end

      it "marks the variable as shared (Arc)" do
        expect(cap_join_decl(code).type_info.shared?).to be true
      end

      it "marks the variable as locked (mutex)" do
        expect(cap_join_decl(code).type_info.locked?).to be true
      end
    end

    context "@multiowned:writeLocked join" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @multiowned:writeLocked;
        FLUX
      }

      it "parses and annotates without error" do
        expect { ast }.not_to raise_error
      end

      it "marks the variable as multiowned (Rc)" do
        expect(cap_join_decl(code).type_info.multiowned?).to be true
      end

      it "marks the variable as write_locked (RwLock)" do
        expect(cap_join_decl(code).type_info.write_locked?).to be true
      end
    end

    context "duplicate ownership join error (@shared:multiowned)" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @shared:multiowned;
        FLUX
      }

      it "raises a parser error about duplicate ownership" do
        expect { ast }.to raise_error(/Duplicate ownership capability/i)
      end
    end

    context "duplicate sync join error (@locked:writeLocked)" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          c = Counter{ value: 0 } @locked:writeLocked;
        FLUX
      }

      it "raises a parser error about duplicate sync capability" do
        expect { ast }.to raise_error(/Duplicate sync capability/i)
      end
    end
  end

  describe "capability `:` join in type annotations" do
    context "Counter @shared:locked type" do
      subject(:t) {
        tokens = Lexer.new("Counter @shared:locked").tokenize
        Parser.new(tokens, "Counter @shared:locked").send(:parse_type_annotation)
      }

      it "sets ownership to :shared" do
        expect(t.ownership).to eq(:shared)
      end

      it "sets sync to :locked" do
        expect(t.sync).to eq(:locked)
      end
    end

    context "Counter @locked:multiowned type (reverse order)" do
      subject(:t) {
        tokens = Lexer.new("Counter @locked:multiowned").tokenize
        Parser.new(tokens, "Counter @locked:multiowned").send(:parse_type_annotation)
      }

      it "sets ownership to :multiowned" do
        expect(t.ownership).to eq(:multiowned)
      end

      it "sets sync to :locked" do
        expect(t.sync).to eq(:locked)
      end
    end

    context "Counter @writeLocked:shared type" do
      subject(:t) {
        tokens = Lexer.new("Counter @writeLocked:shared").tokenize
        Parser.new(tokens, "Counter @writeLocked:shared").send(:parse_type_annotation)
      }

      it "sets ownership to :shared" do
        expect(t.ownership).to eq(:shared)
      end

      it "sets sync to :write_locked" do
        expect(t.sync).to eq(:write_locked)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 6: Transpiler output for all dual-capability combinations
  # ---------------------------------------------------------------------------

  describe "capability `:` join — transpiler output (all 4 two-layer combos)" do
    let(:preamble) { "STRUCT Counter { value: Number }\n" }

    context "@shared:locked → Arc(Locked(T))" do
      let(:zig) { ZigTranspiler.new.transpile(preamble + "c = Counter{ value: 0 } @shared:locked;") }

      it "emits lockedCreate for the inner sync layer" do
        expect(zig).to include("lockedCreate")
      end

      it "emits arcCreate for the outer ownership layer" do
        expect(zig).to include("arcCreate")
      end

      it "wraps arcCreate argument with CheatLib.Locked type" do
        expect(zig).to include("CheatLib.Locked(Counter)")
      end
    end

    context "@locked:shared → Arc(Locked(T)) (order-independent)" do
      let(:zig) { ZigTranspiler.new.transpile(preamble + "c = Counter{ value: 0 } @locked:shared;") }

      it "emits lockedCreate and arcCreate" do
        expect(zig).to include("lockedCreate")
        expect(zig).to include("arcCreate")
      end
    end

    context "@shared:writeLocked → Arc(RwLocked(T))" do
      let(:zig) { ZigTranspiler.new.transpile(preamble + "c = Counter{ value: 0 } @shared:writeLocked;") }

      it "emits rwLockedCreate for the inner sync layer" do
        expect(zig).to include("rwLockedCreate")
      end

      it "emits arcCreate for the outer ownership layer" do
        expect(zig).to include("arcCreate")
      end

      it "wraps arcCreate argument with CheatLib.RwLocked type" do
        expect(zig).to include("CheatLib.RwLocked(Counter)")
      end
    end

    context "@multiowned:locked → Rc(Locked(T))" do
      let(:zig) { ZigTranspiler.new.transpile(preamble + "c = Counter{ value: 0 } @multiowned:locked;") }

      it "emits lockedCreate for the inner sync layer" do
        expect(zig).to include("lockedCreate")
      end

      it "emits rcCreate for the outer ownership layer" do
        expect(zig).to include("rcCreate")
      end

      it "wraps rcCreate argument with CheatLib.Locked type" do
        expect(zig).to include("CheatLib.Locked(Counter)")
      end
    end

    context "@multiowned:writeLocked → Rc(RwLocked(T))" do
      let(:zig) { ZigTranspiler.new.transpile(preamble + "c = Counter{ value: 0 } @multiowned:writeLocked;") }

      it "emits rwLockedCreate for the inner sync layer" do
        expect(zig).to include("rwLockedCreate")
      end

      it "emits rcCreate for the outer ownership layer" do
        expect(zig).to include("rcCreate")
      end

      it "wraps rcCreate argument with CheatLib.RwLocked type" do
        expect(zig).to include("CheatLib.RwLocked(Counter)")
      end
    end
  end

  describe "capability `:` join — WITH block dereferences through ownership wrapper" do
    let(:preamble) {
      <<~FLUX
        STRUCT Counter { value: Number }
        FN getVal(c: Counter) RETURNS Number -> RETURN c.value; END
      FLUX
    }

    context "WITH EXCLUSIVE on @shared:locked dereferences through Arc (.data.*)" do
      let(:zig) {
        ZigTranspiler.new.transpile(preamble + <<~FLUX)
          c = Counter{ value: 0 } @shared:locked;
          WITH EXCLUSIVE c AS inner { getVal(inner); }
        FLUX
      }

      it "emits .data.*.acquire() to dereference through Arc before locking" do
        expect(zig).to include(".data.*.acquire()")
      end

      it "does not emit bare .acquire() without Arc dereference" do
        expect(zig).not_to match(/\bc\.acquire\(\)/)
      end
    end

    context "WITH EXCLUSIVE on @shared:writeLocked dereferences through Arc (.data.*)" do
      let(:zig) {
        ZigTranspiler.new.transpile(preamble + <<~FLUX)
          c = Counter{ value: 0 } @shared:writeLocked;
          WITH EXCLUSIVE c AS inner { getVal(inner); }
        FLUX
      }

      it "emits .data.*.write() to dereference through Arc before write-locking" do
        expect(zig).to include(".data.*.write()")
      end
    end

    context "WITH on @locked (no ownership) does NOT add .data.* dereference" do
      let(:zig) {
        ZigTranspiler.new.transpile(preamble + <<~FLUX)
          c = Counter{ value: 0 } @locked;
          WITH c AS inner { getVal(inner); }
        FLUX
      }

      it "emits plain .acquire() without .data.* dereference" do
        expect(zig).to include(".acquire()")
        expect(zig).not_to include(".data.*.acquire()")
      end
    end
  end

  describe "capability `:` join — infer prefers sync over ownership" do
    context "WITH c (implicit) on @shared:locked infers EXCLUSIVE" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN getVal(c: Counter) RETURNS Number -> RETURN c.value; END
          c = Counter{ value: 0 } @shared:locked;
          WITH c AS inner { getVal(inner); }
        FLUX
      }

      it "infers EXCLUSIVE (sync) rather than :shared (ownership) and succeeds" do
        expect { run(code) }.not_to raise_error
      end
    end

    context "WITH c (implicit) on @multiowned:writeLocked infers write_locked_read" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Number }
          FN getVal(c: Counter) RETURNS Number -> RETURN c.value; END
          c = Counter{ value: 0 } @multiowned:writeLocked;
          WITH c AS inner { getVal(inner); }
        FLUX
      }

      it "infers write_locked_read (sync) rather than :multiowned (ownership) and succeeds" do
        expect { run(code) }.not_to raise_error
      end
    end
  end

end
