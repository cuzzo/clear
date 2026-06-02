# typed: false
#!/usr/bin/env ruby

require "bundler/setup"
require "sorbet-runtime"
T::Configuration.default_checked_level = :never

require "benchmark"

ROOT = File.expand_path("..", __dir__)
SRC_ROOT = File.join(ROOT, "src")
$LOAD_PATH.unshift(SRC_ROOT)
$LOAD_PATH.unshift(File.join(SRC_ROOT, "ast"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "mir"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "backends"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "annotator-helpers"))

require "backends/compiler_frontend"
require "backends/importer"
require "mir_lowering"
require "mir_checker"
require "mir_emitter"

source_path = File.expand_path(ARGV.fetch(0) { "examples/minivm/vm.cht" })
source = File.read(source_path)
source_dir = File.dirname(source_path)

Record = Struct.new(:calls, :units, :seconds, keyword_init: true)
COUNTS = Hash.new { |h, k| h[k] = Record.new(calls: 0, units: 0, seconds: 0.0) }

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def src_caller
  loc = caller_locations(2, 24).find do |frame|
    path = frame.absolute_path || frame.path
    path.start_with?(SRC_ROOT) &&
      !path.end_with?("tools/profile_structural_multipliers.rb") &&
      !path.end_with?("src/ast/ast.rb") &&
      !path.end_with?("src/ast/scope.rb") &&
      !path.end_with?("src/ast/symbol_entry.rb") &&
      !path.end_with?("src/semantic/ownership_graph.rb")
  end
  return "unknown" unless loc

  path = loc.absolute_path || loc.path
  "#{path.delete_prefix("#{ROOT}/")}:#{loc.lineno}:in #{loc.base_label}"
end

def add_count(kind, caller_key, units, seconds)
  rec = COUNTS[[kind, caller_key]]
  rec.calls += 1
  rec.units += units
  rec.seconds += seconds
end

class Scope
  alias_method :__structural_profile_initialize_copy, :initialize_copy

  def initialize_copy(original)
    start = now
    __structural_profile_initialize_copy(original)
  ensure
    add_count("Scope#dup entries", src_caller, original.locals.length, now - start)
  end
end

class SymbolEntry
  alias_method :__structural_profile_initialize_copy, :initialize_copy

  def initialize_copy(original)
    start = now
    __structural_profile_initialize_copy(original)
  ensure
    add_count("SymbolEntry#dup", src_caller, 1, now - start)
  end
end

class OwnershipGraph
  alias_method :__structural_profile_fork_lightweight, :fork_lightweight
  alias_method :__structural_profile_restore_lightweight, :restore_lightweight

  def fork_lightweight
    start = now
    __structural_profile_fork_lightweight
  ensure
    add_count("OwnershipGraph#fork states", src_caller, @nodes.length, now - start)
  end

  def restore_lightweight(snapshot)
    start = now
    __structural_profile_restore_lightweight(snapshot)
  ensure
    add_count("OwnershipGraph#restore states", src_caller, snapshot ? snapshot.node_states.length : 0, now - start)
  end
end

class SemanticAnnotator
  alias_method :__structural_profile_analyze_control_flow_branches, :analyze_control_flow_branches

  def analyze_control_flow_branches(branches, merge_to_parent: true)
    start = now
    fn = current_fn_ctx&.name || "<top>"
    __structural_profile_analyze_control_flow_branches(branches, merge_to_parent: merge_to_parent)
  ensure
    add_count("branches #{fn}", src_caller, branches.length, now - start)
  end
end

module ScopeHelper
  alias_method :__structural_profile_with_new_scope, :with_new_scope

  def with_new_scope(scope = nil, &blk)
    copied_locals = scope ? scope.locals.length : 0
    start = now
    __structural_profile_with_new_scope(scope, &blk)
  ensure
    add_count("ScopeHelper#with_new_scope copied locals", src_caller, copied_locals, now - start)
  end
end

class << AST
  alias_method :__structural_profile_each_locatable, :each_locatable
  alias_method :__structural_profile_walk_body, :walk_body

  def each_locatable(root, descend_functions: false, &visitor)
    start = now
    count = 0
    __structural_profile_each_locatable(root, descend_functions: descend_functions) do |node|
      count += 1
      visitor.call(node)
    end
  ensure
    add_count("AST.each_locatable yields", src_caller, count, now - start)
  end

  def walk_body(body, &visitor)
    start = now
    count = 0
    __structural_profile_walk_body(body) do |node|
      count += 1
      visitor.call(node)
    end
  ensure
    add_count("AST.walk_body yields", src_caller, count, now - start)
  end
end

module MIR
  class << self
    alias_method :__structural_profile_each_node, :each_node
    alias_method :__structural_profile_each_surface_node, :each_surface_node
    alias_method :__structural_profile_nodes, :nodes
    alias_method :__structural_profile_surface_nodes, :surface_nodes

    def each_node(root, &blk)
      start = now
      count = 0
      __structural_profile_each_node(root) do |node|
        count += 1
        blk.call(node)
      end
    ensure
      add_count("MIR.each_node yields", src_caller, count, now - start)
    end

    def each_surface_node(root, &blk)
      start = now
      count = 0
      __structural_profile_each_surface_node(root) do |node|
        count += 1
        blk.call(node)
      end
    ensure
      add_count("MIR.each_surface_node yields", src_caller, count, now - start)
    end

    def nodes(root)
      start = now
      out = __structural_profile_nodes(root)
    ensure
      add_count("MIR.nodes length", src_caller, out ? out.length : 0, now - start)
    end

    def surface_nodes(root)
      start = now
      out = __structural_profile_surface_nodes(root)
    ensure
      add_count("MIR.surface_nodes length", src_caller, out ? out.length : 0, now - start)
    end
  end
end

timings = {}
importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
frontend = nil
timings[:frontend] = Benchmark.realtime do
  frontend = CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
end

lowering = MIRLowering.new(
  struct_schemas: frontend.struct_schemas,
  enum_schemas: frontend.enum_schemas,
  union_schemas: frontend.union_schemas,
  fn_sigs: frontend.fn_sigs,
  moved_guard_info: frontend.moved_guard_info,
  importer: importer,
  source_dir: source_dir,
)

mod = nil
timings[:lower] = Benchmark.realtime { mod = lowering.lower_module(frontend.ast) }
items = (mod[:items] + mod[:type_items]).flatten
fns = items.grep(MIR::FnDef)
checker = MIRChecker.new
timings[:checker] = Benchmark.realtime do
  fns.each do |fn|
    errors = checker.check_fn!(fn, strict: true)
    raise errors.join("\n") unless errors.empty?
  end
end
emitter = MIREmitter.new
timings[:emit] = Benchmark.realtime { items.each { |item| emitter.emit(item) } }

puts "timings #{timings.map { |k, v| "#{k}=#{format("%.6f", v)}" }.join(" ")} total=#{format("%.6f", timings.values.sum)}"
puts "kind,calls,units,seconds,caller"
COUNTS
  .map { |(kind, caller), rec| [kind, caller, rec] }
  .sort_by { |_kind, _caller, rec| [-rec.units, -rec.seconds, -rec.calls] }
  .first(120)
  .each do |kind, caller, rec|
    puts "#{kind},#{rec.calls},#{rec.units},#{format("%.6f", rec.seconds)},#{caller}"
  end
