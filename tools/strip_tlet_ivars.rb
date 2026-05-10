#!/usr/bin/env ruby
# frozen_string_literal: true
#
# B2: Remove T.let wrappers from accessor-backed ivars in initialize bodies.
# The accessor sig in sorbet/rbi/clear-attr-accessors.rbi provides the type;
# Sorbet infers the ivar type from it. Run after regenerating the RBI.
#
# Usage:
#   bundle exec ruby tools/strip_tlet_ivars.rb [--dry-run]
#
# Prints each stripped site. With --dry-run, reports without writing files.

require 'prism'

dry_run = ARGV.include?("--dry-run")

# ---- Step 1: collect declared accessor names per class ----
# declared[class_path] = [ivar_name, ...]
declared = Hash.new { |h, k| h[k] = [] }

walk_declared = nil
walk_declared = lambda do |node, scope|
  return unless node
  case node
  when Prism::ClassNode
    name = node.constant_path.is_a?(Prism::ConstantReadNode) ? node.constant_path.name.to_s : node.constant_path.full_name.to_s
    new_scope = scope + [name]
    class_path = new_scope.join("::")
    if node.body.is_a?(Prism::StatementsNode)
      node.body.body.each do |stmt|
        next unless stmt.is_a?(Prism::CallNode) && [:attr_accessor, :attr_reader].include?(stmt.name)
        (stmt.arguments&.arguments || []).each do |a|
          declared[class_path] << a.value.to_s if a.is_a?(Prism::SymbolNode)
        end
      end
    end
    walk_declared.(node.body, new_scope)
  when Prism::ModuleNode
    name = node.constant_path.is_a?(Prism::ConstantReadNode) ? node.constant_path.name.to_s : node.constant_path.full_name.to_s
    walk_declared.(node.body, scope + [name])
  else
    node.child_nodes.compact.each { |c| walk_declared.(c, scope) } if node.respond_to?(:child_nodes)
  end
end

Dir.glob("src/**/*.rb").sort.each do |f|
  r = Prism.parse_file(f)
  walk_declared.(r.value, []) if r.success?
end
declared.transform_values!(&:uniq)

# ---- Step 2: per-file, collect T.let sites for accessor-backed ivars ----
# Returns [{tlet_node:, val_node:, ivar_name:}] for qualifying sites in def initialize.
collect_tlet_sites = lambda do |def_node, class_path|
  return [] unless def_node.is_a?(Prism::DefNode) && def_node.name == :initialize
  body = def_node.body
  stmts = case body
  when Prism::StatementsNode then body.body
  when Prism::BeginNode      then body.statements&.body || []
  else []
  end
  results = []
  stmts.each do |stmt|
    next unless stmt.is_a?(Prism::InstanceVariableWriteNode)
    val = stmt.value
    next unless val.is_a?(Prism::CallNode) && val.name == :let
    recv = val.receiver
    next unless recv.is_a?(Prism::ConstantReadNode) && recv.name == :T
    args = val.arguments&.arguments
    next unless args && args.size >= 2
    ivar_name = stmt.name.to_s.delete_prefix("@")
    next unless (declared[class_path] || []).include?(ivar_name)
    results << { tlet_node: val, val_node: args[0], ivar_name: ivar_name }
  end
  results
end

# file -> [{tlet_node:, val_node:, ivar_name:}]
strip_sites = Hash.new { |h, k| h[k] = [] }

walk_sites = nil
walk_sites = lambda do |node, scope, file|
  return unless node
  case node
  when Prism::ClassNode
    name = node.constant_path.is_a?(Prism::ConstantReadNode) ? node.constant_path.name.to_s : node.constant_path.full_name.to_s
    new_scope = scope + [name]
    class_path = new_scope.join("::")
    if node.body.is_a?(Prism::StatementsNode)
      node.body.body.each do |stmt|
        strip_sites[file].concat(collect_tlet_sites.(stmt, class_path)) if stmt.is_a?(Prism::DefNode)
      end
    end
    walk_sites.(node.body, new_scope, file)
  when Prism::ModuleNode
    name = node.constant_path.is_a?(Prism::ConstantReadNode) ? node.constant_path.name.to_s : node.constant_path.full_name.to_s
    walk_sites.(node.body, scope + [name], file)
  else
    node.child_nodes.compact.each { |c| walk_sites.(c, scope, file) } if node.respond_to?(:child_nodes)
  end
end

Dir.glob("src/**/*.rb").sort.each do |f|
  r = Prism.parse_file(f)
  walk_sites.(r.value, [], f) if r.success?
end
strip_sites.delete_if { |_, v| v.empty? }

total = strip_sites.values.sum(&:size)
puts "#{dry_run ? "[dry-run] " : ""}Stripping #{total} T.let site(s) across #{strip_sites.size} file(s)"

# ---- Step 3: apply replacements (end-to-start to preserve offsets) ----
strip_sites.each do |file, sites|
  # Prism offsets are byte offsets. Read as binary so String#[] operations
  # treat indices as byte positions (not character positions). Write back as
  # binary to preserve the original encoding without interpretation.
  source = File.binread(file)

  # Process in reverse offset order so earlier offsets stay valid after each edit
  sites.sort_by! { |s| -s[:tlet_node].location.start_offset }

  sites.each do |s|
    tlet_loc = s[:tlet_node].location
    val_loc  = s[:val_node].location
    old_text = tlet_loc.slice
    new_text = val_loc.slice

    puts "  #{file}:#{tlet_loc.start_line}  @#{s[:ivar_name]} = #{old_text.inspect} -> #{new_text.inspect}"
    next if dry_run

    source[tlet_loc.start_offset, tlet_loc.length] = new_text.b
  end

  File.binwrite(file, source) unless dry_run
end
