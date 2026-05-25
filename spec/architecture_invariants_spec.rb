require "rspec"

ARCH_ROOT = File.expand_path("..", __dir__)

# Static-analysis guard for the placement-field architecture.
#
# Storage / allocator decisions flow through a staged pipeline, and EACH
# field has exactly ONE sanctioned writer. A write from anywhere else is
# a renegade escape/placement decision -- the architectural defect that
# produces the allocator-mismatch bug class (leaks, double-frees,
# invalid frees). This test fails the build if such a write exists.
#
#   node.storage        <- annotation ONLY
#   symbol.storage      <- escape analysis ONLY
#   CleanupEntry#alloc  <- cleanup classification ONLY
#   CleanupEntry#scope  <- cleanup classification ONLY
#
# These invariants are non-negotiable: fixing the compiler means making
# every placement decision in its one sanctioned pass, never beside it.
RSpec.describe "architecture invariants: placement-field writers" do
  SRC = File.join(ARCH_ROOT, "src")

  # ── the ONE sanctioned writer of each field ─────────────────────────

  # node.storage is expression-shape metadata. Annotation is the source for
  # parsed nodes; rewrite/lowering adapters may copy that metadata onto
  # synthetic nodes, but escape placement must not be written here.
  NODE_STORAGE_OK = lambda do |rel|
    rel == "annotator/annotator.rb" ||
      rel.start_with?("annotator/helpers/") ||
      rel == "ast/ast.rb" ||           # finalize_storage! -- the annotation mechanism
      rel == "ast/parser.rb" ||        # parse-time literal storage
      rel == "mir/alloc.rb" ||         # downgrade_frame_to_stack: mixed into SemanticAnnotator
      rel == "backends/pipeline_host.rb" ||
      rel == "backends/pipeline_rewriter.rb" ||
      rel == "backends/string_concat_rewriter.rb" ||
      rel == "mir/mir_lowering.rb" ||
      rel.start_with?("mir/lowering/")
  end

  # symbol.storage is made DEFINITIVE by escape analysis.
  SYMBOL_STORAGE_OK = lambda do |rel|
    rel == "mir/escape_analysis.rb"
  end

  # CleanupEntry#alloc is set once, by cleanup classification.
  CLEANUP_ALLOC_OK = lambda do |rel|
    rel == "mir/cleanup_classifier.rb" || rel == "mir/cleanup_entry.rb"
  end

  # ── scan every source file for placement-field writes ───────────────

  def self.scan
    node_w = []
    sym_w = []
    cleanup_w = []
    cleanup_scope_w = []
    Dir[File.join(SRC, "**", "*.rb")].sort.each do |path|
      rel = path.sub(SRC + "/", "")
      File.readlines(path).each_with_index do |line, idx|
        next if line.strip.start_with?("#")          # skip comment lines
        loc = "#{rel}:#{idx + 1}"
        code = line.strip

        if (m = line.match(/([\w.\[\]]*)\.storage\s*=(?![=~])/))
          recv = m[1]
          symbol_write = recv.end_with?(".symbol") ||
                         %w[sym symbol node_sym decl_sym entry sym_entry].include?(recv)
          (symbol_write ? sym_w : node_w) << [loc, code]
        end

        # CleanupEntry is a typed Hash-subclass written via [:alloc]=.
        # Restrict to entry/cleanup-named receivers so plain Hashes
        # (effects[:alloc], resolved_allocs[:alloc]) are not flagged.
        if line.match(/\b\w*(?:entry|cleanup)\w*\[:alloc\]\s*=(?![=~])/i)
          cleanup_w << [loc, code]
        end

        if line.match(/\b\w*(?:entry|cleanup)\w*\[:scope\]\s*=(?![=~])/i)
          cleanup_scope_w << [loc, code]
        end
      end
    end
    { node: node_w, symbol: sym_w, cleanup: cleanup_w, cleanup_scope: cleanup_scope_w }
  end

  WRITES = scan

  def renegades(list, sanctioned)
    list.reject { |loc, _| sanctioned.call(loc.split(":").first) }
  end

  def report(label, bad)
    "#{bad.size} renegade #{label} write(s) -- must move to the sanctioned pass:\n" +
      bad.map { |loc, code| "  #{loc}\n      #{code}" }.join("\n")
  end

  it "node.storage is written ONLY by annotation" do
    bad = renegades(WRITES[:node], NODE_STORAGE_OK)
    expect(bad).to be_empty, report("node.storage", bad)
  end

  it "symbol.storage is written ONLY by escape analysis" do
    bad = renegades(WRITES[:symbol], SYMBOL_STORAGE_OK)
    expect(bad).to be_empty, report("symbol.storage", bad)
  end

  it "CleanupEntry#alloc is written ONLY by cleanup classification" do
    bad = renegades(WRITES[:cleanup], CLEANUP_ALLOC_OK)
    expect(bad).to be_empty, report("CleanupEntry#alloc", bad)
  end

  it "CleanupEntry#scope is written ONLY by cleanup classification" do
    bad = renegades(WRITES[:cleanup_scope], CLEANUP_ALLOC_OK)
    expect(bad).to be_empty, report("CleanupEntry#scope", bad)
  end
end

RSpec.describe "architecture invariants: MIR pass order" do
  def source(rel)
    File.read(File.join(ARCH_ROOT, rel))
  end

  def expect_order(rel, *patterns)
    text = source(rel)
    positions = patterns.map do |pattern|
      idx = text.index(pattern)
      expect(idx).not_to be_nil, "#{rel} is missing #{pattern.inspect}"
      idx
    end
    expect(positions).to eq(positions.sort),
      "#{rel} has wrong pass order:\n  #{patterns.join("\n  ")}"
  end

  it "runs top-level rewrites before hoist, type check, and MIRPass" do
    expect_order(
      "src/backends/compiler_frontend.rb",
      "annotator.annotate!",
      "PipelineRewriter.new(annotator).rewrite!(ast)",
      "MIRPassState.for!(T.must(ast)).mark!(:pipeline_rewritten)",
      "StringConcatRewriter.new.rewrite!(T.must(ast))",
      "MIRPassState.for!(T.must(ast)).mark!(:string_concat_rewritten)",
      "schema_lookup = ->(name) { annotator.lookup_type_schema(name) }",
      "Hoist.apply!(T.must(ast), schema_lookup: schema_lookup)",
      "PreMirTypeCheck.verify!(T.must(ast))",
      "mir_pass = MIRPass.new",
      "mir_pass.transform!",
    )
  end

  it "runs imported modules through the same rewrite/hoist/typecheck/MIRPass boundary" do
    expect_order(
      "src/backends/importer.rb",
      "annotator.annotate!",
      "PipelineRewriter.new(annotator).rewrite!(ast)",
      "MIRPassState.for!(ast).mark!(:pipeline_rewritten)",
      "StringConcatRewriter.new.rewrite!(ast)",
      "MIRPassState.for!(ast).mark!(:string_concat_rewritten)",
      "schema_lookup = ->(name) { annotator.lookup_type_schema(name) }",
      "Hoist.apply!(ast, schema_lookup: schema_lookup)",
      "PreMirTypeCheck.verify!(ast)",
      "mir_pass = MIRPass.new",
      "mir_pass.transform!",
    )
  end

  it "runs MIR placement before cleanup classification, loop analysis, and lowering stamps" do
    expect_order(
      "src/mir/mir_pass.rb",
      "pass_state.require!(:premir_type_checked",
      "EscapeAnalysis.apply!",
      "pass_state.mark!(:escape_analyzed)",
      "CleanupClassifier.classify",
      "pass_state.mark!(:cleanup_classified)",
      "LoopFrameAnalysis.analyze!",
      "pass_state.mark!(:loop_frame_analyzed)",
      "finalize_needs_rt!",
      "pass_state.mark!(:needs_rt_finalized)",
      "transform_function!",
      "pass_state.mark!(:mir_pass_complete)",
    )
  end

  it "requires each MIR consumer to assert the pass-state stage it consumes" do
    expect(source("src/mir/hoist.rb")).to include('MIRPassState.require!(ast, :string_concat_rewritten, consumer: "Hoist")')
    expect(source("src/mir/pre_mir_type_check.rb")).to include('MIRPassState.require!(program, :hoisted, consumer: "PreMirTypeCheck")')
    expect(source("src/mir/mir_lowering.rb")).to include('MIRPassState.require!(node, :mir_pass_complete, consumer: "MIRLowering")')
    expect(source("src/mir/mir_checker.rb")).to include('MIRPassState.require!(program, :mir_lowered, consumer: "MIRChecker")')
  end

  it "keeps pass stages registered as typed producer/requirement specs" do
    pass_state = source("src/mir/pass_state.rb")
    expect(pass_state).to include("class StageSpec < T::Struct")
    expect(pass_state).to include("const :producer, String")
    expect(pass_state).to include("const :requires, T.nilable(Symbol)")
    expect(pass_state).to include("STAGE_BY_NAME")
    expect(pass_state).to include("next required stage")
  end

  it "aborts compilation on MIRChecker errors in emitted program paths" do
    expect(source("src/backends/transpiler.rb")).to include("MIR ownership verification failed")
    expect(source("src/backends/transpiler.rb")).to match(/raise\s+"MIR ownership verification failed/)
  end

  it "requires structural calls to carry typed callable contracts" do
    expect(source("src/mir/mir.rb")).to include("class CallableContract")
    expect(source("src/mir/mir.rb")).to include("attr_reader :signature")
    expect(source("src/mir/mir.rb")).to include("attr_reader :ownership_contract")
    expect(source("src/mir/mir.rb")).to include("attr_reader :checked_arg_count")
    expect(source("src/mir/mir_checker.rb")).to include("verify_callable_contract!")
    expect(source("src/mir/mir_checker.rb")).to include("MIR::CallableContract")
  end

  it "keeps ownership-significant MIR node classes in an explicit registry" do
    expect(source("src/mir/mir.rb")).to include("OWNERSHIP_SIGNIFICANT_NODE_TYPES")
    expect(source("src/mir/mir.rb")).to include("AllocMark, Cleanup, ErrCleanup, TransferMark, MoveMark")
    expect(source("src/mir/mir.rb")).to include("RawZig, InlineZig")
    expect(source("src/mir/mir.rb")).to include("Call, TailCall, MethodCall")
  end

  it "keeps linear MIR ownership traversal closed over statement node classes" do
    checker = source("src/mir/mir_checker.rb")
    expect(checker).to include("LINEAR_STATEMENT_NODE_TYPES")
    expect(checker).to include("LINEAR_STMT_NOT_REGISTERED")
    expect(checker).not_to match(/else\s*\n\s*check_linear_expr_uses!\(stmt, state\)/)
  end

  it "keeps escape analysis sinks registered with concrete handlers" do
    escape = source("src/mir/escape_analysis.rb")
    expect(escape).to include("ESCAPE_SINK_HANDLERS")
    expect(escape).to include("validate_escape_sink_handlers!")
    expect(escape).to include("return_value")
    expect(escape).to include("takes_or_mutable_arg")
    expect(escape).to include("execution_boundary_capture")
  end
end

RSpec.describe "architecture invariants: post-annotation type access" do
  def source(rel)
    File.read(File.join(ARCH_ROOT, rel))
  end

  TYPE_CONTRACT_BURNDOWN_FILES = [
    "src/annotator/annotator.rb",
    "src/annotator/helpers/function_analysis.rb",
    "src/annotator/helpers/generic_analysis.rb",
    "src/annotator/helpers/pipe_analysis.rb",
    "src/backends/pipeline_host.rb",
    "src/backends/pipeline_rewriter.rb",
    "src/mir/escape_analysis.rb",
    "src/mir/lowering/expressions.rb",
    "src/mir/lowering/variables.rb",
  ].freeze

  TYPE_CONTRACT_SOURCE_DIRS = [
    "src/annotator",
    "src/backends",
    "src/mir",
  ].freeze

  def scoped_source_files
    TYPE_CONTRACT_SOURCE_DIRS.flat_map do |dir|
      Dir[File.join(ARCH_ROOT, dir, "**/*.rb")]
    end.sort.map { |path| path.sub(ARCH_ROOT + "/", "") }
  end

  it "does not re-derive whether AST nodes have full_type in burned-down consumers" do
    offenders = scoped_source_files.flat_map do |rel|
      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("respond_to?(:full_type)") || line.include?('respond_to?("full_type")')
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "post-annotation consumers must use Locatable#full_type!, not defensive full_type probes:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not keep legacy full_type_or readers in scoped compiler code" do
    offenders = scoped_source_files.flat_map do |rel|
      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("full_type_or")
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "scoped compiler code must use Locatable#full_type! rather than full_type_or:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not use optional Type.from_node on post-annotation AST values in burned-down consumers" do
    offenders = scoped_source_files.flat_map do |rel|
      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/Type\.from_node\((?![^\)]*,\s*context:)/)
        # Raw metadata is not an annotated AST value; it may still be
        # normalized optionally because absence has semantic meaning there.
        next if line.match?(/\b(?:variant_data|return_type|expected_type|current_expected_type|current_fn_return_type|type_info)\b/)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "post-annotation AST values must use Locatable#full_type! or Type.from_node!, not optional Type.from_node:\n" \
      "#{offenders.join("\n")}"
  end

  it "keeps required AST type access as a hard contract" do
    ast = source("src/ast/ast.rb")
    expect(ast).to include("def full_type!(context: \"post-annotation AST\")")
    expect(ast).to include('raise "#{context}: unresolved type info')
    expect(source("src/mir/pre_mir_type_check.rb")).to include("full_type is the :Untyped")
  end

  it "does not use optional Type.from_node on MIR AST consumers" do
    allowed_raw_metadata = [
      /current_expected_type/,
      /current_fn_return_type/,
      /return_type/,
      /expected_type/,
      /variant_data/,
      /\btype_info\b/,
    ]
    offenders = Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("Type.from_node(")
        next if allowed_raw_metadata.any? { |pattern| line.match?(pattern) }
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "MIR AST consumers must use Type.from_node! / Locatable#full_type!; optional Type.from_node is only for raw type metadata:\n" \
      "#{offenders.join("\n")}"
  end

  it "uses hard AST type reads in MIR consumers" do
    offenders = Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/\.full_type(?![!\w])/)
        # Producer writes/copies are the sanctioned place for synthetic nodes
        # to receive already-authoritative annotation facts.
        next if line.match?(/\.full_type\s*=/)
        # PreMirTypeCheck is the boundary that rejects the :Untyped sentinel.
        next if rel == "src/mir/pre_mir_type_check.rb"
        # MIR AllocMark exposes a Type payload through #full_type; this is not
        # an AST annotation read and has no bang accessor.
        next if rel == "src/mir/mir_checker.rb" && line.include?("alloc_marks.first.full_type")
        # OwnershipGraph::Node exposes its stored Type payload through
        # #full_type; this is not an AST annotation read.
        next if rel == "src/mir/ownership_graph.rb" && line.include?("source.full_type")
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "MIR AST consumers must use Locatable#full_type!; plain .full_type is only for producer writes or MIR Type payloads:\n" \
      "#{offenders.join("\n")}"
  end

  it "uses hard AST type reads in backend consumers" do
    offenders = Dir[File.join(ARCH_ROOT, "src/backends/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/\.full_type(?![!\w])/)
        next if line.match?(/\.full_type\s*=/)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "Backend AST consumers must use Locatable#full_type!; plain .full_type is only for producer writes:\n" \
      "#{offenders.join("\n")}"
  end
end

RSpec.describe "architecture invariants: closed placement pipeline" do
  ForbiddenPattern = Struct.new(:name, :glob, :pattern, :allowed, keyword_init: true)

  FORBIDDEN = [
    ForbiddenPattern.new(
      name: "return/heap provenance as placement data",
      glob: "src/**/*.rb",
      pattern: /\b(?:return_provenance|heap_provenance)\b/,
      allowed: [
        %r{\Asrc/mir/mir_checker\.rb\z},
        %r{\Asrc/mir/mir\.rb\z},
        %r{\Asrc/ast/diagnostic_registry\.rb\z},
      ],
    ),
    ForbiddenPattern.new(
      name: "lowering-side heap/frame inference helpers",
      glob: "src/mir/{mir_lowering.rb,lowering/**/*.rb,hoist.rb,cleanup_classifier.rb}",
      pattern: /\b(?:node_is_heap\?|heap_owned_value\?|takes_arg_alloc|receiver_root_heap\?|storage_to_alloc|authoritative_storage|call_return_provenance|return_expr_provenance)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "recursive cleanup shape used as allocator input downstream",
      glob: "src/mir/{mir_lowering.rb,lowering/**/*.rb,hoist.rb}",
      pattern: /\b(?:recursive_cleanup_shape\?|type_shape_needs_recursive_cleanup\?)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "lowering/hoist context allocator state",
      glob: "src/mir/{mir_lowering.rb,lowering/**/*.rb,hoist.rb}",
      pattern: /@(?:decl_alloc|current_fn_return_alloc)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "node storage used as downstream allocator authority",
      glob: "src/mir/{mir_lowering.rb,lowering/**/*.rb,hoist.rb,cleanup_classifier.rb}",
      pattern: /\bnode\.storage\s*(?:==|=~|!=|=)\s*:heap\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "inactive escape fuzz cells",
      glob: "tools/fuzz/templates/**/*.rb",
      pattern: /(?:expected\s*[:=]|\?\s*)\s*:in_dev\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "source-specific call metadata in escape analysis",
      glob: "src/mir/escape_analysis.rb",
      pattern: /\bmatched_stdlib_def\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "loop-analysis special escape flags",
      glob: "src/**/*.rb",
      pattern: /\b(?:frame_alloc_escapes|stores_into_nonlocal_collection)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "loop rewind decisions from collection mutator names",
      glob: "src/mir/{control_flow.rb,mir_checker.rb}",
      pattern: /\b(?:append|insert|push|put|ELEMENT_STORE)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "loop rewind decisions from collection shape",
      glob: "src/mir/{control_flow.rb,mir_checker.rb}",
      pattern: /\b(?:collection\?|collection_value\?|list_collection\?|set_collection\?|pool\?|map\?|array\?)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "defensive nil-array fallbacks in placement helpers",
      glob: "src/mir/{cleanup_classifier.rb,hoist.rb}",
      pattern: /\|\|\s*\[\]|\b&&\s*\w+\.any\?|\w+&\.any\?/,
      allowed: [],
    ),
  ].freeze

  def scan_for(pattern)
    files = Dir[File.join(ARCH_ROOT, pattern.glob)].uniq.sort
    files.each_with_object([]) do |path, hits|
      rel = path.sub(ARCH_ROOT + "/", "")
      next if pattern.allowed.any? { |allowed| allowed.match?(rel) }

      File.readlines(path).each_with_index do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(pattern.pattern)

        hits << "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end
  end

  FORBIDDEN.each do |pattern|
    it "forbids #{pattern.name}" do
      hits = scan_for(pattern)
      expect(hits).to be_empty,
        "#{hits.size} forbidden #{pattern.name} hit(s):\n#{hits.join("\n")}"
    end
  end
end
