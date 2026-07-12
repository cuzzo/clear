require "rspec"
require "tmpdir"
require "fileutils"
require_relative "../../examples/minivm/vm_golden_harness"

# `:integration` -- the per-fixture tests build CLEAR binaries
# (`_bc_runner` / `vm` / `vm_opt`) and run them. They share filesystem
# state (`examples/minivm/_register_*` artifact files baked into the
# cached runner binary), so parallel workers race. Skipped by default
# `prspec spec/` runs (which exclude :integration); included in
# `prspec spec/ --tag integration`.
RSpec.describe "MiniVM golden harness", :integration do
  let(:vm_tests_dir) { File.expand_path("../../examples/minivm/vm-tests", __dir__) }
  let(:case_dir) { File.join(vm_tests_dir, "basics") }
  let(:source_path) { File.join(case_dir, "return_i64.clear") }
  let(:source) { File.read(source_path) }
  let(:cases) { MiniVM::Golden::Case.all(vm_tests_dir) }

  def compile_or_skip(target, test_case)
    target.compile(test_case.source, source_dir: test_case.source_dir)
  rescue MiniVM::Golden::PendingTarget => e
    skip e.message
  end

  # MiniVM::Golden.*.run builds vm.clear to a native binary and executes
  # it. That compile times out on GitHub-hosted runners (same reason
  # the Register-VM allowlist CI job is disabled). The compile/snapshot
  # tests above use the in-process Ruby emitter and are unaffected.
  def skip_vm_binary_on_ci!
    skip "vm.clear native-binary execution times out on GitHub runners; run locally" if ENV["CI"]
  end

  def run_or_skip(target, test_case)
    target.run(test_case.source, source_dir: test_case.source_dir)
  rescue MiniVM::Golden::PendingTarget => e
    skip e.message
  end

  # Fixtures the register emitter doesn't yet handle. These keep their
  # `.clear` source committed so the gap is visible, but we skip generating
  # the per-fixture register-snapshot test for them (would produce a
  # pending). When the register emitter gains support for the underlying
  # feature, drop the fixture from this set and run
  # `examples/minivm/update_vm_golden.rb --target register` to record
  # the freshly-supported snapshot.
  REGISTER_PENDING_FIXTURES = %w[
    types/union_helper_arg_i64.clear
    types/union_payload_i64.clear
    types/union_tag_i64.clear
    values/map_contains_i64.clear
    values/map_delete_i64.clear
    values/list_index_f64.clear
    values/list_index_i64.clear
    values/list_set_f64.clear
    values/list_set_i64.clear
    values/string_length.clear
    values/union_helper_multi_return_i64.clear
  ].to_set.freeze

  MiniVM::Golden::Case.all(File.expand_path("../../examples/minivm/vm-tests", __dir__)).each do |test_case|
    rel = test_case.relative_path(File.expand_path("../../examples/minivm/vm-tests", __dir__))
    register_pending = REGISTER_PENDING_FIXTURES.include?(rel)

    it "compiles the stack VM bytecode snapshot for #{rel}" do
      bytecode = compile_or_skip(MiniVM::Golden.stack, test_case)
      expected_path = test_case.bytecode_snapshot_path(:stack)

      expect(File).to exist(expected_path)
      expect(MiniVM::Golden.normalize_snapshot(bytecode.snapshot)).to eq(MiniVM::Golden.normalize_snapshot(File.read(expected_path)))
    end

    unless register_pending
      it "compiles the register VM bytecode snapshot for #{rel}" do
        bytecode = compile_or_skip(MiniVM::Golden.register, test_case)
        expected_path = test_case.bytecode_snapshot_path(:register)

        expect(File).to exist(expected_path)
        expect(MiniVM::Golden.normalize_snapshot(bytecode.snapshot)).to eq(MiniVM::Golden.normalize_snapshot(File.read(expected_path)))
      end
    end

    it "records the expected observable output for #{rel}" do
      expected_path = test_case.output_path

      expect(File).to exist(expected_path)
      expect(File.read(expected_path).strip).not_to be_empty
    end

  end

  it "compiles the first register bytecode snapshot" do
    bytecode = MiniVM::Golden.register.compile(source, source_dir: case_dir)

    expect(bytecode.snapshot).to include("register instructions:\n0000 ICONST r0 0 ; I:42")
    expect(bytecode.snapshot).to include("0003 IRET r0")
  end

  # A function returning a non-scalar struct by value is a fundamental
  # register-emitter restriction ("only supports Int64 and Float64
  # returns"), not a fixture that keeps gaining support -- so it stays
  # a stable probe that the PendingTarget guard still fires (unsupported
  # features must raise, not silently emit wrong bytecode). Inline so it
  # is not coupled to the evolving vm-tests corpus.
  REGISTER_UNSUPPORTED_SRC = <<~CHT
    STRUCT P { x: Int64 }
    FN main() RETURNS P ->
        RETURN P{ x: 1_i64 };
    END
  CHT

  it "keeps unsupported register cases explicit but pending" do
    expect {
      MiniVM::Golden.register.compile(REGISTER_UNSUPPORTED_SRC, source_dir: Dir.pwd)
    }.to raise_error(MiniVM::Golden::PendingTarget, /support|returns/)
  end

  it "exposes runner hooks for both targets" do
    expect(MiniVM::Golden.stack).to respond_to(:run)
    expect(MiniVM::Golden.register).to respond_to(:run)
  end

  it "runs register bytecode through vm.clear for an Int64 return" do
    skip_vm_binary_on_ci!
    source = <<~CHT
      FN main() RETURNS Int64 ->
          RETURN 42_i64;
      END
    CHT

    result = MiniVM::Golden.register.run(source, source_dir: vm_tests_dir)

    expect(result.status).to eq(:pass)
    expect(result.output).to eq("42")
  end

  it "uses truncating signed integer division" do
    skip_vm_binary_on_ci!
    source = <<~CHT
      FN main() RETURNS Int64 ->
          RETURN -7_i64 / 2_i64;
      END
    CHT

    result = MiniVM::Golden.register.run(source, source_dir: vm_tests_dir)

    expect(result.status).to eq(:pass)
    expect(result.output).to eq("-3")
  end

  it "runs integer modulo bytecode" do
    skip_vm_binary_on_ci!
    source = <<~CHT
      FN main() RETURNS Int64 ->
          RETURN 200_i64 MOD 150_i64;
      END
    CHT

    result = MiniVM::Golden.register.run(source, source_dir: vm_tests_dir)

    expect(result.status).to eq(:pass)
    expect(result.output).to eq("50")
  end

  it "runs compiled register bytecode for the first Int64 fixture" do
    skip_vm_binary_on_ci!
    test_case = MiniVM::Golden::Case.new(path: source_path)

    result = MiniVM::Golden.register.run(test_case.source, source_dir: test_case.source_dir)

    expect(result.status).to eq(:pass)
    expect(result.output).to eq("42")
  end

  it "runs scalar register match expressions" do
    skip_vm_binary_on_ci!
    source = <<~CHT
      FN score(n: Int64) RETURNS Int64 ->
          RETURN PARTIAL MATCH n START
              1 -> 100,
              2 -> 200,
              DEFAULT -> 0
          END;
      END

      FN main() RETURNS Int64 ->
          RETURN score(2);
      END
    CHT

    result = MiniVM::Golden.register.run(source, source_dir: vm_tests_dir)

    expect(result.status).to eq(:pass)
    expect(result.output).to eq("200")
  end

  it "runs every register-supported golden fixture to its expected output" do
    skip_vm_binary_on_ci!
    # Conformance check: only fixtures with both a committed register
    # snapshot AND a committed expected-output file. Fixtures missing
    # either are surfaced as `pending` per-case above; including them
    # here would double-report the same incompleteness.
    runnable = cases.select do |test_case|
      File.exist?(test_case.bytecode_snapshot_path(:register)) &&
        File.exist?(test_case.output_path)
    end

    runnable = runnable.reject { |tc| REGISTER_PENDING_FIXTURES.include?(tc.relative_path(vm_tests_dir)) }
    expect(runnable.length).to be >= 1
    runnable.each do |test_case|
      result = MiniVM::Golden.register.run(test_case.source, source_dir: test_case.source_dir)

      expect(result.status).to eq(:pass), test_case.relative_path(vm_tests_dir)
      expect(result.output).to eq(test_case.expected_output), test_case.relative_path(vm_tests_dir)
    end
  end

  it "discovers fixture cases through the harness" do
    expect(cases.map { |c| c.relative_path(vm_tests_dir) }).to include(
      "basics/return_i64.clear",
      "calls/early_return_i64.clear",
      "calls/helper_call_f64.clear",
      "calls/nested_helper_calls_i64.clear",
      "control/f64_compare_branch.clear",
      "control/nested_loop_branch_i64.clear",
      "errors/or_fallible_success_i64.clear",
      "errors/or_map_fallback_i64.clear",
      "errors/or_map_success_i64.clear",
      "errors/or_else_raise_fallback_i64.clear",
      "functions/fn_ref_i64.clear",
      "functions/higher_order_fn_ref_i64.clear",
      "functions/higher_order_lambda_i64.clear",
      "functions/lambda_capture_i64.clear",
      "functions/lambda_default_i64.clear",
      "functions/lambda_direct_i64.clear",
      "numerics/div_i64.clear",
      "numerics/f64_arithmetic.clear",
      "numerics/locals_reassign_f64.clear",
      "types/enum_match_i64.clear",
      "types/enum_multi_branch_i64.clear",
      "types/union_payload_i64.clear",
      "types/union_tag_i64.clear",
      "values/list_append_count.clear",
      "values/list_index_i64.clear",
      "values/map_get_i64.clear",
      "values/string_concat.clear",
      "values/struct_field_i64.clear"
    )
  end

  it "updates missing stack bytecode snapshots" do
    Dir.mktmpdir("minivm-golden-") do |dir|
      fixture_dir = File.join(dir, "basics")
      FileUtils.mkdir_p(fixture_dir)
      FileUtils.cp(source_path, File.join(fixture_dir, "return_i64.clear"))

      results = MiniVM::Golden.update_snapshots(root: dir, targets: [:stack])
      snapshot_path = File.join(fixture_dir, "return_i64.stack.bc")

      expect(results.map(&:status)).to eq([:written])
      expect(File.read(snapshot_path)).to include("instructions:\n0000 LOAD_CONST_I64")
    end
  end

  it "checks stack bytecode snapshots without rewriting stale files" do
    Dir.mktmpdir("minivm-golden-") do |dir|
      fixture_dir = File.join(dir, "basics")
      FileUtils.mkdir_p(fixture_dir)
      FileUtils.cp(source_path, File.join(fixture_dir, "return_i64.clear"))
      snapshot_path = File.join(fixture_dir, "return_i64.stack.bc")
      File.write(snapshot_path, "stale\n")

      results = MiniVM::Golden.update_snapshots(root: dir, targets: [:stack], check: true)

      expect(results.map(&:status)).to eq([:stale])
      expect(File.read(snapshot_path)).to eq("stale\n")
    end
  end

  it "reports pending targets during snapshot updates" do
    Dir.mktmpdir("minivm-golden-") do |dir|
      fixture_dir = File.join(dir, "basics")
      FileUtils.mkdir_p(fixture_dir)
      # A register-unsupported fixture (non-scalar struct return); see
      # REGISTER_UNSUPPORTED_SRC above.
      File.write(File.join(fixture_dir, "struct_return.clear"), REGISTER_UNSUPPORTED_SRC)

      results = MiniVM::Golden.update_snapshots(root: dir, targets: [:register])

      expect(results).not_to be_empty
      expect(results.map(&:status).uniq).to eq([:pending])
    end
  end
end
