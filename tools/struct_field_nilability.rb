#!/usr/bin/env ruby
# For each Struct.new(:a, :b, ...) AST/MIR/Schemas class, scan every
# `ClassName.new(...)` construction site in src/ and report whether
# any positional argument is `nil` (literal). Fields proven non-nil
# can be added to TYPE_POLICY in tools/gen_struct_fields_rbi.rb.
#
# Output: TSV — class\tfield_index\tfield_name\tnil_count\tnonnil_count\tverdict

require 'prism'

# Step 1: discover all Struct.new declarations in the AST/schemas sources.
SOURCES = %w[src/ast/ast.rb src/ast/schemas.rb].freeze

# class_path => [field_name, ...] in positional order
class_fields = {}

walk = nil
walk = lambda do |node, scope|
  return unless node
  case node
  when Prism::ModuleNode, Prism::ClassNode
    name = node.constant_path.is_a?(Prism::ConstantReadNode) ? node.constant_path.name : node.constant_path.full_name
    walk.(node.body, scope + [name.to_s])
    return
  when Prism::ConstantWriteNode
    if node.value.is_a?(Prism::CallNode) &&
       node.value.name == :new &&
       node.value.receiver.is_a?(Prism::ConstantReadNode) &&
       node.value.receiver.name == :Struct
      cls = (scope + [node.name.to_s]).join('::')
      args = node.value.arguments&.arguments || []
      fields = args.filter_map { |a| a.value.to_sym if a.is_a?(Prism::SymbolNode) }
      class_fields[cls] = fields if fields.any?
    end
  when Prism::DefNode
    return
  end
  if node.respond_to?(:child_nodes)
    node.child_nodes.compact.each { |c| walk.(c, scope) }
  end
end

SOURCES.each do |f|
  parsed = Prism.parse_file(f)
  next unless parsed.success?
  walk.(parsed.value, [])
end

# Build [field_index, field_name] => Hash counters per class.
# nil_count / nonnil_count tracked per (class, position).
counters = {}
class_fields.each do |cls, fields|
  fields.each_with_index do |fname, idx|
    counters[[cls, idx, fname]] = { nil: 0, nonnil: 0, sites: [] }
  end
end

# Step 2: scan every Ruby file in src/ for `ClassName.new(...)` calls.
# Match the constant-path against the discovered class names.
# Build a quick lookup: short class name (last segment) => full class path.
short_to_full = {}
class_fields.each_key do |cls|
  short = cls.split('::').last
  short_to_full[short] ||= []
  short_to_full[short] << cls
end

scan_walk = nil
scan_walk = lambda do |node, file|
  return unless node
  if node.is_a?(Prism::CallNode) && node.name == :new
    recv = node.receiver
    # Build the receiver's textual constant path (e.g. "AST::FuncCall")
    recv_path = const_path_text(recv)
    if recv_path
      short = recv_path.split('::').last
      candidates = (short_to_full[short] || []).select do |full|
        full == recv_path || full.end_with?("::" + recv_path)
      end
      if candidates.size == 1
        cls = candidates.first
        fields = class_fields[cls]
        positional_args = (node.arguments&.arguments || []).reject do |a|
          a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::SplatNode) ||
            a.is_a?(Prism::BlockArgumentNode) || a.is_a?(Prism::AssocNode)
        end
        positional_args.each_with_index do |arg, idx|
          break if idx >= fields.size
          key = [cls, idx, fields[idx]]
          if arg.is_a?(Prism::NilNode)
            counters[key][:nil] += 1
            counters[key][:sites] << "#{file}:#{node.location.start_line}"
          else
            counters[key][:nonnil] += 1
          end
        end
      end
    end
  end
  if node.respond_to?(:child_nodes)
    node.child_nodes.compact.each { |c| scan_walk.(c, file) }
  end
end

def const_path_text(node)
  case node
  when Prism::ConstantReadNode then node.name.to_s
  when Prism::ConstantPathNode
    parent = const_path_text(node.parent) if node.parent
    parent ? "#{parent}::#{node.name}" : node.name.to_s
  else nil
  end
end

Dir.glob('src/**/*.rb').each do |f|
  parsed = Prism.parse_file(f)
  next unless parsed.success?
  scan_walk.(parsed.value, f)
end

# Step 3: report.
# Verdict: NON_NIL if 0 nil and ≥1 nonnil. NILABLE if any nil seen.
# UNTESTED if no construction sites observed.
puts "class\tidx\tfield\tnil\tnonnil\tverdict"
counters.sort_by { |(cls, idx, _f), _c| [cls, idx] }.each do |(cls, idx, fname), c|
  verdict = if c[:nil] == 0 && c[:nonnil] > 0 then "NON_NIL"
            elsif c[:nil] > 0 then "NILABLE"
            else "UNTESTED"
            end
  puts "#{cls}\t#{idx}\t#{fname}\t#{c[:nil]}\t#{c[:nonnil]}\t#{verdict}"
end
