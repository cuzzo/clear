require "rspec"
require "stringio"
require_relative "../src/backends/compiler_frontend"
require_relative "../src/mir/mir_lowering"
require_relative "../src/mir/mir_checker"
require_relative "../src/backends/importer"
require_relative "../examples/minivm/register_bc_emitter"

RSpec.describe "register-VM :fiber bg_mode (zero-capture slice)" do
  SRC = <<~CHT
    FN main() RETURNS !Void ->
        f: ~Int64 = BG { a: Int64 = 40_i64; a + 2_i64; };
        n: Int64 = NEXT f;
        ASSERT n == 42_i64, "zero-capture fiber";
        RETURN;
    END
  CHT

  def emit(bg_mode)
    prev = ENV["CLEAR_REGISTER_BG_MODE"]
    ENV["CLEAR_REGISTER_BG_MODE"] = bg_mode
    imp = ModuleImporter.new(base_dir: Dir.pwd, use_mir: true)
    out, err = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    begin
      fe = CompilerFrontend.compile(SRC, importer: imp, source_dir: Dir.pwd)
      low = MIRLowering.new(struct_schemas: fe.struct_schemas, enum_schemas: fe.enum_schemas,
                            union_schemas: fe.union_schemas, fn_sigs: fe.fn_sigs,
                            moved_guard_info: fe.moved_guard_info, importer: imp,
                            source_dir: Dir.pwd, target: :bc)
      prog = low.lower_program(fe.ast)
      MIRChecker.new.check_program!(prog, strict: true)
      RegisterBcEmitter.new(fe, source: SRC, importer: imp).compile(prog).ops
    ensure
      $stdout, $stderr = out, err
      ENV["CLEAR_REGISTER_BG_MODE"] = prev
    end
  end

  let(:bgspawn) { MiniVM::Register::OpcodeSpec::OPCODES.find { |o| o.name == :BGSPAWN }.code }
  let(:fnexti)  { MiniVM::Register::OpcodeSpec::OPCODES.find { |o| o.name == :FNEXTI }.code }

  it ":fiber emits BGSPAWN + FNEXTI" do
    ops = emit("fiber")
    expect(ops).to include(bgspawn)
    expect(ops).to include(fnexti)
  end

  it ":inline (default) emits neither" do
    ops = emit("inline")
    expect(ops).not_to include(bgspawn)
    expect(ops).not_to include(fnexti)
  end
end
