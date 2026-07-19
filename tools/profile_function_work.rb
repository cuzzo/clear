# typed: false
#!/usr/bin/env ruby

require "bundler/setup"
require "sorbet-runtime"
T::Configuration.default_checked_level = :never

require "benchmark"

ROOT = File.expand_path("..", __dir__)
SRC_ROOT = File.join(ROOT, "compiler", "ruby")
$LOAD_PATH.unshift(SRC_ROOT)
$LOAD_PATH.unshift(File.join(SRC_ROOT, "ast"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "mir"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "backends"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "annotator-helpers"))

require "compiler/compiler_frontend"
require "compiler/module_importer"
require "mir_lowering"
require "mir_checker"

source_path = File.expand_path(ARGV.fetch(0) { "examples/minivm/vm.clear" })
source = File.read(source_path)
source_dir = File.dirname(source_path)

def ast_count(body)
  count = 0
  AST.each_locatable(body) { count += 1 }
  count
end

def mir_count(root)
  count = 0
  MIR.each_node(root) { count += 1 }
  count
end

def recursive_mir_count(root)
  mir_count(root)
end

def direct_mir_count(body)
  return 0 unless body.is_a?(Array)
  body.length
end

importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
frontend = nil
frontend_time = Benchmark.realtime do
  frontend = CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
end

lowering = MIRLowering.new(input: MIRLoweringInput.new(
  struct_schemas: frontend.struct_schemas,
  enum_schemas: frontend.enum_schemas,
  union_schemas: frontend.union_schemas,
  schema_lookup: ->(name) { frontend.annotator.lookup_type_schema(name) },
  lifecycle_registry: frontend.lifecycle_registry,
  fn_sigs: frontend.fn_sigs,
  moved_guard_info: frontend.moved_guard_info,
  importer: importer,
  source_dir: source_dir,
))

rows = []
frontend.fn_nodes.each do |name, fn|
  next unless fn.body
  lowered = nil
  lower_time = Benchmark.realtime { lowered = lowering.lower(fn) }
  checker_time = 0.0
  errors = []
  if lowered.is_a?(MIR::FnDef)
    checker = MIRChecker.new
    checker_time = Benchmark.realtime { errors = checker.check_fn!(lowered, strict: true) }
  end
  rows << {
    name: name,
    line: fn.token&.line,
    source_ast: ast_count(fn.body),
    lower_time: lower_time,
    checker_time: checker_time,
    mir_direct: lowered.is_a?(MIR::FnDef) ? direct_mir_count(lowered.body) : 0,
    mir_recursive: lowered.is_a?(MIR::FnDef) ? recursive_mir_count(lowered.body) : 0,
    errors: errors.length,
  }
end

puts "frontend=#{format("%.6f", frontend_time)} functions=#{rows.length}"
puts "name,line,source_ast,mir_direct,mir_recursive,mir_per_ast,lower_s,checker_s,errors"
rows.sort_by { |row| [-row[:mir_recursive], -row[:source_ast], row[:name]] }.each do |row|
  ratio = row[:source_ast].zero? ? 0.0 : row[:mir_recursive].to_f / row[:source_ast]
  puts [
    row[:name],
    row[:line],
    row[:source_ast],
    row[:mir_direct],
    row[:mir_recursive],
    format("%.2f", ratio),
    format("%.6f", row[:lower_time]),
    format("%.6f", row[:checker_time]),
    row[:errors],
  ].join(",")
end
