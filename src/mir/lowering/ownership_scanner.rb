# typed: strict
require "sorbet-runtime"
require "set"

require_relative "../../ast/ast"
require_relative "../../ast/type"
require_relative "../cleanup_entry"
require_relative "../lowering/functions"
require_relative "../lowering/schema_registry"

class MIRLoweringOwnershipScanner < T::Struct
  extend T::Sig

  NameNormalizer = T.type_alias { T.proc.params(name: String).returns(String) }
  ScanRoot = T.type_alias { T.any(AST::Node, T::Array[AST::Node]) }

  const :schema_lookup, MIRLoweringSchemas::SchemaLookup
  const :bindings, MIRLoweringFunctions::CleanupBindingMap
  const :capture_map, T::Hash[String, String]
  const :rename_map, T::Hash[String, String]
  const :safe_name, NameNormalizer

  sig { params(stmt: AST::Node).returns(T::Array[String]) }
  def collect_bg_capture_transfer_roots(stmt)
    names = T.let([], T::Array[String])
    AST.each_bg_block_in_stmt(stmt) do |bg|
      body_names = T.let(Set.new, T::Set[String])
      AST.each_locatable(bg.body) do |node|
        body_names << node.name.to_s if node.is_a?(AST::Identifier)
      end
      (bg.capture_analysis&.move_mark_names || Set.new).each do |name|
        next unless body_names.include?(name.to_s)
        entry = bindings[name.to_s] || CleanupEntry::NONE
        names << name.to_s if entry.present?
      end
    end
    names.uniq
  end

  sig { params(node: AST::Node).returns(T::Array[String]) }
  def collect_explicit_move_roots(node)
    names = T.let([], T::Array[String])
    collect = T.let(->(root) do
      AST.each_locatable(root) do |child|
        next unless child.is_a?(AST::MoveNode)
        moved = moved_arg_root(child)
        names << moved if moved
      end
    end, T.proc.params(root: ScanRoot).void)
    collect.call(node)
    AST.each_bg_block_in_stmt(node) do |bg|
      collect.call(T.cast(bg.body, ScanRoot)) if bg.respond_to?(:body) && bg.body
    end
    names.uniq
  end

  sig { params(stmt: AST::Node).returns(T::Array[String]) }
  def collect_moved_arg_roots(stmt)
    names = T.let([], T::Array[String])
    if AST.declaration_with_identifier_value?(stmt)
      value = T.cast(T.unsafe(stmt).value, AST::Identifier)
      ti = Type.from_node!(value, context: "moved declaration root")
      entry = bindings[value.name.to_s] || CleanupEntry::NONE
      names << value.name.to_s if ownership_tracked_transfer_type?(ti) && entry.present?
    end
    walk_ast_for_moved_args(stmt) do |arg|
      next if arg_is_call_argument?(stmt, arg)
      ti = Type.from_node!(arg, context: "moved argument root")
      next unless ownership_tracked_transfer_type?(ti)
      root = moved_arg_root(arg)
      next unless root
      ident = AST.root_identifier(arg) rescue nil
      entry = bindings[root] || CleanupEntry::NONE
      next unless ident&.symbol&.heap_storage? || (entry.present? && entry.heap?)
      names << root
    end
    names.uniq
  end

  sig { params(node: AST::Node, blk: T.proc.params(arg0: AST::Node).void).void }
  def walk_ast_for_moved_args(node, &blk)
    yield node if node.is_a?(AST::Identifier) && AST.moved?(node)
    return if nested_ownership_scope?(node)

    AST.each_child_node(node) { |child| walk_ast_for_moved_args(child, &blk) }
  end

  sig { params(arg: AST::Node).returns(T.nilable(String)) }
  def moved_arg_root(arg)
    node = arg
    node = node.value if node.is_a?(AST::MoveNode)
    return node.name.to_s if node.is_a?(AST::Identifier)
    nil
  end

  sig { params(name: String).returns(String) }
  def transfer_binding_name(name)
    mapped = capture_map[name]
    return mapped.to_s if mapped

    safe = safe_name.call(name)
    rename_map.key?(safe) ? rename_map.fetch(safe) : safe
  end

  private

  sig { params(stmt: AST::Node, arg: AST::Node).returns(T::Boolean) }
  def arg_is_call_argument?(stmt, arg)
    return false unless AST.call?(stmt) && stmt.respond_to?(:args)
    T.unsafe(stmt).args.include?(arg)
  end

  sig { params(ti: Type).returns(T::Boolean) }
  def ownership_tracked_transfer_type?(ti)
    return false if ti.primitive? || ti.void? || ti.any? || ti.id_handle?

    ti.ownership_bearing?(schema_lookup)
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def nested_ownership_scope?(node)
    case node
    when AST::WithBlock, AST::DoBlock, AST::BgBlock, AST::BgStreamBlock,
         AST::FunctionDef, AST::LambdaLit
      true
    else
      false
    end
  end
end
