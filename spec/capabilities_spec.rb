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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
          FN bad(c: Counter @multiowned) RETURNS Float64 -> RETURN 0; END
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
          STRUCT Point { x: Float64 }
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
          STRUCT Point { x: Float64 }
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
          STRUCT Point { x: Float64 }
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
          STRUCT Point { x: Float64 }
          FN bad(p: Point @shared) RETURNS Float64 -> RETURN 0; END
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
          FN getVal(c: Counter) RETURNS Float64 -> RETURN c.value; END
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
          STRUCT Counter { value: Float64 }
          FN getVal(c: Counter) RETURNS Float64 -> RETURN c.value; END
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
          STRUCT Counter { value: Float64 }
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
          FN main() RETURNS Void ->
            MUTABLE c = Counter{ value: 0 } @locked;
            c.value = c.value + 1;
            RETURN;
          END
        FLUX
      }

      it "succeeds and sets auto_lock on the assignment" do
        fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
        assign = fn.body.find { |s| s.is_a?(AST::Assignment) && s.name.is_a?(AST::GetField) }
        expect(assign).not_to be_nil
        expect(assign.auto_lock).to eq({ var: "c", sync: :locked })
      end
    end

    context "auto-lock: one-line field mutation on @writeLocked without WITH block" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            MUTABLE c = Counter{ value: 0 } @writeLocked;
            c.value = c.value + 1;
            RETURN;
          END
        FLUX
      }

      it "succeeds and sets auto_lock with write_locked sync" do
        fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
        assign = fn.body.find { |s| s.is_a?(AST::Assignment) && s.name.is_a?(AST::GetField) }
        expect(assign).not_to be_nil
        expect(assign.auto_lock).to eq({ var: "c", sync: :write_locked })
      end
    end

    context "auto-lock: field mutation on plain struct does NOT set auto_lock" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Int64 }
          FN main() RETURNS Void ->
            MUTABLE c = Counter{ value: 0 };
            c.value = c.value + 1;
            RETURN;
          END
        FLUX
      }

      it "does not set auto_lock" do
        fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
        assign = fn.body.find { |s| s.is_a?(AST::Assignment) && s.name.is_a?(AST::GetField) }
        expect(assign).not_to be_nil
        expect(assign.auto_lock).to be_nil
      end
    end

    context "compound assignment += desugars to x = x + expr" do
      let(:code) {
        <<~FLUX
          FN main() RETURNS Void ->
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
          FN main() RETURNS Void ->
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
          FN bad(c: Counter @locked) RETURNS Float64 -> RETURN 0; END
        FLUX
      }

      it "raises a parser error: capabilities are not allowed on function parameters" do
        expect { ast }.to raise_error(/Capability annotations are not allowed on function parameters/i)
      end
    end
  end

  # ===========================================================================
  # @alwaysMutable (RefCell — interior mutability)
  # ===========================================================================
  describe "@alwaysMutable (interior mutability RefCell(T) wrapper)" do
    it "allows field mutation through const binding" do
      expect {
        run(<<~CLEAR)
          STRUCT Cfg { val: Int64 }
          FN f() RETURNS Void ->
              cfg = Cfg{ val: 1 } @alwaysMutable;
              cfg.val = 2;
              RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "generates RefCell Zig type" do
      zig = ZigTranspiler.new.transpile(<<~CLEAR)
        STRUCT Cfg { val: Int64 }
        FN f() RETURNS Void ->
            cfg = Cfg{ val: 1 } @alwaysMutable;
            RETURN;
        END
      CLEAR
      expect(zig).to include("CheatLib.refCellCreate")
    end

    it "rejects field mutation on non-alwaysMutable const binding" do
      expect {
        run(<<~CLEAR)
          STRUCT Cfg { val: Int64 }
          FN f() RETURNS Void ->
              cfg = Cfg{ val: 1 };
              cfg.val = 2;
              RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot modify field of immutable/)
    end
  end

  describe "@writeLocked (readers-writer RwLocked(T) wrapper)" do
    def write_locked_decl(source)
      run(source).statements.find { |s| s.is_a?(AST::VarDecl) || s.is_a?(AST::BindExpr) }
    end

    context "creating a @writeLocked variable" do
      let(:code) {
        <<~FLUX
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
          FN getVal(c: Counter) RETURNS Float64 -> RETURN c.value; END
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
          STRUCT Counter { value: Float64 }
          FN getVal(c: Counter) RETURNS Float64 -> RETURN c.value; END
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
          FN bad(c: Counter @writeLocked) RETURNS Float64 -> RETURN 0; END
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
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
          STRUCT Counter { value: Float64 }
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
    let(:preamble) { "STRUCT Counter { value: Float64 }\n" }

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
        STRUCT Counter { value: Float64 }
        FN getVal(c: Counter) RETURNS Float64 -> RETURN c.value; END
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
          STRUCT Counter { value: Float64 }
          FN getVal(c: Counter) RETURNS Float64 -> RETURN c.value; END
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
          STRUCT Counter { value: Float64 }
          FN getVal(c: Counter) RETURNS Float64 -> RETURN c.value; END
          c = Counter{ value: 0 } @multiowned:writeLocked;
          WITH c AS inner { getVal(inner); }
        FLUX
      }

      it "infers write_locked_read (sync) rather than :multiowned (ownership) and succeeds" do
        expect { run(code) }.not_to raise_error
      end
    end
  end

  describe "Capability combinations — ordering and conflicts" do
    let(:counter_struct) { "STRUCT Counter { value: Int64 }\n" }

    context "valid cross-dimension combinations" do
      it "@local:indirect parses and compiles" do
        code = counter_struct + "FN f() RETURNS Void -> c = Counter{ value: 0 } @local:indirect; RETURN; END"
        expect { run(code) }.not_to raise_error
      end

      it "@indirect:local (reversed order) parses and compiles" do
        code = counter_struct + "FN f() RETURNS Void -> c = Counter{ value: 0 } @indirect:local; RETURN; END"
        expect { run(code) }.not_to raise_error
      end

      it "@shared:locked (ownership + sync) parses and compiles" do
        code = counter_struct + "FN f() RETURNS Void -> c = Counter{ value: 0 } @shared:locked; RETURN; END"
        expect { run(code) }.not_to raise_error
      end
    end

    context "invalid same-dimension duplicates" do
      it "@locked:writeLocked (duplicate sync) raises parser error" do
        code = counter_struct + "FN f() RETURNS Void -> c = Counter{ value: 0 } @locked:writeLocked; RETURN; END"
        expect { run(code) }.to raise_error(ParserError, /Duplicate sync/)
      end

      it "@shared:multiowned (duplicate ownership) raises parser error" do
        code = counter_struct + "FN f() RETURNS Void -> c = Counter{ value: 0 } @shared:multiowned; RETURN; END"
        expect { run(code) }.to raise_error(ParserError, /Duplicate ownership/)
      end

      it "@local:locked (duplicate sync) raises parser error" do
        code = counter_struct + "FN f() RETURNS Void -> c = Counter{ value: 0 } @local:locked; RETURN; END"
        expect { run(code) }.to raise_error(ParserError, /Duplicate sync/)
      end
    end
  end

  describe "Capability audit — over-engineering detection" do
    let(:counter_struct) { "STRUCT Counter { value: Int64 }\n" }

    it "warns about Ghost Lock: @locked but never WITH EXCLUSIVE" do
      code = counter_struct + "FN f() RETURNS Void -> c = Counter{ value: 0 } @locked; RETURN; END"
      expect {
        ZigTranspiler.new.transpile(code)
      }.to output(/Variable 'c' is @locked but never mutated/).to_stderr
    end

    it "warns about Isolated Share: @shared but never @parallel" do
      code = counter_struct + <<~FLUX
        FN useC(c: Counter) RETURNS Void -> RETURN; END
        FN f() RETURNS Void ->
            c = Counter{ value: 0 } @shared;
            p: ~Void = BG { useC(c); };
            NEXT p;
            RETURN;
        END
      FLUX
      expect {
        ZigTranspiler.new.transpile(code)
      }.to output(/Variable 'c' is @shared.*never leaves the local scheduler/).to_stderr
    end

    it "warns about Unnecessary Local: @local never captured in BG" do
      code = counter_struct + <<~FLUX
        FN useC(c: Counter) RETURNS Void -> RETURN; END
        FN f() RETURNS Void -> c = Counter{ value: 0 } @local; useC(c); RETURN; END
      FLUX
      expect {
        ZigTranspiler.new.transpile(code)
      }.to output(/Variable 'c' is @local but never shared/).to_stderr
    end

    it "does NOT warn when @locked is properly used with WITH EXCLUSIVE" do
      code = counter_struct + <<~FLUX
        FN f() RETURNS Void ->
            c = Counter{ value: 0 } @locked;
            WITH EXCLUSIVE c AS inner { inner.value = 1; }
            RETURN;
        END
      FLUX
      expect {
        ZigTranspiler.new.transpile(code)
      }.not_to output(/Variable 'c' is @locked/).to_stderr
    end

    it "does NOT warn when @local is captured in BG" do
      code = counter_struct + <<~FLUX
        FN f() RETURNS Void ->
            MUTABLE c = Counter{ value: 0 } @local;
            p: ~Void = BG { c.value = c.value + 1; };
            NEXT p;
            RETURN;
        END
      FLUX
      expect {
        ZigTranspiler.new.transpile(code)
      }.not_to output(/Variable 'c' is @local but never shared/).to_stderr
    end
  end

  # ===========================================================================
  # REENTRANCY CAPABILITY — @reentrant / @nonReentrant
  # ===========================================================================
  describe "Reentrancy capability (@reentrant / @nonReentrant)" do

    def transpile(source)
      ZigTranspiler.new.transpile(source)
    end

    # -------------------------------------------------------------------------
    # @reentrant: direct recursion allowed
    # -------------------------------------------------------------------------
    describe "direct recursion" do
      it "raises an error when a directly-recursive function is not annotated" do
        code = <<~CLEAR
          FN fib(n: Int64) RETURNS Int64 ->
            IF n <= 1 THEN RETURN n; END
            RETURN fib(n - 1) + fib(n - 2);
          END
        CLEAR
        expect { run(code) }.to raise_error(CompilerError, /Reentrancy Error.*fib.*@reentrant/)
      end

      it "accepts a directly-recursive function marked @reentrant" do
        code = <<~CLEAR
          FN fib(n: Int64) RETURNS Int64 @reentrant ->
            IF n <= 1 THEN RETURN n; END
            RETURN fib(n - 1) + fib(n - 2);
          END
        CLEAR
        expect { run(code) }.not_to raise_error
      end

      it "raises an error when a directly-recursive function is marked @nonReentrant" do
        code = <<~CLEAR
          FN fib(n: Int64) RETURNS Int64 @nonReentrant ->
            IF n <= 1 THEN RETURN n; END
            RETURN fib(n - 1) + fib(n - 2);
          END
        CLEAR
        expect { run(code) }.to raise_error(CompilerError, /Use @reentrant.*not @nonReentrant/)
      end

      it "transpiles @reentrant function without a StackGuard prologue" do
        code = <<~CLEAR
          FN fib(n: Int64) RETURNS Int64 @reentrant ->
            IF n <= 1 THEN RETURN n; END
            RETURN fib(n - 1) + fib(n - 2);
          END
          FN main() RETURNS Void ->
            ASSERT fib(5) == 5;
          END
        CLEAR
        zig = transpile(code)
        expect(zig).not_to include("StackGuard")
      end
    end

    # -------------------------------------------------------------------------
    # @nonReentrant: fn-pointer / lambda calls
    # -------------------------------------------------------------------------
    describe "fn-pointer / lambda calls" do
      it "does not require annotation when calling a fn-type parameter" do
        # Calling through a fn-type parameter is safe — the caller explicitly controls
        # what function is passed; any self-recursion is visible at the call site.
        code = <<~CLEAR
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS Int64 ->
            RETURN cb(x);
          END
        CLEAR
        expect { run(code) }.not_to raise_error
      end

      it "accepts a fn-pointer-calling function marked @nonReentrant" do
        code = <<~CLEAR
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS Int64 @nonReentrant ->
            RETURN cb(x);
          END
        CLEAR
        expect { run(code) }.not_to raise_error
      end

      it "accepts a fn-pointer-calling function marked @reentrant" do
        code = <<~CLEAR
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS Int64 @reentrant ->
            RETURN cb(x);
          END
        CLEAR
        expect { run(code) }.not_to raise_error
      end

      it "transpiles @nonReentrant with a StackGuard prologue" do
        code = <<~CLEAR
          FN double(x: Int64) RETURNS Int64 ->
            RETURN x * 2;
          END
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS Int64 @nonReentrant ->
            RETURN cb(x);
          END
          FN main() RETURNS Void ->
            result: Int64 = apply(double, 3);
          END
        CLEAR
        zig = transpile(code)
        expect(zig).to include("StackGuard.enter")
        expect(zig).to include("_guard.push()")
        expect(zig).to include("_guard.pop()")
      end

      it "transpiles @nonReentrant with safety import" do
        code = <<~CLEAR
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS Int64 @nonReentrant ->
            RETURN cb(x);
          END
          FN main() RETURNS Void ->
          END
        CLEAR
        zig = transpile(code)
        expect(zig).to include('const safety = @import("safety")')
      end

      it "does not emit safety import when no @nonReentrant functions exist" do
        code = <<~CLEAR
          FN main() RETURNS Void ->
          END
        CLEAR
        zig = transpile(code)
        expect(zig).not_to include("safety")
      end
    end

    # -------------------------------------------------------------------------
    # Indirect (mutual) recursion
    # -------------------------------------------------------------------------
    describe "mutual recursion (indirect cycles)" do
      it "raises an error for unannotated mutually recursive functions" do
        code = <<~CLEAR
          FN isEven(n: Int64) RETURNS Bool ->
            IF n == 0 THEN RETURN TRUE; END
            RETURN isOdd(n - 1);
          END
          FN isOdd(n: Int64) RETURNS Bool ->
            IF n == 0 THEN RETURN FALSE; END
            RETURN isEven(n - 1);
          END
        CLEAR
        expect { run(code) }.to raise_error(CompilerError, /Reentrancy Error.*mutually recursive/)
      end

      it "accepts mutually recursive functions when both are marked @reentrant" do
        code = <<~CLEAR
          FN isEven(n: Int64) RETURNS Bool @reentrant ->
            IF n == 0 THEN RETURN TRUE; END
            RETURN isOdd(n - 1);
          END
          FN isOdd(n: Int64) RETURNS Bool @reentrant ->
            IF n == 0 THEN RETURN FALSE; END
            RETURN isEven(n - 1);
          END
        CLEAR
        expect { run(code) }.not_to raise_error
      end

      it "accepts mutually recursive functions when both are marked @nonReentrant" do
        code = <<~CLEAR
          FN isEven(n: Int64) RETURNS Bool @nonReentrant ->
            IF n == 0 THEN RETURN TRUE; END
            RETURN isOdd(n - 1);
          END
          FN isOdd(n: Int64) RETURNS Bool @nonReentrant ->
            IF n == 0 THEN RETURN FALSE; END
            RETURN isEven(n - 1);
          END
        CLEAR
        expect { run(code) }.not_to raise_error
      end

      it "does not flag functions that share a callee but aren't in a cycle" do
        # foo and bar both call helper — no cycle
        code = <<~CLEAR
          FN helper(x: Int64) RETURNS Int64 ->
            RETURN x + 1;
          END
          FN foo(x: Int64) RETURNS Int64 ->
            RETURN helper(x);
          END
          FN bar(x: Int64) RETURNS Int64 ->
            RETURN helper(x);
          END
        CLEAR
        expect { run(code) }.not_to raise_error
      end
    end

    # -------------------------------------------------------------------------
    # Parser: @reentrant / @nonReentrant attribute parsing
    # -------------------------------------------------------------------------
    describe "parser" do
      it "parses @reentrant on FunctionDef without RETURNS" do
        code = <<~CLEAR
          FN ping() @reentrant ->
            ping();
          END
        CLEAR
        tree = run(code)
        fn = tree.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "ping" }
        expect(fn.reentrant).to eq(:reentrant)
      end

      it "parses @nonReentrant on FunctionDef with RETURNS" do
        code = <<~CLEAR
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS Int64 @nonReentrant ->
            RETURN cb(x);
          END
        CLEAR
        tree = run(code)
        fn = tree.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "apply" }
        expect(fn.reentrant).to eq(:non_reentrant)
      end

      it "leaves reentrant as nil for plain functions" do
        code = <<~CLEAR
          FN add(a: Int64, b: Int64) RETURNS Int64 ->
            RETURN a + b;
          END
        CLEAR
        tree = run(code)
        fn = tree.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "add" }
        expect(fn.reentrant).to be_nil
      end
    end

  end

  # ---------------------------------------------------------------------------
  # Capability syntax enforcement
  # ---------------------------------------------------------------------------
  describe "capability syntax enforcement" do
    it "capabilities must start with @" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS Void -> x = S{ v: 0 } @shared:locked; RETURN; END")
      }.not_to raise_error
    end

    it "rejects two separate @ capabilities without : join" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS Void -> x = S{ v: 0 } @shared @locked; RETURN; END")
      }.to raise_error(/Cannot use two separate @ capabilities.*Join with ':'/)
    end

    it "rejects @locked @shared (two separate @)" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS Void -> x = S{ v: 0 } @locked @shared; RETURN; END")
      }.to raise_error(/Cannot use two separate @ capabilities/)
    end

    it "accepts @shared:locked (joined with :)" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS Void -> x = S{ v: 0 } @shared:locked; RETURN; END")
      }.not_to raise_error
    end

    it "accepts @locked:shared (reversed order, joined with :)" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS Void -> x = S{ v: 0 } @locked:shared; RETURN; END")
      }.not_to raise_error
    end

    it "rejects duplicate sync: @locked:writeLocked" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS Void -> x = S{ v: 0 } @locked:writeLocked; RETURN; END")
      }.to raise_error(/Duplicate sync capability/)
    end

    it "rejects duplicate ownership: @shared:multiowned" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS Void -> x = S{ v: 0 } @shared:multiowned; RETURN; END")
      }.to raise_error(/Duplicate ownership capability/)
    end

    it "HashMap@sharded(N):locked is valid syntax" do
      expect {
        run("FN f() RETURNS Void -> MUTABLE m: HashMap<Int64>@sharded(2):locked = {}; RETURN; END")
      }.not_to raise_error
    end

    it "HashMap@sharded(N) without :locked is valid (lock-elided)" do
      expect {
        run("FN f() RETURNS Void -> MUTABLE m: HashMap<Int64>@sharded(2) = {}; RETURN; END")
      }.not_to raise_error
    end

    it "rejects old HashMap:sharded syntax (capabilities must start with @)" do
      expect {
        run("FN f() RETURNS Void -> MUTABLE m: HashMap<Int64>:sharded(2) = {}; RETURN; END")
      }.to raise_error(ParserError)
    end
  end

end
