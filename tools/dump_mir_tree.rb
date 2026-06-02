# typed: false
#!/usr/bin/env ruby

require "bundler/setup"
require "json"
require "optparse"
require "benchmark"

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

options = {
  output: nil,
  module_mode: true,
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/dump_mir_tree.rb [options] path/to/file.cht"
  opts.on("-o", "--output PATH", "Write JSON to PATH") { |path| options[:output] = path }
  opts.on("--program", "Dump lower_program instead of lower_module") { options[:module_mode] = false }
end.parse!

source_path = ARGV.fetch(0) do
  warn "missing source path"
  exit 1
end

source_path = File.expand_path(source_path)
source = File.read(source_path)
source_dir = File.dirname(source_path)
output_path = options[:output] || File.join("/tmp", "#{File.basename(source_path, ".cht")}.mir-tree.json")

def primitive_json_value?(value)
  value.nil? || value.equal?(true) || value.equal?(false) ||
    value.is_a?(String) || value.is_a?(Numeric) || value.is_a?(Symbol)
end

class MirTreeDumper
  attr_reader :nodes

  def initialize
    @seen = {}
    @nodes = []
  end

  def dump(value, path = "$")
    case value
    when Array
      {
        "kind" => "array",
        "size" => value.length,
        "items" => value.each_with_index.map { |item, index| dump(item, "#{path}[#{index}]") },
      }
    when Hash
      {
        "kind" => "hash",
        "size" => value.length,
        "entries" => value.map do |key, item|
          {
            "key" => key.to_s,
            "value" => dump(item, "#{path}.#{key}"),
          }
        end,
      }
    else
      return value.to_s if primitive_json_value?(value)
      return opaque(value) unless value.is_a?(MIR::Emittable)

      dump_mir_node(value, path)
    end
  end

  private

  def dump_mir_node(node, path)
    oid = node.object_id
    if (existing = @seen[oid])
      existing["ref_count"] += 1
      existing["ref_paths"] << path if existing["ref_paths"].length < 20
      return { "kind" => "ref", "id" => existing["id"], "class" => existing["class"], "path" => path }
    end

    id = @nodes.length
    record = {
      "id" => id,
      "object_id" => oid,
      "class" => node.class.name,
      "short_class" => node.class.name.to_s.sub(/\AMIR::/, ""),
      "path" => path,
      "source_line" => source_line(node),
      "source_column" => source_column(node),
      "ref_count" => 1,
      "ref_paths" => [path],
      "fields" => {},
      "child_ids" => [],
    }
    @seen[oid] = record
    @nodes << record

    fields = node.respond_to?(:each_pair) ? node.each_pair.to_h : {}
    fields.each do |key, value|
      child_path = "#{path}.#{key}"
      dumped = dump(value, child_path)
      record["fields"][key.to_s] = dumped
      collect_child_ids(dumped, record["child_ids"])
    end

    {
      "kind" => "node",
      "id" => id,
      "class" => record["class"],
      "path" => path,
    }
  end

  def collect_child_ids(value, out)
    case value
    when Hash
      if value["kind"] == "node" || value["kind"] == "ref"
        out << value["id"]
      elsif value["kind"] == "array"
        value["items"].each { |item| collect_child_ids(item, out) }
      elsif value["kind"] == "hash"
        value["entries"].each { |entry| collect_child_ids(entry["value"], out) }
      else
        value.each_value { |item| collect_child_ids(item, out) }
      end
    when Array
      value.each { |item| collect_child_ids(item, out) }
    end
  end

  def source_line(node)
    node.respond_to?(:source_line) ? node.source_line : nil
  rescue StandardError
    nil
  end

  def source_column(node)
    node.respond_to?(:source_column) ? node.source_column : nil
  rescue StandardError
    nil
  end

  def opaque(value)
    if value.respond_to?(:name)
      { "kind" => "opaque", "class" => value.class.name, "name" => value.name.to_s }
    else
      text = value.inspect
      text = "#{text[0, 160]}..." if text.length > 160
      { "kind" => "opaque", "class" => value.class.name, "inspect" => text }
    end
  end
end

times = {}
importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
frontend = nil
times["frontend"] = Benchmark.realtime do
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

mir_root = nil
times["lower"] = Benchmark.realtime do
  mir_root =
    if options[:module_mode]
      lowering.lower_module(frontend.ast)
    else
      lowering.lower_program(frontend.ast)
    end
end

dumper = MirTreeDumper.new
tree = dumper.dump(mir_root)

doc = {
  "schema" => "cheat.mir-tree.v1",
  "source_path" => source_path,
  "mode" => options[:module_mode] ? "module" : "program",
  "times_seconds" => times,
  "node_count" => dumper.nodes.length,
  "nodes" => dumper.nodes,
  "tree" => tree,
}

File.write(output_path, JSON.pretty_generate(doc))
puts output_path
warn format("dumped %d MIR nodes in %.3fs frontend + %.3fs lower", dumper.nodes.length, times["frontend"], times["lower"])
