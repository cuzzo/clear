# typed: false
#!/usr/bin/env ruby

require "bundler/setup"
require "json"
require "optparse"

ROOT = File.expand_path("..", __dir__)
SRC_ROOT = File.join(ROOT, "src")
$LOAD_PATH.unshift(SRC_ROOT)
$LOAD_PATH.unshift(File.join(SRC_ROOT, "ast"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "mir"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "backends"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "annotator-helpers"))

options = {
  interval: 0.001,
  output: "/tmp/cheat-stack-samples.json",
  checked: true,
  mode: "full",
  top: 40,
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/sample_compile_stacks.rb [options] path/to/file.cht"
  opts.on("--interval SECONDS", Float, "Sampling interval, default 0.001") { |v| options[:interval] = v }
  opts.on("-o", "--output PATH", "Write JSON report") { |v| options[:output] = v }
  opts.on("--unchecked", "Disable Sorbet runtime call validation before loading compiler") { options[:checked] = false }
  opts.on("--mode MODE", "full or frontend-only") { |v| options[:mode] = v }
  opts.on("--top N", Integer, "Rows to print per section") { |v| options[:top] = v }
end.parse!

unless options[:checked]
  require "sorbet-runtime"
  T::Configuration.default_checked_level = :never
end

require "benchmark"
require "backends/compiler_frontend"
require "backends/importer"
require "backends/pipeline_rewriter"
require "backends/string_concat_rewriter"
require "mir/hoist"
require "mir/pre_mir_type_check"
require "mir/mir_pass"
require "mir_lowering"
require "mir_checker"
require "mir_emitter"

source_path = File.expand_path(ARGV.fetch(0) do
  warn "missing source path"
  exit 1
end)

source = File.read(source_path)
source_dir = File.dirname(source_path)

class StackSampler
  def initialize(thread, interval:)
    @thread = thread
    @interval = interval
    @phase = "idle"
    @samples_by_phase = Hash.new(0)
    @leaf_by_phase = Hash.new(0)
    @frame_by_phase = Hash.new(0)
    @stack_by_phase = Hash.new(0)
    @running = false
  end

  attr_reader :samples_by_phase, :leaf_by_phase, :frame_by_phase, :stack_by_phase
  attr_accessor :phase

  def start
    @running = true
    @sampler_thread = Thread.new do
      while @running
        sleep @interval
        sample
      end
    end
  end

  def stop
    @running = false
    @sampler_thread&.join
  end

  def sample
    locs = @thread.backtrace_locations
    return unless locs && !locs.empty?

    phase = @phase
    frames = locs.map { |loc| frame_label(loc) }.reject { |label| label.include?("/tools/sample_compile_stacks.rb:") }
    return if frames.empty?

    @samples_by_phase[phase] += 1
    @leaf_by_phase[[phase, frames.first]] += 1
    frames.each { |frame| @frame_by_phase[[phase, frame]] += 1 }
    @stack_by_phase[[phase, frames.join(";")]] += 1
  end

  def frame_label(loc)
    path = loc.absolute_path || loc.path
    rel = path.start_with?(ROOT) ? path.delete_prefix("#{ROOT}/") : path
    "#{rel}:#{loc.lineno}:in #{loc.base_label}"
  end
end

def timed_phase(name, sampler, timings)
  sampler.phase = name
  before_gc = GC.stat
  value = nil
  elapsed = Benchmark.realtime { value = yield }
  after_gc = GC.stat
  timings[name] = {
    seconds: elapsed,
    gc_allocated_objects: after_gc[:total_allocated_objects] - before_gc[:total_allocated_objects],
    gc_freed_objects: after_gc[:total_freed_objects] - before_gc[:total_freed_objects],
    gc_count: after_gc[:count] - before_gc[:count],
  }
  sampler.phase = "idle"
  value
end

IMPORTER_STATS = Hash.new { |h, k| h[k] = { calls: 0, seconds: 0.0 } }
module ImporterTimingProbe
  def compile_file(path, *args, **kwargs, &blk)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    super
  ensure
    key = "compile_file #{path}"
    IMPORTER_STATS[key][:calls] += 1
    IMPORTER_STATS[key][:seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end

  def compile_module_mir(ast, annotator, source_dir, *args, **kwargs, &blk)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    super
  ensure
    key = "compile_module_mir #{source_dir}"
    IMPORTER_STATS[key][:calls] += 1
    IMPORTER_STATS[key][:seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  end
end
ModuleImporter.prepend(ImporterTimingProbe)

main_thread = Thread.current
sampler = StackSampler.new(main_thread, interval: options[:interval])
timings = {}
sampler.start

frontend = nil
program = nil
items = nil

begin
  importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
  tokens = timed_phase("lex", sampler, timings) { Lexer.new(source).tokenize }
  ast = timed_phase("parse", sampler, timings) { Parser.new(tokens, source).parse }
  annotator = SemanticAnnotator.new(importer: importer, source_dir: source_dir, strict_test: false, source_code: source)
  timed_phase("annotate", sampler, timings) { annotator.annotate!(ast) }
  timed_phase("pipeline_rewrite", sampler, timings) do
    PipelineRewriter.new(annotator).rewrite!(ast)
    MIRPassState.for!(ast).mark!(:pipeline_rewritten)
  end
  timed_phase("string_concat_rewrite", sampler, timings) do
    StringConcatRewriter.new.rewrite!(ast)
    MIRPassState.for!(ast).mark!(:string_concat_rewritten)
  end
  schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
  timed_phase("hoist", sampler, timings) { Hoist.apply!(ast, schema_lookup: schema_lookup) }
  fn_nodes = {}
  ast.statements.each { |stmt| fn_nodes[stmt.name] = stmt if stmt.is_a?(AST::FunctionDef) }
  timed_phase("synthesize_tests", sampler, timings) { CompilerFrontend.synthesize_test_body_wrappers!(ast, fn_nodes) }
  timed_phase("pre_mir_type_check", sampler, timings) { PreMirTypeCheck.verify!(ast) }
  timed_phase("mir_pass", sampler, timings) { MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup).transform!(ast) }

  struct_schemas = {}
  enum_schemas = {}
  union_schemas = {}
  ast.statements.each do |stmt|
    case stmt
    when AST::StructDef then struct_schemas[stmt.name.to_sym] = Schemas::StructSchema.new(fields: stmt.field_decls)
    when AST::EnumDef then enum_schemas[stmt.name.to_sym] = stmt.variants
    when AST::UnionDef
      union_schemas[stmt.name.to_sym] = Schemas::UnionSchema.new(
        variants: stmt.variants,
        type_params: stmt.type_params&.any? ? stmt.type_params.map(&:to_sym) : nil,
        visibility: stmt.visibility || :package,
      )
    end
  end
  fn_sigs = {}
  ast.statements.each do |stmt|
    fn_sigs[stmt.name] = FunctionSignature.from_function_def(stmt) if stmt.is_a?(AST::FunctionDef)
  end
  annotator.scope_stack.first.locals.each do |name, entry|
    next if fn_sigs.key?(name)
    sig = entry.fn_signature
    fn_sigs[name] = sig if sig && sig.module_alias
  end
  moved_guard_info = {}
  fn_nodes.each { |name, fn| moved_guard_info[name] = fn.moved_guard_info if fn.moved_guard_info }
  frontend = CompilerFrontend::Result.new(ast, annotator, fn_nodes, fn_sigs, struct_schemas, enum_schemas, union_schemas, moved_guard_info)

  unless options[:mode] == "frontend-only"
    lowering = MIRLowering.new(
      struct_schemas: frontend.struct_schemas,
      enum_schemas: frontend.enum_schemas,
      union_schemas: frontend.union_schemas,
      fn_sigs: frontend.fn_sigs,
      moved_guard_info: frontend.moved_guard_info,
      importer: importer,
      source_dir: source_dir,
    )
    program = timed_phase("lower", sampler, timings) { lowering.lower_module(frontend.ast) }
    items = (program[:items] + program[:type_items]).flatten
    fns = items.select { |item| item.is_a?(MIR::FnDef) }
    checker = MIRChecker.new
    timed_phase("checker", sampler, timings) do
      fns.each do |fn|
        errors = checker.check_fn!(fn, strict: true)
        raise errors.join("\n") unless errors.empty?
      end
    end
    emitter = MIREmitter.new
    timed_phase("emit", sampler, timings) { items.each { |item| emitter.emit(item) } }
  end
ensure
  sampler.stop
end

def top_counts(hash, phase, limit)
  hash
    .select { |(ph, _key), _count| ph == phase }
    .map { |(_ph, key), count| { key: key, count: count } }
    .sort_by { |row| -row[:count] }
    .first(limit)
end

report = {
  source_path: source_path,
  checked: options[:checked],
  interval: options[:interval],
  timings: timings,
  importer: IMPORTER_STATS.map { |key, val| { key: key, calls: val[:calls], seconds: val[:seconds] } }.sort_by { |row| [-row[:seconds], row[:key]] },
  phases: {},
}

timings.keys.each do |phase|
  samples = sampler.samples_by_phase[phase].to_i
  report[:phases][phase] = {
    samples: samples,
    top_leaf: top_counts(sampler.leaf_by_phase, phase, options[:top]),
    top_frames: top_counts(sampler.frame_by_phase, phase, options[:top]),
    top_stacks: top_counts(sampler.stack_by_phase, phase, [options[:top], 20].min),
  }
end

File.write(options[:output], JSON.pretty_generate(report))

puts "checked=#{options[:checked]} interval=#{options[:interval]} output=#{options[:output]}"
puts timings.map { |name, data| "#{name}=#{format("%.6f", data[:seconds])}" }.join(" ")
puts "total=#{format("%.6f", timings.values.sum { |data| data[:seconds] })}"
puts "== importer =="
report[:importer].first(options[:top]).each do |row|
  puts "%10.6f %5d %s" % [row[:seconds], row[:calls], row[:key]]
end
timings.keys.each do |phase|
  samples = report[:phases][phase][:samples]
  puts "== #{phase} samples=#{samples} =="
  report[:phases][phase][:top_frames].first(15).each do |row|
    pct = samples.zero? ? 0.0 : row[:count] * 100.0 / samples
    puts "%7.2f%% %6d %s" % [pct, row[:count], row[:key]]
  end
end
