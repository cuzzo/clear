require "rspec"
require "stringio"
require_relative "../ruby/compiler/compiler_frontend" unless defined?(CompilerFrontend)
require_relative "../ruby/mir/mir_lowering" unless defined?(MIRLowering::OwnershipSurfaceScan)
require_relative "../ruby/mir/mir_checker" unless defined?(MIRChecker::FsmStructureError)
require_relative "../ruby/compiler/module_importer" unless defined?(ModuleImporter)
require_relative "../../examples/minivm/register_bc_emitter"

RSpec.describe "register-VM @shared:locked scalar store cell" do
  LOCKED_SRC = <<~CHT
    STRUCT Counter { value: Int64 }
    FN main() RETURNS Void ->
        c = Counter{ value: 7 } @shared:locked;
        WITH EXCLUSIVE c AS inner { inner.value = inner.value + 35; }
        WITH c AS inner { ASSERT inner.value == 42, "cell"; }
        RETURN;
    END
  CHT

  PLAIN_SRC = <<~CHT
    STRUCT Counter { value: Int64 }
    FN main() RETURNS Void ->
        c = Counter{ value: 7 };
        ASSERT c.value == 7, "plain";
        RETURN;
    END
  CHT

  def emit(src)
    imp = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    out, err = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    begin
      fe = CompilerFrontend.compile(src, importer: imp, source_dir: Dir.pwd)
      low = MIRLowering.new(input: MIRLoweringInput.new(struct_schemas: fe.struct_schemas, enum_schemas: fe.enum_schemas,
                            union_schemas: fe.union_schemas, fn_sigs: fe.fn_sigs,
                            moved_guard_info: fe.moved_guard_info, importer: imp,
                            source_dir: Dir.pwd, target: :bc))
      prog = low.lower_program(fe.ast)
      MIRChecker.new.check_program!(prog, strict: true)
      RegisterBcEmitter.new(fe, source: src, importer: imp).compile(prog).ops
    ensure
      $stdout, $stderr = out, err
    end
  end

  def emit_fixture(name)
    emit(File.read(File.expand_path("../../transpile-tests/#{name}", __dir__)))
  end

  def code(name)
    MiniVM::Register::OpcodeSpec::OPCODES.find { |o| o.name == name }.code
  end

  it "lowers a single-i64-field @shared:locked struct to SCELL opcodes" do
    ops = emit(LOCKED_SRC)
    expect(ops).to include(code(:SCELLNEW))
    expect(ops).to include(code(:SCELLSETI))
    expect(ops).to include(code(:SCELLGETI))
  end

  it "leaves a plain struct field in a register (no SCELL)" do
    ops = emit(PLAIN_SRC)
    expect(ops).not_to include(code(:SCELLNEW))
    expect(ops).not_to include(code(:SCELLSETI))
    expect(ops).not_to include(code(:SCELLGETI))
  end

  it "brackets the guest WITH block with LOCKACQ/LOCKREL" do
    ops = emit(LOCKED_SRC)
    acq = ops.index(code(:LOCKACQ))
    rel = ops.rindex(code(:LOCKREL))
    expect(acq).not_to be_nil
    expect(rel).not_to be_nil
    expect(acq).to be < rel
  end

  it "emits no lock ops for a plain struct" do
    ops = emit(PLAIN_SRC)
    expect(ops).not_to include(code(:LOCKACQ))
    expect(ops).not_to include(code(:LOCKREL))
  end

  FIBER_SHARE_SRC = <<~CHT
    STRUCT Counter { value: Int64 }
    FN main() RETURNS Void ->
        MUTABLE c = Counter{ value: 10 } @shared:locked;
        f: ~Int64 = BG {
            WITH EXCLUSIVE c AS inner { inner.value = inner.value + 5; }
            7_i64;
        };
        n: Int64 = NEXT f;
        ASSERT n == 7_i64, "ret";
        WITH c AS r { ASSERT r.value == 15, "shared"; }
        RETURN;
    END
  CHT

  it "marshals a cell-backed cap capture into the real fiber path (BGSPAWN+CAPGETI)" do
    ops = emit(FIBER_SHARE_SRC)
    expect(ops).to include(code(:BGSPAWN))
    expect(ops).to include(code(:CAPGETI))
    expect(ops).to include(code(:LOCKACQ))
  end

  VOID_FIBER_SRC = <<~CHT
    STRUCT Counter { value: Int64 }
    FN main() RETURNS Void ->
        MUTABLE c = Counter{ value: 0 } @shared:locked;
        a: ~Void = BG { WITH EXCLUSIVE c AS x { x.value = x.value + 1; } };
        b: ~Void = BG { WITH EXCLUSIVE c AS x { x.value = x.value + 1; } };
        NEXT a;
        NEXT b;
        WITH c AS r { ASSERT r.value == 2, "two"; }
        RETURN;
    END
  CHT

  it "runs a void-payload cap-capturing BG as a real fiber (BGSPAWN per BG)" do
    ops = emit(VOID_FIBER_SRC)
    expect(ops.count { |o| o == code(:BGSPAWN) }).to eq(2)
    expect(ops).to include(code(:CAPGETI))
    expect(ops).to include(code(:LOCKACQ))
  end

  # R6.6 regression lock: the canonical lock-contention test must
  # compile to real concurrent fibers, not the inline (vacuous) path.
  # If it regressed to inline, 263's `ASSERT timed_out == 1` would
  # pass for the wrong reason; this catches it at emit time.
  it "compiles 263_with_lock_contention to >= 2 real fibers" do
    src = File.read(File.expand_path("../../transpile-tests/263_with_lock_contention.cht", __dir__))
    ops = emit(src)
    expect(ops.count { |o| o == code(:BGSPAWN) }).to be >= 2
    expect(ops).to include(code(:LOCKACQ))
  end

  it "compiles typed versioned snapshot read and transaction MIR in the register backend" do
    expect { emit_fixture("328_versioned_snapshot_read.cht") }.not_to raise_error
    expect { emit_fixture("329_versioned_snapshot_mutable.cht") }.not_to raise_error
  end

  it "compiles typed multi-cell snapshot transaction MIR in the register backend" do
    expect { emit_fixture("330_versioned_multi_cell.cht") }.not_to raise_error
  end

  it "compiles typed WITH MATCH arm MIR in the register backend" do
    expect { emit_fixture("333_with_match_per_arm_dispatch.cht") }.not_to raise_error
  end

  it "compiles typed IfChain branch MIR in the register backend" do
    expect { emit_fixture("46_match_when.cht") }.not_to raise_error
  end

  it "compiles typed union MATCH MIR in the register backend" do
    expect { emit_fixture("52_union.cht") }.not_to raise_error
    expect { emit_fixture("57_match_union_capture.cht") }.not_to raise_error
  end

  it "compiles typed union MATCH struct payload MIR in the register backend" do
    expect { emit_fixture("69_inline_union_variants.cht") }.not_to raise_error
    expect { emit_fixture("107_match_destructure_bind.cht") }.not_to raise_error
  end

  it "compiles typed union variant construction in the register backend" do
    src = <<~CHT
      UNION Op { Add: Int64, Other }
      FN main() RETURNS Void ->
          o = Op{ Add: 1_i64 };
          RETURN;
      END
    CHT

    expect { emit(src) }.not_to raise_error
  end

  it "normalizes typed and legacy union variant rows for register metadata" do
    emitter = RegisterBcEmitter.allocate
    typed = MIR::UnionTypeVariant.new(name: "Some", zig_type: "T")
    legacy = { name: "None", zig_type: "void" }

    expect(emitter.send(:union_variant_name, typed)).to eq("Some")
    expect(emitter.send(:union_variant_zig_type, typed)).to eq("T")
    expect(emitter.send(:with_union_variant_zig_type, typed, "i64")).to have_attributes(name: "Some", zig_type: "i64")
    expect(emitter.send(:union_variant_name, legacy)).to eq("None")
    expect(emitter.send(:union_variant_zig_type, legacy)).to eq("void")
    expect(emitter.send(:with_union_variant_zig_type, legacy, "String")).to eq({ name: "None", zig_type: "String" })
  end
end
