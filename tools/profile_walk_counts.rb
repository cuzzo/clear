# typed: false
#!/usr/bin/env ruby

require "bundler/setup"
require "sorbet-runtime"
T::Configuration.default_checked_level = :never

ROOT = File.expand_path("..", __dir__)
SRC_ROOT = File.join(ROOT, "src")
$LOAD_PATH.unshift(SRC_ROOT)
$LOAD_PATH.unshift(File.join(SRC_ROOT, "ast"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "mir"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "backends"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "annotator-helpers"))

require "benchmark"
require "compiler/compiler_frontend"
require "compiler/module_importer"
require "mir_lowering"
require "mir_checker"
require "backends/mir_emitter"

source_path = File.expand_path(ARGV.fetch(0) { "examples/minivm/vm.cht" })
source = File.read(source_path)
source_dir = File.dirname(source_path)

COUNTS = Hash.new { |h, k| h[k] = { calls: 0, yields: 0, seconds: 0.0 } }

def caller_key
  loc = caller_locations(2, 12).find do |frame|
    path = frame.absolute_path || frame.path
    path.start_with?(SRC_ROOT) && !path.end_with?("src/ast/ast.rb") && !path.end_with?("src/mir/mir.rb")
  end
  return "unknown" unless loc

  path = loc.absolute_path || loc.path
  "#{path.delete_prefix("#{ROOT}/")}:#{loc.lineno}:in #{loc.base_label}"
end

class << AST
  alias_method :__walk_profile_each_locatable, :each_locatable
  alias_method :__walk_profile_walk_body, :walk_body
  alias_method :__walk_profile_each_bg_block, :each_bg_block

  def each_locatable(root, descend_functions: false, &visitor)
    key = ["AST.each_locatable", caller_key]
    count = 0
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    __walk_profile_each_locatable(root, descend_functions: descend_functions) do |node|
      count += 1
      visitor.call(node)
    end
  ensure
    rec = COUNTS[key]
    rec[:calls] += 1
    rec[:yields] += count
    rec[:seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end

  def walk_body(body, &visitor)
    key = ["AST.walk_body", caller_key]
    count = 0
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    __walk_profile_walk_body(body) do |node|
      count += 1
      visitor.call(node)
    end
  ensure
    rec = COUNTS[key]
    rec[:calls] += 1
    rec[:yields] += count
    rec[:seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end

  def each_bg_block(body, &visitor)
    key = ["AST.each_bg_block", caller_key]
    count = 0
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    __walk_profile_each_bg_block(body) do |node|
      count += 1
      visitor.call(node)
    end
  ensure
    rec = COUNTS[key]
    rec[:calls] += 1
    rec[:yields] += count
    rec[:seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end
end

module MIR
  class << self
    alias_method :__walk_profile_each_node, :each_node
    alias_method :__walk_profile_each_surface_node, :each_surface_node
    alias_method :__walk_profile_nodes, :nodes
    alias_method :__walk_profile_surface_nodes, :surface_nodes

    def each_node(root, &blk)
      key = ["MIR.each_node", caller_key]
      count = 0
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      __walk_profile_each_node(root) do |node|
        count += 1
        blk.call(node)
      end
    ensure
      rec = COUNTS[key]
      rec[:calls] += 1
      rec[:yields] += count
      rec[:seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end

    def each_surface_node(root, &blk)
      key = ["MIR.each_surface_node", caller_key]
      count = 0
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      __walk_profile_each_surface_node(root) do |node|
        count += 1
        blk.call(node)
      end
    ensure
      rec = COUNTS[key]
      rec[:calls] += 1
      rec[:yields] += count
      rec[:seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end

    def nodes(root)
      key = ["MIR.nodes", caller_key]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out = __walk_profile_nodes(root)
    ensure
      rec = COUNTS[key]
      rec[:calls] += 1
      rec[:yields] += out ? out.length : 0
      rec[:seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end

    def surface_nodes(root)
      key = ["MIR.surface_nodes", caller_key]
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out = __walk_profile_surface_nodes(root)
    ensure
      rec = COUNTS[key]
      rec[:calls] += 1
      rec[:yields] += out ? out.length : 0
      rec[:seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end
  end
end

elapsed = Benchmark.realtime do
  importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
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
  items = (mod[:items] + mod[:type_items]).flatten
  checker = MIRChecker.new
  items.grep(MIR::FnDef).each do |fn|
    errors = checker.check_fn!(fn, strict: true)
    raise errors.join("\n") unless errors.empty?
  end
  emitter = MIREmitter.new
  items.each { |item| emitter.emit(item) }
end

puts "elapsed=#{format("%.6f", elapsed)}"
puts "kind,calls,yields,seconds,caller"
COUNTS
  .map { |(kind, caller), rec| [kind, caller, rec] }
  .sort_by { |_kind, _caller, rec| [-rec[:seconds], -rec[:yields], -rec[:calls]] }
  .first(80)
  .each do |kind, caller, rec|
    puts "#{kind},#{rec[:calls]},#{rec[:yields]},#{format("%.6f", rec[:seconds])},#{caller}"
  end
