#!/usr/bin/env ruby
require 'prism'

# ivar_types[class_path][attr_name] = type_string extracted from T.let in initialize
ivar_types = Hash.new { |h, k| h[k] = {} }
declared = Hash.new { |h, k| h[k] = [] }

# Collect @attr = T.let(_, Type) bindings from an initialize body
collect_ivar_types = lambda do |def_node, class_path|
  return unless def_node.is_a?(Prism::DefNode) && def_node.name == :initialize
  body = def_node.body
  stmts = case body
  when Prism::StatementsNode then body.body
  when Prism::BeginNode      then body.statements&.body || []
  else []
  end
  stmts.each do |stmt|
    next unless stmt.is_a?(Prism::InstanceVariableWriteNode)
    val = stmt.value
    next unless val.is_a?(Prism::CallNode) && val.name == :let
    recv = val.receiver
    next unless recv.is_a?(Prism::ConstantReadNode) && recv.name == :T
    args = val.arguments&.arguments
    next unless args && args.size >= 2
    ivar_name = stmt.name.to_s.delete_prefix('@')
    ivar_types[class_path][ivar_name] = args[1].location.slice
  end
end

walk_block_for_attrs = lambda do |block_node, class_path|
  return unless block_node
  return unless block_node.body.is_a?(Prism::StatementsNode)
  block_node.body.body.each do |stmt|
    next unless stmt.is_a?(Prism::CallNode)
    next unless [:attr_accessor, :attr_reader, :attr_writer].include?(stmt.name)
    kind = stmt.name
    names = (stmt.arguments&.arguments || []).filter_map do |a|
      if a.is_a?(Prism::SymbolNode); a.value
      elsif a.is_a?(Prism::StringNode); a.content
      else nil
      end
    end
    names.each { |n| declared[class_path] << [kind, n] }
  end
end

walk = nil
walk = lambda do |node, scope|
  return unless node
  case node
  when Prism::ModuleNode, Prism::ClassNode
    name = node.constant_path.is_a?(Prism::ConstantReadNode) ? node.constant_path.name : node.constant_path.full_name
    walk.(node.body, scope + [name.to_s])
  when Prism::ConstantWriteNode
    if node.value.is_a?(Prism::CallNode) &&
       node.value.name == :new &&
       node.value.receiver.is_a?(Prism::ConstantReadNode) &&
       node.value.receiver.name == :Struct
      class_path = (scope + [node.name.to_s]).join('::')
      walk_block_for_attrs.(node.value.block, class_path) if node.value.block
    end
  when Prism::DefNode
    return
  end
  if node.respond_to?(:child_nodes)
    node.child_nodes.compact.each { |c| walk.(c, scope) }
  end
end

class_walk = nil
class_walk = lambda do |node, scope|
  return unless node
  case node
  when Prism::ClassNode
    name = node.constant_path.is_a?(Prism::ConstantReadNode) ? node.constant_path.name : node.constant_path.full_name
    new_scope = scope + [name.to_s]
    class_path = new_scope.join('::')
    if node.body.is_a?(Prism::StatementsNode)
      node.body.body.each do |stmt|
        if stmt.is_a?(Prism::CallNode) && [:attr_accessor, :attr_reader, :attr_writer].include?(stmt.name)
          kind = stmt.name
          names = (stmt.arguments&.arguments || []).filter_map do |a|
            if a.is_a?(Prism::SymbolNode); a.value
            elsif a.is_a?(Prism::StringNode); a.content
            else nil
            end
          end
          names.each { |n| declared[class_path] << [kind, n] }
        elsif stmt.is_a?(Prism::DefNode)
          collect_ivar_types.(stmt, class_path)
        end
      end
    end
    class_walk.(node.body, new_scope)
  when Prism::ModuleNode
    name = node.constant_path.is_a?(Prism::ConstantReadNode) ? node.constant_path.name : node.constant_path.full_name
    class_walk.(node.body, scope + [name.to_s])
  end
  if node.respond_to?(:child_nodes)
    node.child_nodes.compact.each { |c| class_walk.(c, scope) }
  end
end

Dir.glob('src/**/*.rb').sort.each do |f|
  parsed = Prism.parse_file(f)
  next unless parsed.success?
  walk.(parsed.value, [])
  class_walk.(parsed.value, [])
end

# Preserve typed sigs from the existing RBI for attrs whose T.let has been
# stripped. When a T.let is removed from source, ivar_types loses the type,
# but the checked-in RBI still has it. We use the existing RBI as a fallback
# so re-running the generator is idempotent after stripping.
rbi_preserved = Hash.new { |h, k| h[k] = {} }
rbi_path = File.join(File.dirname(__dir__), "sorbet", "rbi", "clear-attr-accessors.rbi")
if File.exist?(rbi_path)
  current_class = nil
  pending_return = nil
  File.readlines(rbi_path).each do |line|
    if line =~ /^class (\S+)/
      current_class = $1
      pending_return = nil
    elsif current_class && line =~ /sig \{ returns\((.+?)\) \}/
      pending_return = $1 unless $1 == "T.untyped"
    elsif current_class && pending_return && line =~ /\s+def (\w+); end/
      rbi_preserved[current_class][$1] = pending_return
      pending_return = nil
    else
      pending_return = nil unless line.strip.empty?
    end
  end
end

total = declared.values.map(&:uniq).map(&:size).sum
typed_count = ivar_types.values.sum(&:size)
preserved_count = rbi_preserved.values.sum(&:size)
warn "RBI generation: #{declared.size} classes, #{total} attr_* (uniq), #{typed_count} typed ivar matches, #{preserved_count} preserved from existing RBI"

normalize_type = lambda do |_class_path, type_str|
  type_str
end

puts <<~HDR
  # typed: true
  # frozen_string_literal: true
  #
  # AUTO-GENERATED. Do not edit by hand. Regenerate with:
  #   bundle exec ruby tools/gen_attr_rbi.rb > sorbet/rbi/clear-attr-accessors.rbi
  #
  # Sorbet's automatic Struct.new typing only surfaces the positional
  # Struct fields, not `attr_accessor`/`attr_reader`/`attr_writer`
  # declarations inside the do-block. Without this shim, every file
  # that flips to `# typed: true` and reads such an attribute trips a
  # `Method does not exist` error.
  #
  # Where a matching T.let declaration exists in initialize, the sig is
  # typed. Otherwise it falls back to T.untyped.

HDR

declared.keys.sort.each do |cls|
  attrs = declared[cls].uniq.sort_by { |kind, n| [n.to_s, kind.to_s] }
  next if attrs.empty?
  puts "class #{cls}"
  attrs.each do |kind, name|
    type_str = normalize_type.call(cls, ivar_types.dig(cls, name.to_s) || rbi_preserved.dig(cls, name.to_s) || "T.untyped")
    if kind == :attr_reader || kind == :attr_accessor
      puts "  sig { returns(#{type_str}) }"
      puts "  def #{name}; end"
    end
    if kind == :attr_writer || kind == :attr_accessor
      puts "  sig { params(value: #{type_str}).returns(#{type_str}) }"
      puts "  def #{name}=(value); end"
    end
  end
  puts "end"
  puts
end
