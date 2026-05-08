require "rspec"
require "byebug"
require "tmpdir"
require "fileutils"

require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

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

    context "@multiowned capability annotation on a function parameter" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Float64 }
          FN bad(p: Point @multiowned) RETURNS Float64 -> RETURN 0; END
        FLUX
      }

      it "raises an annotation error: capabilities are not allowed on function parameters" do
        expect { ast }.to raise_error(/Capability annotations are not allowed on function parameters/i)
      end
    end

    context "@shared capability annotation on a function parameter" do
      let(:code) {
        <<~FLUX
          STRUCT Point { x: Float64 }
          FN ok(p: Point @shared) RETURNS Float64 -> RETURN 0; END
        FLUX
      }

      it "is accepted as the explicit shared function-boundary contract" do
        expect { ast }.not_to raise_error
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
          FN f() RETURNS !Void ->
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
        FN f() RETURNS !Void ->
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
          FN f() RETURNS !Void ->
              cfg = Cfg{ val: 1 };
              cfg.val = 2;
              RETURN;
          END
        CLEAR
      }.to raise_error(CompilerError, /Cannot modify field 'val' of immutable object 'cfg'/)
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
        code = counter_struct + "FN f() RETURNS !Void -> c = Counter{ value: 0 } @local:indirect; RETURN; END"
        expect { run(code) }.not_to raise_error
      end

      it "@indirect:local (reversed order) parses and compiles" do
        code = counter_struct + "FN f() RETURNS !Void -> c = Counter{ value: 0 } @indirect:local; RETURN; END"
        expect { run(code) }.not_to raise_error
      end

      it "@shared:locked (ownership + sync) parses and compiles" do
        code = counter_struct + "FN f() RETURNS !Void -> c = Counter{ value: 0 } @shared:locked; RETURN; END"
        expect { run(code) }.not_to raise_error
      end
    end

    context "invalid same-dimension duplicates" do
      it "@locked:writeLocked (duplicate sync) raises parser error" do
        code = counter_struct + "FN f() RETURNS !Void -> c = Counter{ value: 0 } @locked:writeLocked; RETURN; END"
        expect { run(code) }.to raise_error(ParserError, /Duplicate sync/)
      end

      it "@shared:multiowned (duplicate ownership) raises parser error" do
        code = counter_struct + "FN f() RETURNS !Void -> c = Counter{ value: 0 } @shared:multiowned; RETURN; END"
        expect { run(code) }.to raise_error(ParserError, /Duplicate ownership/)
      end

      it "@local:locked (duplicate sync) raises parser error" do
        code = counter_struct + "FN f() RETURNS !Void -> c = Counter{ value: 0 } @local:locked; RETURN; END"
        expect { run(code) }.to raise_error(ParserError, /Duplicate sync/)
      end
    end
  end

  describe "Capability audit — over-engineering detection" do
    let(:counter_struct) { "STRUCT Counter { value: Int64 }\n" }

    it "warns about Ghost Lock: @locked but never WITH EXCLUSIVE" do
      code = counter_struct + "FN f() RETURNS !Void -> c = Counter{ value: 0 } @locked; RETURN; END"
      expect {
        ZigTranspiler.new.transpile(code)
      }.to output(/Variable 'c' is @locked but never mutated/).to_stderr
    end

    it "warns about Isolated Share: @shared but never @parallel" do
      code = counter_struct + <<~FLUX
        FN useC(c: Counter) RETURNS Void -> RETURN; END
        FN f() RETURNS !Void ->
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
        FN f() RETURNS !Void -> c = Counter{ value: 0 } @local; useC(c); RETURN; END
      FLUX
      expect {
        ZigTranspiler.new.transpile(code)
      }.to output(/Variable 'c' is @local but never shared/).to_stderr
    end

    it "does NOT warn when @locked is properly used with WITH EXCLUSIVE" do
      code = counter_struct + <<~FLUX
        FN f() RETURNS !Void ->
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
        FN f() RETURNS !Void ->
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

    it "removes the @local on the lint-flagged binding when a prior @local is on the same line" do
      require_relative "../src/ast/fixable_error"
      src = counter_struct + <<~FLUX
        FN f() RETURNS !Void ->
            MUTABLE a = Counter{ value: 0 } @local; MUTABLE b = Counter{ value: 1 } @local;
            p: ~Void = BG { a.value = a.value + 1; };
            NEXT p;
            RETURN;
        END
      FLUX
      tokens = Lexer.new(src).tokenize
      ast    = Parser.new(tokens, src).parse
      ann    = SemanticAnnotator.new
      ann.source_code = src
      FixCollector.enable!
      begin
        ann.annotate!(ast) rescue nil
        finding = FixCollector.drain.find { |f| f.message =~ /'b' is @local but never shared/ }
        expect(finding).not_to be_nil
        edit = finding.fixes.first.edits.first
        decl_line = src.lines[edit.span.line - 1]
        # The b @local sits AFTER the first @local (a's) on this line.
        expect(edit.span.col).to be > decl_line.index('@local') + 1
      ensure
        FixCollector.disable!
      end
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
        expect { run(code) }.to raise_error(CompilerError, /Reentrancy Error.*fib.*EFFECTS REENTRANT/)
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
        expect { run(code) }.to raise_error(CompilerError, /Replace `@nonReentrant` with `EFFECTS REENTRANT`/)
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
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS !Int64 ->
            RETURN cb(x);
          END
        CLEAR
        expect { run(code) }.not_to raise_error
      end

      it "accepts a fn-pointer-calling function marked @nonReentrant" do
        code = <<~CLEAR
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS !Int64 @nonReentrant ->
            RETURN cb(x);
          END
        CLEAR
        expect { run(code) }.not_to raise_error
      end

      it "accepts a fn-pointer-calling function marked @reentrant" do
        code = <<~CLEAR
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS !Int64 @reentrant ->
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
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS !Int64 @nonReentrant ->
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
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS !Int64 @nonReentrant ->
            RETURN cb(x);
          END
          FN main() RETURNS Void ->
          END
        CLEAR
        zig = transpile(code)
        expect(zig).to include('const safety = @import("runtime/../lib/safety.zig")')
      end

      it "does not emit safety import when no @nonReentrant functions exist" do
        code = <<~CLEAR
          FN main() RETURNS Void ->
          END
        CLEAR
        zig = transpile(code)
        # Must not import the safety lib; the .safety field on the
        # DebugAllocator config (always present in the runtime footer)
        # is unrelated to this check.
        expect(zig).not_to include('@import("runtime/../lib/safety.zig")')
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
          FN isEven(n: Int64) RETURNS !Bool @nonReentrant ->
            IF n == 0 THEN RETURN TRUE; END
            RETURN isOdd(n - 1);
          END
          FN isOdd(n: Int64) RETURNS !Bool @nonReentrant ->
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
          FN foo(x: Int64) RETURNS !Int64 ->
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
          FN apply(cb: FN(Int64) -> Int64, x: Int64) RETURNS !Int64 @nonReentrant ->
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
        run("STRUCT S { v: Int64 }\nFN f() RETURNS !Void -> x = S{ v: 0 } @shared:locked; RETURN; END")
      }.not_to raise_error
    end

    it "rejects two separate @ capabilities without : join" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS !Void -> x = S{ v: 0 } @shared @locked; RETURN; END")
      }.to raise_error(/Cannot use two separate @ capabilities.*Join with ':'/)
    end

    it "rejects @locked @shared (two separate @)" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS !Void -> x = S{ v: 0 } @locked @shared; RETURN; END")
      }.to raise_error(/Cannot use two separate @ capabilities/)
    end

    it "accepts @shared:locked (joined with :)" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS !Void -> x = S{ v: 0 } @shared:locked; RETURN; END")
      }.not_to raise_error
    end

    it "accepts @locked:shared (reversed order, joined with :)" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS !Void -> x = S{ v: 0 } @locked:shared; RETURN; END")
      }.not_to raise_error
    end

    it "rejects duplicate sync: @locked:writeLocked" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS !Void -> x = S{ v: 0 } @locked:writeLocked; RETURN; END")
      }.to raise_error(/Duplicate sync capability/)
    end

    it "rejects duplicate ownership: @shared:multiowned" do
      expect {
        run("STRUCT S { v: Int64 }\nFN f() RETURNS !Void -> x = S{ v: 0 } @shared:multiowned; RETURN; END")
      }.to raise_error(/Duplicate ownership capability/)
    end

    it "HashMap@sharded(N):locked is valid syntax" do
      expect {
        run("FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@sharded(2):locked = {}; RETURN; END")
      }.not_to raise_error
    end

    it "HashMap@sharded(N) without :locked is valid (lock-elided)" do
      expect {
        run("FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>@sharded(2) = {}; RETURN; END")
      }.not_to raise_error
    end

    it "rejects old HashMap:sharded syntax (capabilities must start with @)" do
      expect {
        run("FN f() RETURNS !Void -> MUTABLE m: HashMap<Int64>:sharded(2) = {}; RETURN; END")
      }.to raise_error(ParserError)
    end
  end

  # ---------------------------------------------------------------------------
  # WITH EXCLUSIVE ... ON TIMEOUT / RETRY(N) THEN
  # ---------------------------------------------------------------------------

  describe "WITH EXCLUSIVE error-clause parsing" do
    def parse_only(source)
      tokens = Lexer.new(source).tokenize
      Parser.new(tokens, source).parse
    end

    def with_block(ast)
      ast.statements.find { |s| s.is_a?(AST::WithBlock) }
    end

    it "parses ON Transient RAISE" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Transient RAISE
      FLUX
      clause = with_block(parse_only(src)).lock_error_clause
      expect(clause[:action]).to eq(:raise)
      expect(clause[:selectors]).to eq([{ form: :kind, name: :Transient, token: clause[:selectors].first[:token] }])
      expect(clause[:retries]).to be_nil
    end

    it "parses ON LockTimeout, LockCycle PASS" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON LockTimeout, LockCycle PASS
      FLUX
      clause = with_block(parse_only(src)).lock_error_clause
      expect(clause[:action]).to eq(:pass)
      expect(clause[:selectors].map { |s| [s[:form], s[:name]] }).to eq([[:type, :LockTimeout], [:type, :LockCycle]])
    end

    it "parses ON Transient EXIT with a message" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Transient EXIT "stuck"
      FLUX
      clause = with_block(parse_only(src)).lock_error_clause
      expect(clause[:action]).to eq(:exit)
      expect(clause[:message]).not_to be_nil
    end

    it "parses ON Transient -> { stmts }" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Transient -> { c.v = 0; }
      FLUX
      clause = with_block(parse_only(src)).lock_error_clause
      expect(clause[:action]).to eq(:block)
      expect(clause[:body]).to be_an(Array)
    end

    it "parses RETRY(N) THEN RAISE as sugar for ON Transient" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } RETRY(3) THEN RAISE
      FLUX
      clause = with_block(parse_only(src)).lock_error_clause
      expect(clause[:action]).to eq(:raise)
      expect(clause[:retries]).to eq(3)
      expect(clause[:selectors].first[:name]).to eq(:Transient)
    end

    it "parses ON LockTimeout RETRY(2) THEN RAISE" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON LockTimeout RETRY(2) THEN RAISE
      FLUX
      clause = with_block(parse_only(src)).lock_error_clause
      expect(clause[:retries]).to eq(2)
      expect(clause[:selectors].map { |s| s[:name] }).to eq([:LockTimeout])
    end

    it "rejects RETRY(0)" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } RETRY(0) THEN RAISE
      FLUX
      expect { parse_only(src) }.to raise_error(ParserError, /RETRY\(N\) requires N > 0/)
    end

    it "leaves lock_error_clause nil when no clause present" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; }
      FLUX
      expect(with_block(parse_only(src)).lock_error_clause).to be_nil
    end

    it "rejects unknown action keyword" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Transient WAT
      FLUX
      expect { parse_only(src) }.to raise_error(ParserError, /Expected RAISE, PASS, RETURN <expr>, EXIT/)
    end

    it "parses WITH POSSIBLE_DEADLOCK EXCLUSIVE modifier" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH POSSIBLE_DEADLOCK EXCLUSIVE c AS inner { inner.v = 1; }
      FLUX
      block = with_block(parse_only(src))
      expect(block.deadlock_escape).to include(kind: :deadlock)
    end

    it "parses WITH POSSIBLE_LOCK_CYCLE modifier" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH POSSIBLE_LOCK_CYCLE EXCLUSIVE c AS inner { inner.v = 1; }
      FLUX
      block = with_block(parse_only(src))
      expect(block.deadlock_escape).to include(kind: :lock_cycle)
    end

    it "leaves deadlock_escape nil when no modifier is present" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; }
      FLUX
      expect(with_block(parse_only(src)).deadlock_escape).to be_nil
    end
  end

  describe "WITH error-clause annotator validation" do
    it "accepts ON Transient on EXCLUSIVE @locked" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Transient RAISE
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts ON LockTimeout alone (LockCycle is statically impossible here)" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON LockTimeout PASS
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects unknown identifier as an unknown type" do
      # Under the unified grammar, any TYPE_ID that isn't one of the 6
      # reserved kinds parses as a type. A bogus name surfaces as
      # "Unknown error type" rather than "Unknown error kind" — there
      # is no source-level path to write an unknown kind.
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Nonsense RAISE
      FLUX
      expect { run(src) }.to raise_error(/Unknown error type 'Nonsense'/)
    end

    it "rejects unknown error type" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Imaginary RAISE
      FLUX
      expect { run(src) }.to raise_error(/Unknown error type 'Imaginary'/)
    end

    it "rejects RETRY on a non-Transient selector" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Deadlock RETRY(3) THEN RAISE
      FLUX
      expect { run(src) }.to raise_error(/RETRY only targets Transient errors/)
    end

    it "rejects selectors that cannot match any lock error" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Input RAISE
      FLUX
      expect { run(src) }.to raise_error(/do not match any error the WITH acquire can produce/)
    end

    it "rejects clause on a non-fallible capability (@multiowned)" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        MUTABLE c = C{ v: 0 } @multiowned;
        WITH c { } ON Transient RAISE
      FLUX
      expect { run(src) }.to raise_error(/never produce a lock-acquire error/)
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 1: lexical same-name nested-WITH check
  # ---------------------------------------------------------------------------

  describe "nested lock re-acquire (lexical)" do
    it "rejects same-name nested EXCLUSIVE WITH" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS outer {
          WITH EXCLUSIVE c AS inner { inner.v = 1; }
        }
      FLUX
      expect { run(src) }.to raise_error(/Nested lock re-acquire: 'c' is already held/)
    end

    it "rejects same-name nested write_locked_read on @writeLocked" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @writeLocked;
        WITH EXCLUSIVE c AS outer {
          WITH c AS inner { n = inner.v; }
        }
      FLUX
      expect { run(src) }.to raise_error(/Nested lock re-acquire: 'c'/)
    end

    it "accepts inner WITH when marked POSSIBLE_DEADLOCK" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS outer {
          WITH POSSIBLE_DEADLOCK EXCLUSIVE c AS inner { inner.v = 1; }
        }
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts nested WITH on distinct types" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        STRUCT D { w: Int64 }
        a = C{ v: 0 } @locked;
        b = D{ w: 0 } @locked;
        WITH EXCLUSIVE a AS x {
          WITH EXCLUSIVE b AS y { y.w = x.v; }
        }
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects nested WITH on same-type distinct variables without opt-out (Phase 2)" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        a = C{ v: 0 } @locked;
        b = C{ v: 0 } @locked;
        WITH EXCLUSIVE a AS x {
          WITH EXCLUSIVE b AS y { y.v = x.v; }
        }
      FLUX
      expect { run(src) }.to raise_error(/self-loop.*:C|Potential.*self-loop/)
    end

    it "accepts nested WITH on same-type distinct variables when inner has POSSIBLE_DEADLOCK" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        a = C{ v: 0 } @locked;
        b = C{ v: 0 } @locked;
        WITH EXCLUSIVE a AS x {
          WITH POSSIBLE_DEADLOCK EXCLUSIVE b AS y { y.v = x.v; }
        }
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts BORROWED outer (non-locked) + EXCLUSIVE inner on a different locked variable" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        STRUCT B { n: Int64 }
        c = C{ v: 0 } @locked;
        b = B{ n: 5 };
        WITH BORROWED b AS ref {
          WITH EXCLUSIVE c AS inner { inner.v = ref.n; }
        }
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects three-deep same-name nesting" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS l1 {
          WITH EXCLUSIVE c AS l2 { l2.v = 1; }
        }
      FLUX
      expect { run(src) }.to raise_error(/Nested lock re-acquire/)
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 2: type-level cross-function lock-cycle detection
  # ---------------------------------------------------------------------------

  describe "type-level lock-cycle detection (cross-function)" do
    it "rejects AB/BA cycle across two functions on distinct types" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }

        FN useB() RETURNS !Void ->
          local_b = B{ y: 0 } @locked;
          WITH EXCLUSIVE local_b AS bb { bb.y = bb.y + 1; }
          RETURN;
        END

        FN useA() RETURNS !Void ->
          local_a = A{ x: 0 } @locked;
          WITH EXCLUSIVE local_a AS aa { aa.x = aa.x + 1; }
          RETURN;
        END

        FN ab() RETURNS !Void ->
          local_a = A{ x: 0 } @locked;
          WITH EXCLUSIVE local_a AS aa { useB(); }
          RETURN;
        END

        FN ba() RETURNS !Void ->
          local_b = B{ y: 0 } @locked;
          WITH EXCLUSIVE local_b AS bb { useA(); }
          RETURN;
        END

        FN main() RETURNS Void -> ab(); ba(); RETURN; END
      FLUX
      expect { run(src) }.to raise_error(/lock cycle/)
    end

    it "accepts consistent-order held-during-call on two types (no cycle)" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }

        FN useB() RETURNS !Void ->
          local_b = B{ y: 0 } @locked;
          WITH EXCLUSIVE local_b AS bb { bb.y = bb.y + 1; }
          RETURN;
        END

        FN ab() RETURNS !Void ->
          local_a = A{ x: 0 } @locked;
          WITH EXCLUSIVE local_a AS aa { useB(); }
          RETURN;
        END

        FN main() RETURNS Void -> ab(); RETURN; END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects same-type nested acquire across a function-call boundary" do
      src = <<~FLUX
        STRUCT C { v: Int64 }

        FN useC() RETURNS !Void ->
          other_c = C{ v: 0 } @locked;
          WITH EXCLUSIVE other_c AS cc { cc.v = cc.v + 1; }
          RETURN;
        END

        FN holder() RETURNS !Void ->
          my_c = C{ v: 0 } @locked;
          WITH EXCLUSIVE my_c AS cc { useC(); }
          RETURN;
        END

        FN main() RETURNS Void -> holder(); RETURN; END
      FLUX
      expect { run(src) }.to raise_error(/self-loop|lock cycle/)
    end

    it "accepts cross-fn cycle when both participating sites carry POSSIBLE_LOCK_CYCLE" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }

        FN useB() RETURNS !Void ->
          local_b = B{ y: 0 } @locked;
          WITH EXCLUSIVE local_b AS bb { bb.y = bb.y + 1; }
          RETURN;
        END

        FN useA() RETURNS !Void ->
          local_a = A{ x: 0 } @locked;
          WITH EXCLUSIVE local_a AS aa { aa.x = aa.x + 1; }
          RETURN;
        END

        FN ab() RETURNS !Void ->
          local_a = A{ x: 0 } @locked;
          WITH POSSIBLE_LOCK_CYCLE EXCLUSIVE local_a AS aa { useB(); }
          RETURN;
        END

        FN ba() RETURNS !Void ->
          local_b = B{ y: 0 } @locked;
          WITH POSSIBLE_LOCK_CYCLE EXCLUSIVE local_b AS bb { useA(); }
          RETURN;
        END

        FN main() RETURNS Void -> ab(); ba(); RETURN; END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "permits calls that don't take the held lock's type" do
      src = <<~FLUX
        STRUCT A { x: Int64 }

        FN pure() RETURNS Int64 -> RETURN 42; END

        FN holder() RETURNS !Void ->
          local_a = A{ x: 0 } @locked;
          WITH EXCLUSIVE local_a AS aa { aa.x = pure(); }
          RETURN;
        END

        FN main() RETURNS Void -> holder(); RETURN; END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects intra-fn AB/BA cycle on different types, different variables" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }

        FN cycleInOne() RETURNS !Void ->
          a1 = A{ x: 0 } @locked;
          b1 = B{ y: 0 } @locked;
          WITH EXCLUSIVE a1 AS aa { WITH EXCLUSIVE b1 AS bb { bb.y = aa.x; } }
          WITH EXCLUSIVE b1 AS bb { WITH EXCLUSIVE a1 AS aa { aa.x = bb.y; } }
          RETURN;
        END

        FN main() RETURNS Void -> cycleInOne(); RETURN; END
      FLUX
      expect { run(src) }.to raise_error(/lock cycle/)
    end
  end

  describe "ON Sym handler reachability" do
    it "rejects ON LockCycle when no cycle is possible" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON LockCycle PASS
      FLUX
      expect { run(src) }.to raise_error(/trying to handle `LockCycle` which is not a possible error/)
    end

    it "rejects ON Deadlock when no self-loop is possible" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Deadlock PASS
      FLUX
      expect { run(src) }.to raise_error(/trying to handle `Deadlock` which is not a possible error/)
    end

    it "accepts ON LockTimeout (always a possible error)" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON LockTimeout PASS
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts ON Transient even when LockCycle is impossible (LockTimeout keeps Transient alive)" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON Transient RAISE
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts ON LockCycle when an opt-out reintroduces the cycle" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }

        FN useB() RETURNS !Void ->
          local_b = B{ y: 0 } @locked;
          WITH EXCLUSIVE local_b AS bb { bb.y = bb.y + 1; }
          RETURN;
        END

        FN useA() RETURNS !Void ->
          local_a = A{ x: 0 } @locked;
          WITH EXCLUSIVE local_a AS aa { aa.x = aa.x + 1; }
          RETURN;
        END

        FN ab() RETURNS !Void ->
          local_a = A{ x: 0 } @locked;
          WITH POSSIBLE_LOCK_CYCLE EXCLUSIVE local_a AS aa {
            useB();
          } ON LockCycle PASS
          RETURN;
        END

        FN ba() RETURNS !Void ->
          local_b = B{ y: 0 } @locked;
          WITH POSSIBLE_LOCK_CYCLE EXCLUSIVE local_b AS bb { useA(); }
          RETURN;
        END

        FN main() RETURNS Void -> ab(); ba(); RETURN; END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects multi-selector clause when every type in the list is impossible" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked;
        WITH EXCLUSIVE c AS inner { inner.v = 1; } ON LockCycle, Deadlock PASS
      FLUX
      expect { run(src) }.to raise_error(/not a possible error/)
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 3: @locked(rank: N) / @writeLocked(rank: N) DAG enforcement
  # ---------------------------------------------------------------------------

  describe "lock rank annotation + ordering" do
    it "parses and accepts @locked(rank: N)" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked(rank: 1);
        WITH EXCLUSIVE c AS inner { inner.v = 1; }
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "parses and accepts @writeLocked(rank: N)" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @writeLocked(rank: 1);
        WITH EXCLUSIVE c AS inner { inner.v = 1; }
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts nested acquire in strictly ascending rank order (@locked)" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }
        a = A{ x: 0 } @locked(rank: 1);
        b = B{ y: 0 } @locked(rank: 2);
        WITH EXCLUSIVE a AS aa {
          WITH EXCLUSIVE b AS bb { bb.y = aa.x; }
        }
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts nested acquire in ascending rank on @writeLocked" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }
        a = A{ x: 0 } @writeLocked(rank: 1);
        b = B{ y: 0 } @writeLocked(rank: 2);
        WITH EXCLUSIVE a AS aa {
          WITH EXCLUSIVE b AS bb { bb.y = aa.x; }
        }
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects nested acquire in descending rank order" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }
        a = A{ x: 0 } @locked(rank: 2);
        b = B{ y: 0 } @locked(rank: 1);
        WITH EXCLUSIVE a AS aa {
          WITH EXCLUSIVE b AS bb { bb.y = aa.x; }
        }
      FLUX
      expect { run(src) }.to raise_error(/Lock rank violation.*rank 1.*rank 2/)
    end

    it "rejects equal ranks on the same acquire path" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }
        a = A{ x: 0 } @locked(rank: 1);
        b = B{ y: 0 } @locked(rank: 1);
        WITH EXCLUSIVE a AS aa {
          WITH EXCLUSIVE b AS bb { bb.y = aa.x; }
        }
      FLUX
      expect { run(src) }.to raise_error(/Lock rank violation/)
    end

    it "rejects inconsistent rank declarations for the same type" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        a = C{ v: 0 } @locked(rank: 1);
        b = C{ v: 0 } @locked(rank: 2);
      FLUX
      expect { run(src) }.to raise_error(/Inconsistent lock rank for type 'C'/)
    end

    it "ignores unranked types in rank ordering check" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }
        a = A{ x: 0 } @locked(rank: 5);
        b = B{ y: 0 } @locked;
        WITH EXCLUSIVE a AS aa {
          WITH EXCLUSIVE b AS bb { bb.y = aa.x; }
        }
      FLUX
      # a is rank 5, b is unranked — rank check skips this pair.
      # (Phase 2 graph detection still runs but this single direction has no cycle.)
      expect { run(src) }.not_to raise_error
    end

    it "accepts a three-rank ascending chain" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }
        STRUCT D { z: Int64 }
        a = A{ x: 0 } @locked(rank: 1);
        b = B{ y: 0 } @locked(rank: 2);
        d = D{ z: 0 } @locked(rank: 3);
        WITH EXCLUSIVE a AS aa {
          WITH EXCLUSIVE b AS bb {
            WITH EXCLUSIVE d AS dd { dd.z = aa.x + bb.y; }
          }
        }
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects a three-rank chain with a dip in the middle" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }
        STRUCT D { z: Int64 }
        a = A{ x: 0 } @locked(rank: 1);
        b = B{ y: 0 } @locked(rank: 3);
        d = D{ z: 0 } @locked(rank: 2);
        WITH EXCLUSIVE a AS aa {
          WITH EXCLUSIVE b AS bb {
            WITH EXCLUSIVE d AS dd { dd.z = aa.x + bb.y; }
          }
        }
      FLUX
      expect { run(src) }.to raise_error(/Lock rank violation.*rank 2.*rank 3/)
    end

    it "downgrades rank violation to a [Note] when POSSIBLE_LOCK_CYCLE is set" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }
        a = A{ x: 0 } @locked(rank: 2);
        b = B{ y: 0 } @locked(rank: 1);
        WITH EXCLUSIVE a AS aa {
          WITH POSSIBLE_LOCK_CYCLE EXCLUSIVE b AS bb { bb.y = aa.x; }
        }
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects descending rank on @writeLocked" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }
        a = A{ x: 0 } @writeLocked(rank: 2);
        b = B{ y: 0 } @writeLocked(rank: 1);
        WITH EXCLUSIVE a AS aa {
          WITH EXCLUSIVE b AS bb { bb.y = aa.x; }
        }
      FLUX
      expect { run(src) }.to raise_error(/Lock rank violation/)
    end

    it "accepts negative ranks (they still define a total order)" do
      src = <<~FLUX
        STRUCT A { x: Int64 }
        STRUCT B { y: Int64 }
        a = A{ x: 0 } @locked(rank: -5);
        b = B{ y: 0 } @locked(rank: 0);
        WITH EXCLUSIVE a AS aa {
          WITH EXCLUSIVE b AS bb { bb.y = aa.x; }
        }
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects malformed @locked(foo: 1) — 'rank' keyword required" do
      src = <<~FLUX
        STRUCT C { v: Int64 }
        c = C{ v: 0 } @locked(foo: 1);
      FLUX
      expect { run(src) }.to raise_error(ParserError, /Expected 'rank' keyword/)
    end

    it "rejects inconsistent rank declarations with the error anchored at the second declaration" do
      # Inconsistent rank is reported at the second (diverging) declaration,
      # not the first. This matters: the programmer reading the error needs
      # the line of the NEW decl that disagrees with the prior contract.
      src = <<~FLUX
        STRUCT C { v: Int64 }
        a = C{ v: 0 } @locked(rank: 1);
        b = C{ v: 0 } @locked(rank: 2);
      FLUX
      expect { run(src) }.to raise_error { |e|
        # Message carries both ranks so the programmer can see the conflict.
        expect(e.message).to match(/Inconsistent lock rank for type 'C'.*rank 1.*rank 2/)
        # Annotator anchors errors by embedding "(Line N)" — the error must
        # point at line 3 (the second declaration), not line 2 (the first).
        expect(e.message).to include("(Line 3)")
        expect(e.message).not_to include("(Line 2)")
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Stdlib error_kind / error_type stamping on call nodes
  # ---------------------------------------------------------------------------
  # Verifies the annotator propagates a stdlib entry's :error_kind / :error_type
  # metadata onto the AST call node. The plumbing is wired through three sites
  # (FuncCall dispatch in resolve_call, MethodCall UFCS in visit_MethodCall,
  # method_analysis for collection methods) and has no coverage without this
  # spec: today no stdlib entry actually sets these fields, so silent regressions
  # in the plumbing are invisible. We monkey-patch writeFile (a can_fail stdlib
  # entry) for the duration of each example, reverting after.

  describe "stdlib error_kind / error_type stamping" do
    let(:entry) { STD_LIB["writeFile"] }

    around do |example|
      # Deep save + restore so the registry mutation doesn't leak across tests.
      saved = entry.dup
      entry[:error_kind] = :Transient
      entry[:error_type] = :LockTimeout
      begin
        example.run
      ensure
        entry.replace(saved)
      end
    end

    def find_call(ast, name)
      # Walk top-level statements looking for a call with the given name.
      # writeFile("p","c"); becomes a FuncCall statement (or wrapped if it
      # can fail and the fn return is !Void — try/OR form).
      ast.statements.each do |s|
        return s if s.is_a?(AST::FuncCall) && s.name == name
        if s.is_a?(AST::BinaryOp) && s.left.is_a?(AST::FuncCall) && s.left.name == name
          return s.left
        end
      end
      nil
    end

    it "stamps error_kind and error_type from the matched stdlib entry" do
      src = 'writeFile("p", "c") OR 0;'
      call = find_call(run(src), "writeFile")
      expect(call).not_to be_nil
      expect(call.error_kind).to eq(:Transient)
      expect(call.error_type).to eq(:LockTimeout)
    end

    it "leaves error_kind / error_type nil when the entry has no metadata" do
      entry.delete(:error_kind)
      entry.delete(:error_type)
      src = 'writeFile("p", "c") OR 0;'
      call = find_call(run(src), "writeFile")
      expect(call).not_to be_nil
      expect(call.error_kind).to be_nil
      expect(call.error_type).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # RAISE grammar + auto-registration
  # ---------------------------------------------------------------------------
  # Verifies the unified RAISE forms and the collision / first-use rules
  # in AST.register_type! as driven by the annotator's visit_Raise.

  describe "RAISE grammar + registry auto-registration" do
    it "accepts `RAISE Kind, Type, \"msg\"` as first use and registers the mapping" do
      src = <<~FLUX
        FN go() RETURNS !Void -> RAISE Input, BadParse, "oops"; END
      FLUX
      expect { run(src) }.not_to raise_error
      expect(AST.kind_of_type(:BadParse)).to eq(:Input)
    end

    it "accepts type-only `RAISE Type, \"msg\"` once registered" do
      src = <<~FLUX
        FN first()  RETURNS !Void -> RAISE Input, TokErr, "bad token"; END
        FN second() RETURNS !Void -> RAISE TokErr, "another"; END
      FLUX
      expect { run(src) }.not_to raise_error
      expect(AST.kind_of_type(:TokErr)).to eq(:Input)
    end

    it "rejects type-only RAISE for an unregistered type" do
      src = <<~FLUX
        FN go() RETURNS !Void -> RAISE UnknownErr, "oops"; END
      FLUX
      expect { run(src) }.to raise_error(/Error type 'UnknownErr' is not registered/)
    end

    it "reports kind collision with the first-registration line" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input,    DupErr, "first"; END
        FN b() RETURNS !Void -> RAISE NotFound, DupErr, "second"; END
      FLUX
      expect { run(src) }.to raise_error(/'DupErr' is already mapped to kind 'Input'.*line 1/)
    end

    it "accepts the same type with the same kind at multiple sites" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input, MaybeOk, "first"; END
        FN b() RETURNS !Void -> RAISE Input, MaybeOk, "second"; END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects shadowing a stdlib type name with a different kind" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input, LockTimeout, "bad"; END
      FLUX
      expect { run(src) }.to raise_error(/'LockTimeout' is reserved by the stdlib as kind 'Transient'/)
    end

    it "accepts re-using a stdlib type name with its stdlib kind (no-op)" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Transient, LockTimeout, "bad"; END
      FLUX
      expect { run(src) }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # CATCH grammar — every form
  # ---------------------------------------------------------------------------
  # The unified CATCH surface:
  #   CATCH Kind                          — by kind
  #   CATCH Kind WITH(Type)               — kind + single type
  #   CATCH Kind WITH(T1, T2, ...)        — kind + multi-type filter
  #   CATCH Type                          — direct type match (kind inferred)
  # Every form feeds the annotator's resolve_catch_clause!, which must
  # populate clause[:kind] + clause[:error_names] so mir-lowering can
  # emit the right dispatch.

  describe "CATCH grammar — kind-only form" do
    it "accepts CATCH Kind" do
      src = <<~FLUX
        FN go(mode: Int64) RETURNS !Int64 ->
          IF mode == 0 THEN RAISE Input, "bad"; END
          RETURN 1;
        CATCH Input
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts CATCH of every registered kind" do
      AST::ERROR_KINDS.each do |kind|
        src = <<~FLUX
          FN go() RETURNS Int64 ->
            RAISE #{kind}, "bad";
            RETURN 1;
          CATCH #{kind}
            RETURN -1;
          END
        FLUX
        expect { run(src) }.not_to(raise_error, "failed for kind #{kind}")
      end
    end
  end

  describe "CATCH grammar — kind + type (legacy WITH form)" do
    it "accepts CATCH Kind WITH(Type) for a type registered at a prior RAISE" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input, ParseError, "bad"; END
        FN b() RETURNS !Int64 ->
          a() OR RAISE;
          RETURN 1;
        CATCH Input WITH(ParseError)
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts CATCH Kind WITH(Type) when the RAISE appears LATER in source (pre-pass seeding)" do
      src = <<~FLUX
        FN b() RETURNS !Int64 ->
          a() OR RAISE;
          RETURN 1;
        CATCH Input WITH(LateType)
          RETURN -1;
        END
        FN a() RETURNS !Void -> RAISE Input, LateType, "bad"; END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts CATCH Kind WITH(Type) even when Type's registered kind differs (dead match, not error)" do
      # Permissive semantics: CATCH accepts the mix; the AND between
      # items and filters means the match is just unreachable at
      # runtime. Programmer's responsibility — enables multi-item
      # CATCH without kind-compat contortions.
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input, MyErr, "bad"; END
        FN b() RETURNS !Int64 ->
          a() OR RAISE;
          RETURN 1;
        CATCH NotFound WITH(MyErr)
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects CATCH Kind WITH(UnknownType) for an unregistered type" do
      src = <<~FLUX
        FN go() RETURNS Int64 ->
          RAISE Input, "bad";
          RETURN 1;
        CATCH Input WITH(NeverRaised)
          RETURN -1;
        END
      FLUX
      expect { run(src) }.to raise_error(/'NeverRaised' is not registered/)
    end

    it "rejects CATCH with an unknown kind" do
      src = <<~FLUX
        FN go() RETURNS Int64 -> RETURN 1;
        CATCH Nope
          RETURN -1;
        END
      FLUX
      # 'Nope' isn't a kind and isn't a registered type either -> unknown type.
      expect { run(src) }.to raise_error(/is not registered/)
    end
  end

  describe "CATCH grammar — multi-type WITH" do
    it "accepts CATCH Kind WITH(T1, T2) when both types are Input" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input, ParseErr,   "p"; END
        FN b() RETURNS !Void -> RAISE Input, InvalidJson, "j"; END
        FN c() RETURNS !Int64 ->
          a() OR RAISE;
          b() OR RAISE;
          RETURN 1;
        CATCH Input WITH(ParseErr, InvalidJson)
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts multi-type WITH even when one of the types has a different kind (Miss becomes a dead filter)" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input,    Ok,   "p"; END
        FN b() RETURNS !Void -> RAISE NotFound, Miss, "m"; END
        FN c() RETURNS !Int64 ->
          a() OR RAISE;
          RETURN 1;
        CATCH Input WITH(Ok, Miss)
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts multi-type WITH with three types sharing a kind" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input, A, "a"; END
        FN b() RETURNS !Void -> RAISE Input, B, "b"; END
        FN c() RETURNS !Void -> RAISE Input, C, "c"; END
        FN handler() RETURNS !Int64 ->
          a() OR RAISE;
          RETURN 1;
        CATCH Input WITH(A, B, C)
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end
  end

  describe "CATCH grammar — direct-type form" do
    it "accepts CATCH Type when Type is registered by a RAISE in the same program" do
      src = <<~FLUX
        FN fail() RETURNS !Void -> RAISE Input, DirectErr, "bad"; END
        FN go() RETURNS !Int64 ->
          fail() OR RAISE;
          RETURN 1;
        CATCH DirectErr
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts CATCH Type for a stdlib-registered type" do
      src = <<~FLUX
        FN maybeTimeout() RETURNS !Void -> RAISE Transient, LockTimeout, "slow"; END
        FN go() RETURNS !Int64 ->
          maybeTimeout() OR RAISE;
          RETURN 1;
        CATCH LockTimeout
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects CATCH Type for an unregistered type" do
      src = <<~FLUX
        FN go() RETURNS Int64 -> RETURN 1;
        CATCH NeverUsed
          RETURN -1;
        END
      FLUX
      expect { run(src) }.to raise_error(/'NeverUsed' is not registered/)
    end
  end

  describe "CATCH grammar — multi-item (comma-separated) CATCH" do
    it "accepts CATCH Kind1, Kind2 (multi-kind)" do
      src = <<~FLUX
        FN failInput() RETURNS !Void -> RAISE Input, "b"; END
        FN failNF()    RETURNS !Void -> RAISE NotFound, "b"; END
        FN go(mode: Int64) RETURNS !Int64 ->
          IF mode == 1 THEN failInput() OR RAISE; END
          IF mode == 2 THEN failNF()    OR RAISE; END
          RETURN 1;
        CATCH Input, NotFound
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts CATCH Type1, Type2 (multi-type)" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input, A, "a"; END
        FN b() RETURNS !Void -> RAISE Input, B, "b"; END
        FN go() RETURNS !Int64 ->
          a() OR RAISE;
          RETURN 1;
        CATCH A, B
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts CATCH Kind1, Type2 (mixed kind + type, different kinds OK)" do
      # Type2 has kind NotFound; CATCH also has kind Input.  This is
      # explicitly permitted: the match ORs the two checks so each
      # lives in its own scope.
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE NotFound, MissingItem, "m"; END
        FN go() RETURNS !Int64 ->
          a() OR RAISE;
          RETURN 1;
        CATCH Input, MissingItem
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects an unregistered type anywhere in the item list" do
      src = <<~FLUX
        FN go() RETURNS Int64 -> RETURN 1;
        CATCH Input, NeverDefined
          RETURN -1;
        END
      FLUX
      expect { run(src) }.to raise_error(/'NeverDefined' is not registered/)
    end
  end

  describe "CATCH grammar — WITH(message) and mixed type/message filter" do
    it "accepts CATCH Kind WITH(\"some message\") as a pure message match" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input, "bad header"; END
        FN go() RETURNS !Int64 ->
          a() OR RAISE;
          RETURN 1;
        CATCH Input WITH("bad header")
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts CATCH Kind WITH(Type, \"message\") mixed filter" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input, ParseErr, "bad"; END
        FN go() RETURNS !Int64 ->
          a() OR RAISE;
          RETURN 1;
        CATCH Input WITH(ParseErr, "bad header")
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "accepts CATCH Type WITH(\"msg\") — direct type + message filter" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input, MyErr, "nope"; END
        FN go() RETURNS !Int64 ->
          a() OR RAISE;
          RETURN 1;
        CATCH MyErr WITH("nope")
          RETURN -1;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end

    it "rejects WITH() with something that is neither a TYPE_ID nor a string" do
      src = <<~FLUX
        FN go() RETURNS Int64 -> RETURN 1;
        CATCH Input WITH(42)
          RETURN -1;
        END
      FLUX
      expect { run(src) }.to raise_error(ParserError, /Expected a type name .* or a string/)
    end
  end

  describe "OR EXIT grammar — unified with inherit semantics" do
    def outer_wrap(inner)
      <<~FLUX
        FN fail() RETURNS !Int64 -> RAISE Input, OrigErr, "original"; RETURN 0; END
        FN try_fail() RETURNS !Int64 ->
          v: Int64 = fail() #{inner};
          RETURN v;
        CATCH Input
          RETURN -1;
        CATCH NotFound
          RETURN -2;
        CATCH System
          RETURN -3;
        CATCH Transient
          RETURN -4;
        DEFAULT
          RETURN -99;
        END
      FLUX
    end

    it "parses OR EXIT \"msg\" (message only)" do
      expect { run(outer_wrap('OR EXIT "replaced"')) }.not_to raise_error
    end

    it "parses OR EXIT Kind (kind only)" do
      expect { run(outer_wrap('OR EXIT NotFound')) }.not_to raise_error
    end

    it "parses OR EXIT Kind, \"msg\"" do
      expect { run(outer_wrap('OR EXIT NotFound, "msg"')) }.not_to raise_error
    end

    it "parses OR EXIT Kind, Type (registers the type on first use)" do
      src = outer_wrap('OR EXIT NotFound, SomeNew')
      expect { run(src) }.not_to raise_error
      expect(AST.kind_of_type(:SomeNew)).to eq(:NotFound)
    end

    it "parses OR EXIT Kind, Type, \"msg\" (full override)" do
      src = outer_wrap('OR EXIT System, SysIssue, "whoops"')
      expect { run(src) }.not_to raise_error
      expect(AST.kind_of_type(:SysIssue)).to eq(:System)
    end

    it "parses OR EXIT Type (kind auto-resolved from the registry)" do
      # OrigErr was registered as Input by the fail() helper in outer_wrap.
      src = outer_wrap('OR EXIT OrigErr, "x"')
      expect { run(src) }.not_to raise_error
    end

    it "rejects OR EXIT Type when Type is unregistered (no kind to infer)" do
      src = outer_wrap('OR EXIT UnknownType, "x"')
      expect { run(src) }.to raise_error(/Error type 'UnknownType' is not registered/)
    end

    it "registers a new (Kind, Type) at an OR EXIT site (first-use behavior)" do
      src = outer_wrap('OR EXIT Input, ExitRegistered, "msg"')
      expect { run(src) }.not_to raise_error
      expect(AST.kind_of_type(:ExitRegistered)).to eq(:Input)
    end

    it "rejects OR EXIT Kind, Type when Type is already registered with a different kind" do
      src = <<~FLUX
        FN seed()  RETURNS !Int64 -> RAISE Input,    Fixed, "first"; RETURN 0; END
        FN other() RETURNS !Int64 -> RAISE NotFound, "x"; RETURN 0; END
        FN go() RETURNS Int64 ->
          v: Int64 = other() OR EXIT NotFound, Fixed, "conflict";
          RETURN v;
        CATCH NotFound
          RETURN -1;
        END
      FLUX
      expect { run(src) }.to raise_error(/'Fixed' is already mapped to kind 'Input'/)
    end
  end

  describe "CATCH grammar — multiple clauses + DEFAULT" do
    it "accepts multiple CATCH clauses mixing kind-only, kind+WITH, and direct-type" do
      src = <<~FLUX
        FN a() RETURNS !Void -> RAISE Input,    Bad,     "b"; END
        FN b() RETURNS !Void -> RAISE Transient, Flaky,  "f"; END
        FN go() RETURNS !Int64 ->
          a() OR RAISE;
          RETURN 1;
        CATCH Input WITH(Bad)
          RETURN -1;
        CATCH Flaky
          RETURN -2;
        CATCH NotFound
          RETURN -3;
        DEFAULT
          RETURN -99;
        END
      FLUX
      expect { run(src) }.not_to raise_error
    end
  end

  # ============================================================
  # Annotated examples for `clear explain` / LSP hover.
  # Each describe below pairs a failing form (the bad case) with a
  # passing form (the good case), so DiagnosticExamples can pull
  # both from the registry code's natural home spec.
  # ============================================================

  # @example_for: WITH_EXCLUSIVE_NEEDS_LOCK
  # @fix: WITH EXCLUSIVE acquires a Mutex / RwLock. Add `@locked`
  # @fix: (single-writer Mutex) or `@writeLocked` (RwLock — readers
  # @fix: coexist via WITH READ; writers via WITH EXCLUSIVE) to the
  # @fix: binding's declaration so the lock is there to acquire.
  describe ":WITH_EXCLUSIVE_NEEDS_LOCK — WITH EXCLUSIVE on a non-lock binding" do
    it "raises when the binding has no @locked / @writeLocked sigil" do
      expect {
        run(<<~CLEAR)
          STRUCT Counter { value: Float64 }
          FN main!() RETURNS !Void ->
            c = Counter{ value: 0 };
            WITH EXCLUSIVE c AS x { _ = x.value; }
            RETURN;
          END
        CLEAR
      }.to raise_error(/EXCLUSIVE capability requires a @locked or @writeLocked/)
    end

    it "compiles when the binding is @locked" do
      run(<<~CLEAR)
        STRUCT Counter { value: Float64 }
        FN main!() RETURNS !Void ->
          c = Counter{ value: 0 } @locked;
          WITH EXCLUSIVE c AS x { _ = x.value; }
          RETURN;
        END
      CLEAR
    end
  end

  # @example_for: WITH_CANNOT_INFER_CAP
  # @fix: Plain `WITH x` infers the capability from x's sigil. When
  # @fix: x has no recognised capability, add one at its declaration
  # @fix: (e.g. `@multiowned`, `@shared`, `@locked`, `@writeLocked`)
  # @fix: so the WITH knows how to unwrap it.
  describe ":WITH_CANNOT_INFER_CAP — plain WITH on a sigil-less binding" do
    it "raises when the source has no capability to infer from" do
      expect {
        run(<<~CLEAR)
          STRUCT Counter { value: Float64 }
          FN main() RETURNS Void ->
            c = Counter{ value: 0 };
            WITH c AS x { _ = x.value; }
            RETURN;
          END
        CLEAR
      }.to raise_error(/cannot infer capability/i)
    end

    it "compiles when the source carries `@multiowned`" do
      run(<<~CLEAR)
        STRUCT Counter { value: Float64 }
        FN main() RETURNS Void ->
          c = Counter{ value: 0 } @multiowned;
          WITH c { _ = c.value; }
          RETURN;
        END
      CLEAR
    end
  end

end
