#!/usr/bin/env ruby
require 'prism'

declared = Hash.new { |h, k| h[k] = [] }

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

# Also catch attr_accessor at class scope (not inside Struct.new).
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

total = declared.values.map(&:uniq).map(&:size).sum
warn "RBI generation: #{declared.size} classes, #{total} attr_* (uniq) across src/"

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
  # `Method does not exist` error. This file declares T.untyped sigs
  # so the per-file typing rollout can proceed.
  #
  # As the Self-host preparation tracker (TODO.md) advances, individual
  # T.untyped sigs are tightened to real types (Symbol for identifiers
  # per task #1, etc.). When all attrs are typed, this shim can be
  # deleted and replaced by inline T::Sig declarations on the classes
  # themselves.

HDR

declared.keys.sort.each do |cls|
  attrs = declared[cls].uniq.sort_by { |kind, n| [n.to_s, kind.to_s] }
  next if attrs.empty?
  puts "class #{cls}"
  attrs.each do |kind, name|
    if kind == :attr_reader || kind == :attr_accessor
      puts "  sig { returns(T.untyped) }"
      puts "  def #{name}; end"
    end
    if kind == :attr_writer || kind == :attr_accessor
      puts "  sig { params(value: T.untyped).returns(T.untyped) }"
      puts "  def #{name}=(value); end"
    end
  end
  puts "end"
  puts
end
