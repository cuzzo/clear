# typed: false
#!/usr/bin/env ruby

require "bundler/setup"
require "benchmark"
require "optparse"

root = File.expand_path("..", __dir__)
src_root = File.join(root, "src")
$LOAD_PATH.unshift(src_root)
$LOAD_PATH.unshift(File.join(src_root, "ast"))
$LOAD_PATH.unshift(File.join(src_root, "mir"))
$LOAD_PATH.unshift(File.join(src_root, "backends"))
$LOAD_PATH.unshift(File.join(src_root, "annotator-helpers"))

require "backends/compiler_frontend"
require "backends/importer"
require "mir_lowering"
require "mir_checker"
require "mir_emitter"

options = {
  phase: "frontend",
  limit: 40,
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/profile_compile_hotspots.rb [options] path/to/file.cht"
  opts.on("--phase NAME", "frontend, annotate, mir_pass, lower, checker, all") { |v| options[:phase] = v }
  opts.on("--limit N", Integer, "Rows to print") { |v| options[:limit] = v }
end.parse!

source_path = File.expand_path(ARGV.fetch(0) do
  warn "missing source path"
  exit 1
end)

module HotspotProfiler
  Record = Struct.new(:calls, :inclusive, :self_time, keyword_init: true)

  @records = Hash.new { |h, k| h[k] = Record.new(calls: 0, inclusive: 0.0, self_time: 0.0) }
  @stack = []
  @wrapped = {}

  class << self
    attr_reader :records

    def reset!
      @records.clear
      @stack.clear
    end

    def instrument!(roots, name_patterns: [])
      root_prefixes = roots.map { |path| File.expand_path(path) }
      name_patterns = Array(name_patterns)
      modules = ObjectSpace.each_object(Module).to_a
      modules.each { |mod| wrap_instance_methods!(mod, root_prefixes, name_patterns) }
      modules.each { |mod| wrap_singleton_methods!(mod, root_prefixes, name_patterns) }
    end

    def report(limit:)
      rows = @records.map do |key, rec|
        [rec.self_time, rec.inclusive, rec.calls, key]
      end
      puts "== self time =="
      rows.sort_by { |self_time, inclusive, calls, _key| [-self_time, -inclusive, -calls] }.first(limit).each do |self_time, inclusive, calls, key|
        print_row(self_time, inclusive, calls, key)
      end
      puts "== inclusive time =="
      rows.sort_by { |self_time, inclusive, calls, _key| [-inclusive, -self_time, -calls] }.first(limit).each do |self_time, inclusive, calls, key|
        print_row(self_time, inclusive, calls, key)
      end
    end

    def print_row(self_time, inclusive, calls, key)
      avg_us = calls.zero? ? 0.0 : inclusive * 1_000_000.0 / calls
      puts "%10.6f self  %10.6f incl  %8d calls  %9.1f us/call  %s" %
        [self_time, inclusive, calls, avg_us, key]
    end

    def track(key)
      frame = { key: key, child: 0.0 }
      @stack << frame
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        yield
      ensure
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        @stack.pop
        rec = @records[key]
        rec.calls += 1
        rec.inclusive += elapsed
        rec.self_time += elapsed - frame[:child]
        @stack.last[:child] += elapsed if @stack.last
      end
    end

    private

    def wrap_instance_methods!(mod, root_prefixes, name_patterns)
      methods = mod.instance_methods(false) + mod.private_instance_methods(false) + mod.protected_instance_methods(false)
      wrap_methods!(mod, methods, root_prefixes, name_patterns, singleton: false)
    end

    def wrap_singleton_methods!(mod, root_prefixes, name_patterns)
      singleton = mod.singleton_class
      methods = singleton.instance_methods(false) + singleton.private_instance_methods(false) + singleton.protected_instance_methods(false)
      wrap_methods!(singleton, methods, root_prefixes, name_patterns, singleton: true, owner_name: mod.name || mod.inspect)
    end

    def wrap_methods!(target, methods, root_prefixes, name_patterns, singleton:, owner_name: nil)
      label_owner = owner_name || target.name || target.inspect
      owner_selected = name_patterns.any? { |pattern| label_owner.match?(pattern) }
      selected = methods.uniq.filter_map do |name|
        loc = target.instance_method(name).source_location rescue nil
        file = loc ? File.expand_path(loc[0]) : nil
        line = loc ? loc[1] : nil
        source_selected = file && root_prefixes.any? { |prefix| file.start_with?(prefix) }
        next nil unless source_selected || owner_selected
        [name, file, line]
      end
      return if selected.empty?

      key = [target.object_id, selected.map(&:first)].hash
      return if @wrapped[key]
      @wrapped[key] = true

      wrapper = Module.new
      selected.each do |name, file, line|
        loc = file ? "#{file.sub(Dir.pwd + "/", "")}:#{line}" : "unknown"
        label = "#{label_owner}##{name} #{loc}"
        wrapper.define_method(name) do |*args, &blk|
          HotspotProfiler.track(label) { super(*args, &blk) }
        end
        wrapper.send(:ruby2_keywords, name) if wrapper.respond_to?(:ruby2_keywords, true)
      end
      target.prepend(wrapper)
    end
  end
end

source = File.read(source_path)
source_dir = File.dirname(source_path)
importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)

annotator_roots = [
  File.join(src_root, "annotator"),
  File.join(src_root, "semantic"),
  File.join(src_root, "ast", "type.rb"),
]
mir_pass_roots = [
  File.join(src_root, "mir", "mir_pass.rb"),
  File.join(src_root, "mir", "cleanup_classifier.rb"),
  File.join(src_root, "semantic"),
]
lower_roots = [
  File.join(src_root, "mir"),
]
checker_roots = [
  File.join(src_root, "mir", "mir_checker.rb"),
]

phase = options[:phase]
roots =
  case phase
  when "frontend", "annotate"
    annotator_roots
  when "mir_pass"
    mir_pass_roots
  when "lower"
    lower_roots
  when "checker"
    checker_roots
  when "all"
    annotator_roots + mir_pass_roots + lower_roots + checker_roots
  else
    warn "unknown phase #{phase.inspect}"
    exit 1
  end

name_patterns =
  case phase
  when "frontend", "annotate"
    [
      /\ASemanticAnnotator\z/,
      /\AAnnotator::/,
      /\AFunctionAnalysis\z/,
      /\APipeAnalysis\z/,
      /\AGenericAnalysis\z/,
      /\AEffectTracker\z/,
      /\AReentranceBridge\z/,
      /\ACapability/,
      /\AMethodAnalysis\z/,
      /\AUnionAnalysis\z/,
      /\ALockHelper\z/,
      /\ATestAnnotation\z/,
      /\AIntrinsicRegistry\z/,
      /\AFunctionSignature\z/,
      /\AType\z/,
      /\AConcurrencyChecks\z/,
      /\AEffectInference\z/,
    ]
  when "mir_pass"
    [
      /\AMIRPass\z/,
      /\ACleanupClassifier\z/,
      /\AEscapeAnalysis\z/,
      /\ABgCaptureClassifier\z/,
      /\ALoopFrameAnalysis\z/,
      /\AFunctionCFG\z/,
      /\AEscapeDataflow\z/,
      /\AType\z/,
    ]
  when "lower"
    [
      /\AMIRLowering/,
      /\AMIR::/,
      /\AType\z/,
    ]
  when "checker"
    [
      /\AMIRChecker\z/,
      /\AType\z/,
    ]
  else
    [
      /\ASemanticAnnotator\z/,
      /\AAnnotator::/,
      /\AMIRPass\z/,
      /\AMIRLowering/,
      /\AMIRChecker\z/,
      /\ACleanupClassifier\z/,
      /\AEscapeAnalysis\z/,
      /\ABgCaptureClassifier\z/,
      /\ALoopFrameAnalysis\z/,
      /\AType\z/,
    ]
  end

HotspotProfiler.instrument!(roots, name_patterns: name_patterns)

tokens = nil
ast = nil
frontend = nil
program = nil
timings = {}

if phase == "annotate"
  tokens = Lexer.new(source).tokenize
  ast = Parser.new(tokens, source).parse
  timings["annotate"] = Benchmark.realtime do
    SemanticAnnotator.new(importer: importer, source_dir: source_dir, source_code: source).annotate!(ast)
  end
elsif phase == "mir_pass"
  tokens = Lexer.new(source).tokenize
  ast = Parser.new(tokens, source).parse
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
  timings["mir_pass"] = Benchmark.realtime do
    MIRPass.new(
      fn_nodes: fn_nodes,
      schema_lookup: schema_lookup,
      body_summaries: annotator.semantic_index.body_summaries
    ).transform!(ast)
  end
elsif phase == "lower"
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
  timings["lower"] = Benchmark.realtime { program = lowering.lower_module(frontend.ast) }
elsif phase == "checker"
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
  program = lowering.lower_module(frontend.ast)
  items = (program[:items] + program[:type_items]).flatten
  fns = items.select { |item| item.is_a?(MIR::FnDef) }
  checker = MIRChecker.new
  timings["checker"] = Benchmark.realtime do
    fns.each do |fn|
      errors = checker.check_fn!(fn, strict: true)
      raise errors.join("\n") unless errors.empty?
    end
  end
else
  timings["frontend"] = Benchmark.realtime do
    frontend = CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
  end
  lowering = MIRLowering.new(input: MIRLoweringInput.new(
    struct_schemas: frontend.struct_schemas,
    enum_schemas: frontend.enum_schemas,
    union_schemas: frontend.union_schemas,
    fn_sigs: frontend.fn_sigs,
    moved_guard_info: frontend.moved_guard_info,
    importer: importer,
    source_dir: source_dir,
  ))
  timings["lower"] = Benchmark.realtime { program = lowering.lower_module(frontend.ast) }
end

warn timings.map { |k, v| "#{k}=#{format("%.6f", v)}" }.join(" ")
HotspotProfiler.report(limit: options[:limit])
