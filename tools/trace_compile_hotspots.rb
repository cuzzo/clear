# typed: false
#!/usr/bin/env ruby

require "bundler/setup"
require "benchmark"
require "optparse"

root = File.expand_path("..", __dir__)
src_root = File.join(root, "compiler", "ruby")
$LOAD_PATH.unshift(src_root)
$LOAD_PATH.unshift(File.join(src_root, "ast"))
$LOAD_PATH.unshift(File.join(src_root, "mir"))
$LOAD_PATH.unshift(File.join(src_root, "backends"))
$LOAD_PATH.unshift(File.join(src_root, "annotator-helpers"))

require "compiler/compiler_frontend"
require "compiler/module_importer"
require "mir_lowering"
require "mir_checker"
require "backends/mir_emitter"

options = { phase: "annotate", limit: 50 }
OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/trace_compile_hotspots.rb [options] path/to/file.clear"
  opts.on("--phase NAME", "annotate, mir_pass, lower, checker") { |v| options[:phase] = v }
  opts.on("--limit N", Integer) { |v| options[:limit] = v }
end.parse!

source_path = File.expand_path(ARGV.fetch(0) do
  warn "missing source path"
  exit 1
end)

Record = Struct.new(:calls, :inclusive, :self_time, keyword_init: true)

def selected_event?(tp, phase, src_root)
  path = File.expand_path(tp.path)
  owner = tp.defined_class.to_s
  case phase
  when "annotate"
    path.start_with?(File.join(src_root, "annotator")) ||
      path.start_with?(File.join(src_root, "semantic")) ||
      path == File.join(src_root, "ast", "type.rb") ||
      owner.match?(/\A(?:SemanticAnnotator|Annotator::|FunctionAnalysis|PipeAnalysis|GenericAnalysis|EffectTracker|ReentranceBridge|Capability|MethodAnalysis|UnionAnalysis|LockHelper|TestAnnotation|IntrinsicRegistry|FunctionSignature|Type|ConcurrencyChecks|EffectInference)/)
  when "mir_pass"
    path == File.join(src_root, "mir", "mir_pass.rb") ||
      path == File.join(src_root, "mir", "cleanup_classifier.rb") ||
      path.start_with?(File.join(src_root, "semantic")) ||
      owner.match?(/\A(?:MIRPass|CleanupClassifier|EscapeAnalysis|BgCaptureClassifier|LoopFrameAnalysis|FunctionCFG|EscapeDataflow|Type)/)
  when "lower"
    path.start_with?(File.join(src_root, "mir")) ||
      owner.match?(/\A(?:MIRLowering|MIR::|Type)/)
  when "checker"
    path == File.join(src_root, "mir", "mir_checker.rb") ||
      owner.match?(/\A(?:MIRChecker|Type)/)
  else
    false
  end
end

def run_phase(phase, source, source_dir, importer)
  case phase
  when "annotate"
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new(importer: importer, source_dir: source_dir, source_code: source).annotate!(ast)
  when "mir_pass"
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    annotator = SemanticAnnotator.new(importer: importer, source_dir: source_dir, source_code: source)
    annotator.annotate!(ast)
    PipelineRewriter.new(annotator).rewrite!(ast)
    MIRPassState.for!(ast).mark!(:pipeline_rewritten)
    StringConcatRewriter.new.rewrite!(ast)
    MIRPassState.for!(ast).mark!(:string_concat_rewritten)
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    Hoist.apply!(ast, schema_lookup: schema_lookup)
    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    CompilerFrontend.synthesize_test_body_wrappers!(ast, fn_nodes)
    PreMirTypeCheck.verify!(ast)
    MIRPass.new(
      fn_nodes: fn_nodes,
      schema_lookup: schema_lookup,
      body_summaries: annotator.semantic_index.body_summaries
    ).transform!(ast)
  when "lower"
    frontend = CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
    lowering = MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: frontend.struct_schemas,
      enum_schemas: frontend.enum_schemas,
      union_schemas: frontend.union_schemas,
      fn_sigs: frontend.fn_sigs,
      moved_guard_info: frontend.moved_guard_info,
      importer: importer,
      source_dir: source_dir,
    ))
    lowering.lower_module(frontend.ast)
  when "checker"
    frontend = CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
    lowering = MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: frontend.struct_schemas,
      enum_schemas: frontend.enum_schemas,
      union_schemas: frontend.union_schemas,
      fn_sigs: frontend.fn_sigs,
      moved_guard_info: frontend.moved_guard_info,
      importer: importer,
      source_dir: source_dir,
    ))
    mod = lowering.lower_module(frontend.ast)
    checker = MIRChecker.new
    (mod[:items] + mod[:type_items]).flatten.each do |item|
      next unless item.is_a?(MIR::FnDef)
      errors = checker.check_fn!(item, strict: true)
      raise errors.join("\n") unless errors.empty?
    end
  else
    raise "unknown phase #{phase.inspect}"
  end
end

source = File.read(source_path)
source_dir = File.dirname(source_path)
importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
phase = options[:phase]
records = Hash.new { |h, k| h[k] = Record.new(calls: 0, inclusive: 0.0, self_time: 0.0) }
stack = []

trace = TracePoint.new(:call, :return) do |tp|
  if tp.event == :call
    if selected_event?(tp, phase, src_root)
      key = "#{tp.defined_class}##{tp.method_id} #{tp.path.sub(Dir.pwd + "/", "")}:#{tp.lineno}"
      stack << { key: key, start: Process.clock_gettime(Process::CLOCK_MONOTONIC), child: 0.0 }
    else
      stack << nil
    end
  else
    frame = stack.pop
    next unless frame
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - frame[:start]
    rec = records[frame[:key]]
    rec.calls += 1
    rec.inclusive += elapsed
    rec.self_time += elapsed - frame[:child]
    stack.reverse_each do |parent|
      next unless parent
      parent[:child] += elapsed
      break
    end
  end
end

elapsed = nil
trace.enable do
  elapsed = Benchmark.realtime { run_phase(phase, source, source_dir, importer) }
end

warn "#{phase}=#{format("%.6f", elapsed)}"
rows = records.map { |key, rec| [rec.self_time, rec.inclusive, rec.calls, key] }
puts "== self time =="
rows.sort_by { |self_time, inclusive, calls, _| [-self_time, -inclusive, -calls] }.first(options[:limit]).each do |self_time, inclusive, calls, key|
  puts "%10.6f self  %10.6f incl  %8d calls  %9.1f us/call  %s" %
    [self_time, inclusive, calls, calls.zero? ? 0.0 : inclusive * 1_000_000 / calls, key]
end
puts "== inclusive time =="
rows.sort_by { |self_time, inclusive, calls, _| [-inclusive, -self_time, -calls] }.first(options[:limit]).each do |self_time, inclusive, calls, key|
  puts "%10.6f self  %10.6f incl  %8d calls  %9.1f us/call  %s" %
    [self_time, inclusive, calls, calls.zero? ? 0.0 : inclusive * 1_000_000 / calls, key]
end
