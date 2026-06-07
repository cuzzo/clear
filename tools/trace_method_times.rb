# typed: false
#!/usr/bin/env ruby

require "bundler/setup"
require "benchmark"
require "csv"
require "optparse"

root = File.expand_path("..", __dir__)
src_root = File.join(root, "src")
$LOAD_PATH.unshift(src_root)
$LOAD_PATH.unshift(File.join(src_root, "ast"))
$LOAD_PATH.unshift(File.join(src_root, "mir"))
$LOAD_PATH.unshift(File.join(src_root, "backends"))
$LOAD_PATH.unshift(File.join(src_root, "annotator-helpers"))

options = {
  phase: "full",
  output: "/tmp/cheat-method-times.csv",
  limit: 80,
  checked: false,
  targets: [src_root],
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/trace_method_times.rb [options] path/to/file.cht"
  opts.on("--phase NAME", "full, frontend, lower, checker, emit") { |v| options[:phase] = v }
  opts.on("-o", "--output PATH", "CSV output path") { |v| options[:output] = v }
  opts.on("--limit N", Integer, "Rows printed per sort") { |v| options[:limit] = v }
  opts.on("--checked", "Enable Sorbet runtime checks before loading compiler") { options[:checked] = true }
  opts.on("--unchecked", "Disable Sorbet runtime checks before loading compiler (default)") { options[:checked] = false }
  opts.on("--target PATH", "Trace methods whose source file is under PATH; repeatable") do |path|
    options[:targets] << File.expand_path(path, root)
  end
end.parse!

unless options[:checked]
  require "sorbet-runtime"
  T::Configuration.default_checked_level = :never
end

require "backends/compiler_frontend"
require "backends/importer"
require "mir_lowering"
require "mir_checker"
require "mir_emitter"

source_path = File.expand_path(ARGV.fetch(0) do
  warn "missing source path"
  exit 1
end)

source = File.read(source_path)
source_dir = File.dirname(source_path)
target_roots = options[:targets].map { |path| File.expand_path(path) }

class MethodTimeTrace
  Record = Struct.new(:owner, :method_name, :path, :line, :calls, :inclusive, :self_time, keyword_init: true)
  Frame = Struct.new(:key, :start, :child, keyword_init: true)

  def initialize(target_roots)
    @target_roots = target_roots
    @records = Hash.new do |h, key|
      owner, method_name, path, line = key
      h[key] = Record.new(
        owner: owner,
        method_name: method_name,
        path: path,
        line: line,
        calls: 0,
        inclusive: 0.0,
        self_time: 0.0,
      )
    end
    @stacks = Hash.new { |h, tid| h[tid] = [] }
  end

  attr_reader :records

  def run
    trace = TracePoint.new(:call, :return) do |tp|
      case tp.event
      when :call
        on_call(tp)
      when :return
        on_return(tp)
      end
    end
    trace.enable
    yield
  ensure
    trace&.disable
  end

  def write_csv(path)
    CSV.open(path, "w") do |csv|
      csv << %w[owner method path line calls inclusive_seconds self_seconds avg_inclusive_us avg_self_us]
      sorted_records.each do |rec|
        csv << [
          rec.owner,
          rec.method_name,
          rec.path,
          rec.line,
          rec.calls,
          format("%.9f", rec.inclusive),
          format("%.9f", rec.self_time),
          format("%.3f", rec.calls.zero? ? 0.0 : rec.inclusive * 1_000_000.0 / rec.calls),
          format("%.3f", rec.calls.zero? ? 0.0 : rec.self_time * 1_000_000.0 / rec.calls),
        ]
      end
    end
  end

  def print_report(limit)
    puts "== self time =="
    sorted_records.first(limit).each { |rec| print_record(rec) }
    puts "== inclusive time =="
    @records.values.sort_by { |rec| [-rec.inclusive, -rec.self_time, -rec.calls] }.first(limit).each { |rec| print_record(rec) }
    puts "== calls =="
    @records.values.sort_by { |rec| [-rec.calls, -rec.self_time, -rec.inclusive] }.first(limit).each { |rec| print_record(rec) }
  end

  private

  def sorted_records
    @records.values.sort_by { |rec| [-rec.self_time, -rec.inclusive, -rec.calls] }
  end

  def print_record(rec)
    avg = rec.calls.zero? ? 0.0 : rec.inclusive * 1_000_000.0 / rec.calls
    puts "%10.6f self  %10.6f incl  %8d calls  %9.1f us/call  %s#%s %s:%s" %
      [rec.self_time, rec.inclusive, rec.calls, avg, rec.owner, rec.method_name, rec.path, rec.line]
  end

  def on_call(tp)
    path = File.expand_path(tp.path)
    return unless target_path?(path)

    key = [owner_name(tp.defined_class), tp.method_id.to_s, path, tp.lineno]
    @stacks[Thread.current.object_id] << Frame.new(key: key, start: now, child: 0.0)
  end

  def on_return(tp)
    path = File.expand_path(tp.path)
    return unless target_path?(path)

    stack = @stacks[Thread.current.object_id]
    return if stack.empty?

    key = [owner_name(tp.defined_class), tp.method_id.to_s, path, tp.lineno]
    return unless stack.last&.key == key

    frame = stack.pop
    elapsed = now - frame.start
    rec = @records[frame.key]
    rec.calls += 1
    rec.inclusive += elapsed
    rec.self_time += elapsed - frame.child
    stack.last.child += elapsed if stack.last
  end

  def target_path?(path)
    @target_roots.any? { |root| path.start_with?(root) }
  end

  def owner_name(owner)
    owner.name || owner.inspect
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

def compile_frontend(source, source_dir)
  importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
  CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
end

def build_lowering(frontend, source_dir, importer)
  MIRLowering.new(input: MIRLoweringInput.new(
    struct_schemas: frontend.struct_schemas,
    enum_schemas: frontend.enum_schemas,
    union_schemas: frontend.union_schemas,
    fn_sigs: frontend.fn_sigs,
    moved_guard_info: frontend.moved_guard_info,
    importer: importer,
    source_dir: source_dir,
  ))
end

def compile_to_mir(source, source_dir)
  importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
  frontend = CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
  [frontend, build_lowering(frontend, source_dir, importer).lower_module(frontend.ast)]
end

trace = MethodTimeTrace.new(target_roots)
timings = {}

case options[:phase]
when "frontend"
  timings[:frontend] = Benchmark.realtime { trace.run { compile_frontend(source, source_dir) } }
when "lower"
  importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
  frontend = CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
  lowering = build_lowering(frontend, source_dir, importer)
  timings[:lower] = Benchmark.realtime { trace.run { lowering.lower_module(frontend.ast) } }
when "checker"
  _frontend, mod = compile_to_mir(source, source_dir)
  items = (mod[:items] + mod[:type_items]).flatten
  fns = items.select { |item| item.is_a?(MIR::FnDef) }
  checker = MIRChecker.new
  timings[:checker] = Benchmark.realtime do
    trace.run do
      fns.each do |fn|
        errors = checker.check_fn!(fn, strict: true)
        raise errors.join("\n") unless errors.empty?
      end
    end
  end
when "emit"
  _frontend, mod = compile_to_mir(source, source_dir)
  items = (mod[:items] + mod[:type_items]).flatten
  emitter = MIREmitter.new
  timings[:emit] = Benchmark.realtime { trace.run { items.each { |item| emitter.emit(item) } } }
when "full"
  importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
  frontend = nil
  mod = nil
  timings[:frontend] = Benchmark.realtime { trace.run { frontend = CompilerFrontend.compile(source, importer: importer, source_dir: source_dir) } }
  lowering = build_lowering(frontend, source_dir, importer)
  timings[:lower] = Benchmark.realtime { trace.run { mod = lowering.lower_module(frontend.ast) } }
  items = (mod[:items] + mod[:type_items]).flatten
  fns = items.select { |item| item.is_a?(MIR::FnDef) }
  checker = MIRChecker.new
  timings[:checker] = Benchmark.realtime do
    trace.run do
      fns.each do |fn|
        errors = checker.check_fn!(fn, strict: true)
        raise errors.join("\n") unless errors.empty?
      end
    end
  end
  emitter = MIREmitter.new
  timings[:emit] = Benchmark.realtime { trace.run { items.each { |item| emitter.emit(item) } } }
else
  warn "unknown phase #{options[:phase].inspect}"
  exit 1
end

trace.write_csv(options[:output])
puts timings.map { |k, v| "#{k}=#{format("%.6f", v)}" }.join(" ")
puts "csv=#{options[:output]}"
trace.print_report(options[:limit])
