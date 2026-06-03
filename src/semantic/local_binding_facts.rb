# typed: strict
require "sorbet-runtime"

require_relative "../ast/ast"
require_relative "../mir/cleanup_entry"

module MIR
  class LocalBindingFacts < T::Struct
    const :names, T::Set[String]
    const :entries, T::Hash[String, CleanupEntry]
    const :frame_decls, T::Array[AST::Node]
    const :iteration_frame_decls, T::Array[AST::Node]
  end

  module LocalBindingAnalysis
    extend T::Sig

    sig { params(body: T::Array[T.untyped]).returns(LocalBindingFacts) }
    def self.direct_loop_body_facts(body)
      names = T.let(::Set.new, T::Set[String])
      entries = T.let({}, T::Hash[String, CleanupEntry])
      frame_decls = T.let([], T::Array[AST::Node])
      iteration_frame_decls = T.let([], T::Array[AST::Node])

      each_direct_loop_node(body) do |node|
        name = binding_decl_name(node)
        next unless name

        names << name
        entry = binding_entry(node)
        entries[name] = entry if entry&.present?
        next unless binding_frame_allocates?(node, entry)

        frame_decls << node
        iteration_frame_decls << node if entry&.present? && entry.scope == :iteration
      end

      LocalBindingFacts.new(
        names: names,
        entries: entries,
        frame_decls: frame_decls,
        iteration_frame_decls: iteration_frame_decls,
      )
    end

    sig { params(body: T::Array[T.untyped], block: T.proc.params(arg0: AST::Node).void).void }
    def self.each_direct_loop_node(body, &block)
      raise TypeError, "body must be an Array" unless body.is_a?(Array)

      body.each do |node|
        next unless node.is_a?(AST::Locatable)
        yield node
        case node
        when AST::WhileLoop, AST::WhileBindLoop, AST::ForRange, AST::ForEach, AST::FunctionDef, AST::LambdaLit
          next
        when AST::IfStatement
          each_direct_loop_node(node.then_branch, &block)
          each_direct_loop_node(node.else_branch, &block)
        when AST::MatchStatement
          node.cases.each { |c| each_direct_loop_node(c.body, &block) }
          each_direct_loop_node(node.default_case, &block) if node.default_case
        when AST::WithBlock
          each_direct_loop_node(node.body, &block)
        when AST::DoBlock
          node.branches.each do |branch|
            each_direct_loop_node(T.cast(branch.fetch(:body), T::Array[T.untyped]), &block)
          end
        end
      end
      nil
    end

    sig { params(node: AST::Node).returns(T.nilable(String)) }
    def self.binding_decl_name(node)
      case node
      when AST::VarDecl
        node.name.is_a?(String) ? node.name : nil
      when AST::BindExpr
        node.mode == :decl && node.name.is_a?(String) ? node.name : nil
      else
        nil
      end
    end

    sig { params(node: AST::Node).returns(T.nilable(CleanupEntry)) }
    def self.binding_entry(node)
      case node
      when AST::VarDecl, AST::BindExpr
        T.unsafe(node).mir_binding_entry
      else
        nil
      end
    end

    sig { params(node: AST::Node, entry: T.nilable(CleanupEntry)).returns(T::Boolean) }
    def self.binding_frame_allocates?(node, entry)
      return false unless entry&.present? && entry.alloc == :frame
      return true if entry.needs_cleanup?
      return false unless node.is_a?(AST::VarDecl) || node.is_a?(AST::BindExpr)

      value = node.value
      return false if value.nil?
      return false if value.is_a?(AST::Literal) || value.is_a?(AST::Identifier)

      true
    end

  end
end
