# typed: false
#!/usr/bin/env ruby

require "bundler/setup"
require "optparse"

options = {
  phase: "full",
  out: "/tmp/cheat-stackprof.dump",
  mode: :wall,
  interval: 1000,
  checked: false,
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/stackprof_compile.rb [options] path/to/file.cht"
  opts.on("--phase NAME", "full, frontend, lower, checker, emit") { |v| options[:phase] = v }
  opts.on("-o", "--out PATH", "StackProf dump path") { |v| options[:out] = v }
  opts.on("--mode MODE", "wall, cpu, object") { |v| options[:mode] = v.to_sym }
  opts.on("--interval USEC", Integer, "Sampling interval in microseconds") { |v| options[:interval] = v }
  opts.on("--checked", "Enable Sorbet runtime checks before loading compiler") { options[:checked] = true }
  opts.on("--unchecked", "Disable Sorbet runtime checks before loading compiler (default)") { options[:checked] = false }
end.parse!

unless options[:checked]
  require "sorbet-runtime"
  T::Configuration.default_checked_level = :never
end

require "stackprof"
require "benchmark"

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

source_path = File.expand_path(ARGV.fetch(0) do
  warn "missing source path"
  exit 1
end)

source = File.read(source_path)
source_dir = File.dirname(source_path)

def compile_frontend(source, source_dir)
  importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
  [CompilerFrontend.compile(source, importer: importer, source_dir: source_dir), importer]
end

def build_lowering(frontend, importer, source_dir)
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

def compile_mir(source, source_dir)
  frontend, importer = compile_frontend(source, source_dir)
  mod = build_lowering(frontend, importer, source_dir).lower_module(frontend.ast)
  [frontend, importer, mod]
end

timings = {}

profiled = lambda do |name, &blk|
  value = nil
  timings[name] = Benchmark.realtime do
    StackProf.run(mode: options[:mode], interval: options[:interval], out: options[:out]) do
      value = blk.call
    end
  end
  value
end

case options[:phase]
when "frontend"
  profiled.call("frontend") { compile_frontend(source, source_dir).first }
when "lower"
  frontend, importer = compile_frontend(source, source_dir)
  lowering = build_lowering(frontend, importer, source_dir)
  profiled.call("lower") { lowering.lower_module(frontend.ast) }
when "checker"
  _frontend, _importer, mod = compile_mir(source, source_dir)
  items = (mod[:items] + mod[:type_items]).flatten
  fns = items.select { |item| item.is_a?(MIR::FnDef) }
  checker = MIRChecker.new
  profiled.call("checker") do
    fns.each do |fn|
      errors = checker.check_fn!(fn, strict: true)
      raise errors.join("\n") unless errors.empty?
    end
  end
when "emit"
  _frontend, _importer, mod = compile_mir(source, source_dir)
  items = (mod[:items] + mod[:type_items]).flatten
  emitter = MIREmitter.new
  profiled.call("emit") { items.each { |item| emitter.emit(item) } }
when "full"
  importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
  frontend = nil
  mod = nil
  profiled.call("full") do
    frontend = CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
    lowering = build_lowering(frontend, importer, source_dir)
    mod = lowering.lower_module(frontend.ast)
    items = (mod[:items] + mod[:type_items]).flatten
    fns = items.select { |item| item.is_a?(MIR::FnDef) }
    checker = MIRChecker.new
    fns.each do |fn|
      errors = checker.check_fn!(fn, strict: true)
      raise errors.join("\n") unless errors.empty?
    end
    emitter = MIREmitter.new
    items.each { |item| emitter.emit(item) }
  end
else
  warn "unknown phase #{options[:phase].inspect}"
  exit 1
end

puts "checked=#{options[:checked]} phase=#{options[:phase]} out=#{options[:out]}"
puts timings.map { |name, seconds| "#{name}=#{format("%.6f", seconds)}" }.join(" ")
