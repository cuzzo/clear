# typed: false
# frozen_string_literal: true

require "tmpdir"

require_relative "../../ruby/incremental"
require_relative "../../../tools/incremental-testing/mutation_catalog"
require_relative "../../../tools/incremental-testing/result_comparator"
require_relative "../../../tools/incremental-testing/differential_runner"
require_relative "../../../tools/incremental-testing/cli"

RSpec.describe "incremental CLEAR compilation" do
  FakeCompilation = Struct.new(:error_name_enum, :source, :function_counter_snapshots, keyword_init: true)

  class FakeIncrementalCompiler < Incremental::ZigCompiler
    def initialize(mode)
      super(Incremental::ZigCompilerConfig.new(source_dir: Dir.pwd))
      @mode = mode
      @compile_calls = 0
    end

    def compile(text, function_counter_seeds: {})
      function_counter_seeds
      @compile_calls += 1
      if [:candidate_failure, :reduced_context_failure].include?(@mode) && @compile_calls == 2
        raise "candidate failed"
      end

      errors = @mode == :new_error && @compile_calls == 2 ? "  NewError = 11," : "  None = 0,"
      FakeCompilation.new(error_name_enum: errors, source: text, function_counter_snapshots: {})
    end

    def artifact(_compilation)
      state = MIREmitter::EmissionState.new
      items = []
      unless @mode == :missing_function
        items << Incremental::EmittedItem.new(
          key: "function:alpha:1",
          kind: :function,
          name: "alpha",
          code: "fn alpha() i64 {\nreturn 1;\n}",
          contract_fingerprint: "alpha-contract",
          state_before: state,
          state_after: state,
        )
      end
      if @mode == :new_support && @compile_calls == 2
        items << Incremental::EmittedItem.new(
          key: "support:new:1",
          kind: :support,
          name: nil,
          code: "const NEW_SUPPORT = true;",
          state_before: state,
          state_after: state,
        )
      end
      Incremental::ProgramArtifact.new(
        error_name_enum: "  None = 0,",
        footer: "footer",
        items: items,
        final_state: state,
      )
    end

    def function_artifact(_compilation, name:, state_before:)
      return nil if @mode == :missing_candidate

      after = if @mode == :state_change
        MIREmitter::EmissionState.new(symbol_literals: { "x" => "__clear_symbol_0" })
      else
        state_before
      end
      first_line = @mode == :contract_change ? "fn alpha() !i64 {" : "fn alpha() i64 {"
      Incremental::EmittedItem.new(
        key: "candidate",
        kind: :function,
        name: name,
        code: "#{first_line}\nreturn 3;\n}",
        contract_fingerprint: @mode == :contract_change ? "changed-contract" : "alpha-contract",
        state_before: state_before,
        state_after: after,
      )
    end
  end

  let(:module_path) { File.join(Dir.pwd, "incremental_spec.clear") }

  def source(alpha: "1", beta: "2", main_body: 'print("ok");')
    <<~CLEAR
      FN alpha() RETURNS Int64 ->
        RETURN #{alpha};
      END

      FN beta() RETURNS Int64 ->
        RETURN #{beta};
      END

      FN main() RETURNS Void ->
        #{main_body}
      END
    CLEAR
  end

  def catalog(text)
    Incremental::SourceCatalog.build(text, module_path: module_path)
  end

  it "catalogs stable functions, calls, ranges, and isolated source" do
    text = source(main_body: "ASSERT alpha() == 1;") + "# UTF-8: lambda\n"
    result = catalog(text)

    expect(result.functions.map(&:name)).to eq(%w[alpha beta main])
    expect(result.fetch("alpha").key).to eq(catalog(text).fetch("alpha").key)
    expect(result.fetch("missing")).to be_nil
    expect(result.fetch("main").called_functions).to eq(Set["alpha"])
    expect(result.called_by_user_function?("alpha")).to be(true)
    expect(result.by_name.keys).to eq(%w[alpha beta main])
    isolated = result.isolated_source("beta")
    expect(isolated.lines.length).to eq(text.lines.length)
    expect(isolated).to include("FN beta")
    expect(isolated).not_to include("FN alpha")

    test_source = source + <<~CLEAR
      TEST Demo DO
        WHEN "calls" DO
          TEST THAT "alpha" DO ASSERT alpha() == 1; END
        END
      END
    CLEAR
    expect(catalog(test_source).non_function_calls).to include("alpha")
  end

  it "classifies exact, isolated, and conservative fallback edits" do
    baseline = catalog(source)

    exact = Incremental::ItemReconciler.reconcile(baseline, catalog(source))
    expect(exact.fast_path).to be(true)
    expect(exact.changed_function).to be_nil

    isolated = Incremental::ItemReconciler.reconcile(baseline, catalog(source(alpha: "3")))
    expect(isolated.fast_path).to be(true)
    expect(isolated.changed_function).to eq("alpha")

    cases = {
      "root function set changed" => source + "\nFN extra() RETURNS Int64 -> RETURN 1; END\n",
      "non-function source changed" => "# changed\n#{source}",
      "more than one function changed" => source(alpha: "3", beta: "4"),
      "main function changed" => source(main_body: 'print("no");'),
      "function interface changed" => source.sub("FN alpha() RETURNS Int64", "FN alpha(x: Int64) RETURNS Int64"),
    }
    cases.each do |reason, changed_source|
      decision = Incremental::ItemReconciler.reconcile(baseline, catalog(changed_source))
      expect(decision.fast_path).to be(false), reason
      expect(decision.reason).to eq(reason)
    end


    caller_baseline = catalog(source(main_body: "ASSERT alpha() == 1;"))
    caller_edit = catalog(source(alpha: "3", main_body: "ASSERT alpha() == 1;"))
    caller_decision = Incremental::ItemReconciler.reconcile(caller_baseline, caller_edit)
    expect(caller_decision.fast_path).to be(true)
    expect(caller_decision.changed_function).to eq("alpha")

    dependency_edit = Incremental::ItemReconciler.reconcile(baseline, catalog(source(alpha: "beta()")))
    expect(dependency_edit.fast_path).to be(false)
    expect(dependency_edit.reason).to eq("function call dependencies changed")
  end

  it "produces byte-identical Zig for a checked isolated body edit and revert" do
    compiler = Incremental::ZigCompiler.new(
      Incremental::ZigCompilerConfig.new(source_dir: Dir.pwd),
    )
    session = Incremental::CompilationSession.new(
      compiler: compiler,
      module_path: module_path,
      verify: true,
    )

    initial = session.compile(source)
    expect(initial.status).to eq(:clean)
    exact = session.compile(source)
    expect(exact.status).to eq(:exact_hit)

    changed_source = source(alpha: "3")
    changed = session.compile(changed_source)
    expect(changed.status).to eq(:incremental)
    expect(changed.changed_function).to eq("alpha")
    clean = compiler.artifact(compiler.compile(changed_source)).render
    expect(changed.zig).to eq(clean)

    reverted = session.compile(source)
    expect(reverted.status).to eq(:incremental)
    expect(reverted.zig).to eq(initial.zig)
  end

  it "incrementally compiles a line inserted inside one function" do
    compiler = Incremental::ZigCompiler.new(
      Incremental::ZigCompilerConfig.new(source_dir: Dir.pwd),
    )
    session = Incremental::CompilationSession.new(
      compiler: compiler,
      module_path: module_path,
      verify: true,
    )

    session.compile(source)
    changed_source = source.sub("RETURN 1;", "ASSERT TRUE;\n  RETURN 1;")
    changed = session.compile(changed_source)

    expect(changed.status).to eq(:incremental)
    expect(changed.changed_function).to eq("alpha")
    expect(changed.zig).to eq(compiler.artifact(compiler.compile(changed_source)).render)
  end

  it "preserves generated names when an earlier function gains a line" do
    path = File.expand_path("../../../transpile-tests/40_locked.clear", __dir__)
    original = File.binread(path)
    changed_source = original.sub("    RETURN c.value;", "    ASSERT TRUE;\n    RETURN c.value;")
    compiler = Incremental::ZigCompiler.new(
      Incremental::ZigCompilerConfig.new(source_dir: File.dirname(path)),
    )
    session = Incremental::CompilationSession.new(
      compiler: compiler,
      module_path: path,
      verify: true,
    )

    session.compile(original)
    changed = session.compile(changed_source)

    expect(changed.status).to eq(:incremental)
    expect(changed.changed_function).to eq("getVal")
  end

  it "preserves shadowed owned-binding names when an earlier function gains a line" do
    original = <<~CLEAR
      FN alpha() RETURNS Int64 ->
        RETURN 1;
      END

      FN shadowed() RETURNS !Void ->
        IF TRUE THEN
          values = List[1_i64];
          ASSERT values.length() == 1;
        END
        IF TRUE THEN
          values = List[2_i64];
          ASSERT values.length() == 1;
        END
        RETURN;
      END

      FN main() RETURNS Void ->
        RETURN;
      END
    CLEAR
    changed_source = original.sub("  RETURN 1;", "  ASSERT TRUE;\n  RETURN 1;")
    compiler = Incremental::ZigCompiler.new(
      Incremental::ZigCompilerConfig.new(source_dir: Dir.pwd),
    )
    session = Incremental::CompilationSession.new(
      compiler: compiler,
      module_path: module_path,
      verify: true,
    )

    session.compile(original)
    changed = session.compile(changed_source)

    expect(changed.status).to eq(:incremental)
    expect(changed.changed_function).to eq("alpha")
  end

  it "keeps hoist names function-local when a function gains a statement" do
    original = <<~CLEAR
      FN preceding() RETURNS !Int64 ->
        parts = " first,second".split(",");
        part = trim(UNWRAP parts[0]);
        RETURN part.length();
      END

      FN alpha() RETURNS !Int64 ->
        parts = " third,fourth".split(",");
        part = trim(UNWRAP parts[0]);
        RETURN part.length();
      END

      FN main() RETURNS Void ->
        RETURN;
      END
    CLEAR
    changed_source = original.sub(
      "FN alpha() RETURNS !Int64 ->",
      "FN alpha() RETURNS !Int64 ->\n  ASSERT TRUE;",
    )
    compiler = Incremental::ZigCompiler.new(
      Incremental::ZigCompilerConfig.new(source_dir: Dir.pwd),
    )
    session = Incremental::CompilationSession.new(
      compiler: compiler,
      module_path: module_path,
      verify: true,
    )

    session.compile(original)
    changed = session.compile(changed_source)

    expect(changed.status).to eq(:incremental)
    expect(changed.changed_function).to eq("alpha")
  end

  it "relocates runtime error source lines after an inserted line" do
    original = <<~CLEAR
      FN alpha() RETURNS Int64 ->
        RETURN 1;
      END

      FN mayFail() RETURNS !Void ->
        RAISE "boom";
      END

      FN main() RETURNS Void ->
        RETURN;
      END
    CLEAR
    changed_source = original.sub("  RETURN 1;", "  ASSERT TRUE;\n  RETURN 1;")
    compiler = Incremental::ZigCompiler.new(
      Incremental::ZigCompilerConfig.new(source_dir: Dir.pwd),
    )
    session = Incremental::CompilationSession.new(
      compiler: compiler,
      module_path: module_path,
      verify: true,
    )

    session.compile(original)
    changed = session.compile(changed_source)

    expect(changed.status).to eq(:incremental)
    expect(changed.changed_function).to eq("alpha")
  end

  it "relocates task-profile source lines after an inserted line" do
    original = <<~CLEAR
      FN alpha() RETURNS Int64 ->
        RETURN 1;
      END

      FN spawnOne() RETURNS !Void ->
        task:~ = BG { print("hi"); };
        NEXT task;
        RETURN;
      END

      FN main() RETURNS Void ->
        RETURN;
      END
    CLEAR
    changed_source = original.sub("  RETURN 1;", "  ASSERT TRUE;\n  RETURN 1;")
    compiler = Incremental::ZigCompiler.new(
      Incremental::ZigCompilerConfig.new(source_dir: Dir.pwd),
    )
    session = Incremental::CompilationSession.new(
      compiler: compiler,
      module_path: module_path,
      verify: true,
    )

    session.compile(original)
    changed = session.compile(changed_source)

    expect(changed.status).to eq(:incremental)
    expect(changed.changed_function).to eq("alpha")
  end

  it "keeps a timed compilation session alive for watch mode" do
    Dir.mktmpdir("incremental-watch") do |dir|
      path = File.join(dir, "main.clear")
      File.write(path, source)
      watcher = Incremental::WatchCompiler.new(
        config: Incremental::ZigCompilerConfig.new(source_dir: dir),
        module_path: path,
        verify: true,
      )

      initial = watcher.compile_file(path)
      expect(initial.result.status).to eq(:clean)
      expect(initial.elapsed_seconds).to be >= 0.0

      File.write(path, source(alpha: "3"))
      changed = watcher.compile_file(path)
      expect(changed.result.status).to eq(:incremental)
      expect(changed.result.changed_function).to eq("alpha")
      expect(changed.elapsed_seconds).to be >= 0.0
    end
  end

  it "emits deterministic Zig for capability-generated names across clean compilations" do
    %w[40_locked.clear 264_multi_lock_sort.clear 333_with_match_per_arm_dispatch.clear].each do |fixture|
      path = File.expand_path("../../../transpile-tests/#{fixture}", __dir__)
      text = File.binread(path)
      config = Incremental::ZigCompilerConfig.new(source_dir: File.dirname(path))
      first_compiler = Incremental::ZigCompiler.new(config)
      second_compiler = Incremental::ZigCompiler.new(config)

      first = first_compiler.artifact(first_compiler.compile(text)).render
      second = second_compiler.artifact(second_compiler.compile(text)).render

      expect(second).to eq(first), fixture
    end
  end

  it "retains unchanged imports and invalidates them by content" do
    Dir.mktmpdir("incremental-imports") do |dir|
      dependency_path = File.join(dir, "dep.clear")
      root_path = File.join(dir, "root.clear")
      File.write(dependency_path, <<~CLEAR)
        PUB FN importedValue() RETURNS Int64 -> RETURN 7; END
      CLEAR
      root = <<~CLEAR
        REQUIRE "dep.clear";
        FN alpha() RETURNS Int64 -> RETURN 1; END
        FN main() RETURNS Void -> RETURN; END
      CLEAR

      config = Incremental::ZigCompilerConfig.new(source_dir: dir)
      compiler = Incremental::ZigCompiler.new(config)
      session = Incremental::CompilationSession.new(compiler: compiler, module_path: root_path)
      initial = session.compile(root)
      expect(compiler.dependency_paths).to eq([dependency_path])
      expect(session.compile(root).status).to eq(:exact_hit)

      File.write(dependency_path, <<~CLEAR)
        PUB FN importedValue() RETURNS Int64 -> RETURN 8; END
      CLEAR
      changed = session.compile(root)
      expect(changed.status).to eq(:clean)
      expect(changed.reason).to eq("dependency changed: dep.clear")
      expect(changed.zig).not_to eq(initial.zig)

      oracle = Incremental::ZigCompiler.new(config)
      expect(changed.zig).to eq(oracle.artifact(oracle.compile(root)).render)
    end
  end

  it "restores a portable primitive cache across compiler processes" do
    Dir.mktmpdir("incremental-portable") do |dir|
      path = File.join(dir, "main.clear")
      cache_path = File.join(dir, "main.clearc")
      File.write(path, source)
      config = Incremental::ZigCompilerConfig.new(source_dir: dir)
      cache = Incremental::PortableCache.new(
        path: cache_path,
        module_path: path,
        compiler_fingerprint: "compiler-v1",
      )

      first = Incremental::CompilationSession.new(
        compiler: Incremental::ZigCompiler.new(config),
        module_path: path,
        cache: cache,
      )
      initial = first.compile(source)
      expect(File.binread(cache_path)).not_to start_with("\x04\x08")

      restored_compiler = Incremental::ZigCompiler.new(config)
      restored = Incremental::CompilationSession.new(
        compiler: restored_compiler,
        module_path: path,
        cache: cache,
        verify: true,
      )
      expect(restored.compile(source).status).to eq(:exact_hit)
      changed = restored.compile(source(alpha: "3"))
      expect(changed.status).to eq(:incremental)
      expect(changed.zig).to eq(restored_compiler.artifact(restored_compiler.compile(source(alpha: "3"))).render)

      incompatible = Incremental::PortableCache.new(
        path: cache_path,
        module_path: path,
        compiler_fingerprint: "compiler-v2",
      )
      expect(incompatible.load).to be_nil
      expect(initial.zig).not_to eq(changed.zig)
    end
  end

  it "rejects corrupt, oversized, and stale portable caches" do
    Dir.mktmpdir("incremental-portable-invalid") do |dir|
      path = File.join(dir, "main.clear")
      dependency = File.join(dir, "dep.clear")
      cache_path = File.join(dir, "main.clearc")
      File.write(path, source)
      File.write(dependency, "one")
      cache = Incremental::PortableCache.new(
        path: cache_path,
        module_path: path,
        compiler_fingerprint: "compiler-v1",
      )

      File.binwrite(cache_path, "not messagepack")
      expect(cache.load).to be_nil
      File.truncate(cache_path, Incremental::PortableCache::MAX_BYTES + 1)
      expect(cache.load).to be_nil

      artifact = Incremental::ProgramArtifact.new(
        error_name_enum: "errors",
        footer: "footer",
        items: [],
        final_state: MIREmitter::EmissionState.new,
      )
      cache.write(
        source: source,
        artifact: artifact,
        function_counter_snapshots: {},
        dependencies: Incremental::DependencySnapshot.capture([dependency]),
      )
      File.write(dependency, "two")
      expect(cache.load).to be_nil
    end
  end

  it "detects changed and missing dependency content" do
    Dir.mktmpdir("incremental-fingerprints") do |dir|
      path = File.join(dir, "dep.clear")
      File.write(path, "one")
      snapshot = Incremental::DependencySnapshot.capture([path, path])
      expect(snapshot.current?).to be(true)
      expect(snapshot.entries.length).to eq(1)

      File.write(path, "two")
      expect(snapshot.changed_paths).to eq([path])
      FileUtils.rm_f(path)
      expect(snapshot.changed_paths).to eq([path])
    end
  end

  it "fingerprints source-declared C headers without compiling them" do
    compiler = Incremental::ZigCompiler.new(
      Incremental::ZigCompilerConfig.new(source_dir: Dir.pwd),
    )
    compiler.publish_dependencies!(<<~CLEAR)
      EXTERN FROM HEADER "missing-incremental-fixture.h" LINK "fixture" ABI C;
    CLEAR
    expect(compiler.dependency_paths).to eq([
      File.expand_path("missing-incremental-fixture.h", Dir.pwd),
    ])
  end

  it "reuses a caller when the changed callee preserves its interface" do
    compiler = Incremental::ZigCompiler.new(
      Incremental::ZigCompilerConfig.new(source_dir: Dir.pwd),
    )
    session = Incremental::CompilationSession.new(compiler: compiler, module_path: module_path)
    original = source(main_body: "ASSERT alpha() == 1;")
    session.compile(original)

    changed = session.compile(source(alpha: "3", main_body: "ASSERT alpha() == 1;"))
    expect(changed.status).to eq(:incremental)
    oracle = compiler.artifact(compiler.compile(source(alpha: "3", main_body: "ASSERT alpha() == 1;"))).render
    expect(changed.zig).to eq(oracle)
  end

  it "compiles a changed function with its transitive user-function dependencies" do
    original = source(alpha: "beta()")
    changed_source = source(alpha: "beta() + 1")
    compiler = Incremental::ZigCompiler.new(
      Incremental::ZigCompilerConfig.new(source_dir: Dir.pwd),
    )
    session = Incremental::CompilationSession.new(compiler: compiler, module_path: module_path, verify: true)
    session.compile(original)

    changed = session.compile(changed_source)
    expect(changed.status).to eq(:incremental)
    expect(changed.changed_function).to eq("alpha")
    expect(changed.zig).to eq(compiler.artifact(compiler.compile(changed_source)).render)
  end

  it "fails closed at every function artifact boundary" do
    expectations = {
      missing_function: "function emission is not independently addressable",
      candidate_failure: "isolated candidate compilation failed",
      missing_candidate: "candidate did not emit one function",
      state_change: "function changed global emission state",
      contract_change: "derived function contract changed",
      new_error: "function introduced a program error type",
      new_support: "function introduced program-level Zig support",
    }
    expectations.each do |mode, reason|
      compiler = FakeIncrementalCompiler.new(mode)
      session = Incremental::CompilationSession.new(compiler: compiler, module_path: module_path)
      session.compile(source)
      result = session.compile(source(alpha: "3"))
      expect(result.status).to eq(:clean), mode.to_s
      expect(result.reason).to eq(reason), mode.to_s
    end
  end

  it "fails closed when a caller-sensitive reduced context cannot be proven" do
    caller_source = source(main_body: "ASSERT alpha() == 1;")
    changed_source = source(alpha: "3", main_body: "ASSERT alpha() == 1;")

    failed = Incremental::CompilationSession.new(
      compiler: FakeIncrementalCompiler.new(:reduced_context_failure),
      module_path: module_path,
    )
    failed.compile(caller_source)
    expect(failed.compile(changed_source).reason).to eq("reduced semantic context could not be verified")

    mismatch = Incremental::CompilationSession.new(
      compiler: FakeIncrementalCompiler.new(:normal),
      module_path: module_path,
    )
    mismatch.compile(caller_source)
    expect(mismatch.compile(changed_source).reason).to eq("reduced semantic context changed function emission")
  end

  it "raises when verification finds a byte mismatch" do
    compiler = FakeIncrementalCompiler.new(:verify_mismatch)
    session = Incremental::CompilationSession.new(
      compiler: compiler,
      module_path: module_path,
      verify: true,
    )
    session.compile(source)
    expect { session.compile(source(alpha: "3")) }.to raise_error(
      RuntimeError,
      "incremental compiler produced Zig that differs from a clean compilation",
    )
  end

  it "uses the clean compiler as the oracle for malformed revisions" do
    compiler = Incremental::ZigCompiler.new(
      Incremental::ZigCompilerConfig.new(source_dir: Dir.pwd),
    )
    session = Incremental::CompilationSession.new(compiler: compiler, module_path: module_path)
    session.compile(source)
    expect { session.compile("FN broken(") }.to raise_error(ParserError)

    permissive = Incremental::CompilationSession.new(
      compiler: FakeIncrementalCompiler.new(:normal),
      module_path: module_path,
    )
    unsupported = permissive.compile("FN broken(")
    expect(unsupported.status).to eq(:clean)
    expect(permissive.compile(source).reason).to eq("initial compilation")
  end

  it "mutates literals, booleans, and compatible operators and compares exact output bytes" do
    mutations = IncrementalTesting::MutationCatalog.literal_mutations(source, limit: 2)
    expect(mutations.length).to eq(2)
    expect(mutations.first.apply(source)).not_to eq(source)

    equal = IncrementalTesting::ResultComparator.compare("zig", "zig")
    different = IncrementalTesting::ResultComparator.compare("zig", "zag")
    expect(equal.equal).to be(true)
    expect(different.equal).to be(false)
    expect(different.clean_digest).not_to eq(different.incremental_digest)

    float_mutation = IncrementalTesting::MutationCatalog.literal_mutations(
      "FN f() RETURNS Float64 -> RETURN 1.0; END",
      limit: 1,
    )
    expect(float_mutation.first.replacement).to eq("2.0")

    varied = IncrementalTesting::MutationCatalog.mutations(
      "FN f() RETURNS Bool -> RETURN 9 + 10 <= 20 AND TRUE; END",
      limit: 20,
    )
    expect(varied.map(&:category)).to include(:literal, :operator, :boolean)
    expect(varied.any? { |mutation| mutation.replacement.bytesize != mutation.end_offset - mutation.start_offset }).to be(true)
  end

  it "runs the differential mutation oracle end to end" do
    Dir.mktmpdir("incremental-runner") do |dir|
      path = File.join(dir, "fixture.clear")
      File.write(path, source)
      run = IncrementalTesting::DifferentialRunner.new(source_path: path, limit: 1).run
      expect(run.success?).to be(true)
      expect(run.cases.map(&:status)).to include(:incremental)
      expect(run.cases.all?(&:equal)).to be(true)
    end
  end

  it "reports differential CLI success, failure, and usage errors" do
    success = IncrementalTesting::RunResult.new(source_path: module_path, cases: [])
    failure_case = IncrementalTesting::CaseResult.new(
      description: "mismatch",
      status: :incremental,
      equal: false,
      incremental_digest: "a",
      clean_digest: "b",
    )
    failure = IncrementalTesting::RunResult.new(source_path: module_path, cases: [failure_case])
    runner = instance_double(IncrementalTesting::DifferentialRunner)
    allow(IncrementalTesting::DifferentialRunner).to receive(:new).and_return(runner)

    allow(runner).to receive(:run).and_return(success)
    expect { expect(IncrementalTesting::CLI.run([module_path])).to eq(0) }.to output(/"success": true/).to_stdout

    allow(runner).to receive(:run).and_return(failure)
    expect { expect(IncrementalTesting::CLI.run([module_path])).to eq(1) }.to output(/"success": false/).to_stdout

    expect { expect(IncrementalTesting::CLI.run([])).to eq(2) }
      .to output(/missing argument: FILE_OR_DIR/).to_stderr
  end
end
