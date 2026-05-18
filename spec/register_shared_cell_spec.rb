require "rspec"
require "stringio"
require_relative "../src/backends/compiler_frontend"
require_relative "../src/mir/mir_lowering"
require_relative "../src/mir/mir_checker"
require_relative "../src/backends/importer"
require_relative "../examples/minivm/register_bc_emitter"

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
      low = MIRLowering.new(struct_schemas: fe.struct_schemas, enum_schemas: fe.enum_schemas,
                            union_schemas: fe.union_schemas, fn_sigs: fe.fn_sigs,
                            moved_guard_info: fe.moved_guard_info, importer: imp,
                            source_dir: Dir.pwd, target: :bc)
      prog = low.lower_program(fe.ast)
      MIRChecker.new.check_program!(prog, strict: true)
      RegisterBcEmitter.new(fe, source: src, importer: imp).compile(prog).ops
    ensure
      $stdout, $stderr = out, err
    end
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
end
