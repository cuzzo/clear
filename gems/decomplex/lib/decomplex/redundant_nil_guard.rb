# frozen_string_literal: true

require "set"
require_relative "ast"

module Decomplex
  # Redundant nil-guard detector. Finds local-variable nil checks or
  # safe-navigation performed after the same local is already proven
  # non-nil on the current intra-method path.
  #
  # Conservative by design: local variables only, no loop reasoning, no
  # interprocedural facts. Reassignment invalidates the proof.
  class RedundantNilGuard
    Finding = Struct.new(:file, :defn, :line, :span, :local, :guard,
                         :proof, keyword_init: true) do
      def to_h
        loc = "#{file}:#{defn}:#{line}"
        super.merge(at: loc, spans: { loc => span })
      end
    end
    Flow = Struct.new(:known, :terminated, keyword_init: true)
    NilFact = Struct.new(:local, :non_nil_when_true, keyword_init: true)

    TERMINATING_CALLS = %i[raise fail abort exit exit!].freeze

    def self.scan(files)
      files.flat_map do |file|
        root, lines = Ast.parse(file)
        new(file, lines).tap { |scanner| scanner.walk(root, []) }.findings
      end.sort_by { |f| [f.file, f.line, f.local, f.guard] }.map(&:to_h)
    end

    attr_reader :findings

    def initialize(file, lines)
      @file = file
      @lines = lines
      @findings = []
    end

    def walk(node, defstack)
      return unless Ast.node?(node)

      if %i[DEFN DEFS].include?(node.type)
        name = node.children[node.type == :DEFS ? 1 : 0].to_s
        process_block(Ast.body_stmts(node), defstack + [name], Set.new)
        return
      end

      node.children.each { |child| walk(child, defstack) }
    end

    private

    def process_block(stmts, defstack, known)
      current = known.dup
      stmts.each do |stmt|
        flow = process_stmt(stmt, defstack, current)
        current = flow.known
        return flow if flow.terminated
      end
      Flow.new(known: current, terminated: false)
    end

    def process_stmt(node, defstack, known)
      return Flow.new(known: known.dup, terminated: false) unless Ast.node?(node)

      case node.type
      when :IF, :UNLESS
        process_branch(node, defstack, known)
      when :LASGN
        inspect_node(node.children[1], defstack, known)
        next_known = known.dup
        next_known.delete(node.children[0].to_s)
        Flow.new(known: next_known, terminated: false)
      else
        inspect_node(node, defstack, known)
        Flow.new(known: known.dup, terminated: terminating?(node))
      end
    end

    def process_branch(node, defstack, known)
      cond, then_body, else_body = node.children
      inspect_node(cond, defstack, known)

      then_known = known_for_branch(node.type, true, cond, known)
      else_known = known_for_branch(node.type, false, cond, known)
      then_flow = process_block(stmts_for(then_body), defstack, then_known)
      else_flow = process_block(stmts_for(else_body), defstack, else_known)

      if then_flow.terminated && else_flow.terminated
        Flow.new(known: Set.new, terminated: true)
      elsif then_flow.terminated
        Flow.new(known: else_flow.known, terminated: false)
      elsif else_flow.terminated
        Flow.new(known: then_flow.known, terminated: false)
      else
        Flow.new(known: then_flow.known & else_flow.known, terminated: false)
      end
    end

    def known_for_branch(node_type, body_branch, cond, known)
      next_known = known.dup
      fact = nil_fact(cond)
      return next_known unless fact

      cond_true_branch =
        if node_type == :IF
          body_branch
        else
          !body_branch
        end
      proves_non_nil = cond_true_branch == fact.non_nil_when_true
      next_known.add(fact.local) if proves_non_nil
      next_known
    end

    def inspect_node(node, defstack, known)
      return unless Ast.node?(node)

      recorded = record_redundant(node, defstack, known)
      return if %i[DEFN DEFS].include?(node.type)
      return if recorded && node.type == :OPCALL

      node.children.each { |child| inspect_node(child, defstack, known) }
    end

    def record_redundant(node, defstack, known)
      local = redundant_nil_subject(node, known)
      return false unless local

      @findings << Finding.new(
        file: @file,
        defn: defstack.last || "(top-level)",
        line: node.first_lineno,
        span: span(node),
        local: local,
        guard: Ast.slice(node, @lines),
        proof: "#{local} is already proven non-nil on this path"
      )
      true
    end

    def redundant_nil_subject(node, known)
      return qcall_local(node, known) if node.type == :QCALL

      fact = nil_fact(node)
      return nil unless fact && known.include?(fact.local)

      fact.local
    end

    def nil_fact(node)
      return nil unless Ast.node?(node)

      case node.type
      when :CALL
        recv, mid, args = node.children
        return nil unless mid == :nil? && args.nil?

        local = local_name(recv)
        local ? NilFact.new(local: local, non_nil_when_true: false) : nil
      when :OPCALL
        recv, mid, args = node.children
        return negated_nil_fact(recv) if mid == :!
        return comparison_nil_fact(recv, mid, args) if %i[== !=].include?(mid)

        nil
      else
        nil
      end
    end

    def negated_nil_fact(node)
      fact = nil_fact(node)
      return nil unless fact

      NilFact.new(local: fact.local,
                  non_nil_when_true: !fact.non_nil_when_true)
    end

    def comparison_nil_fact(recv, mid, args)
      local = local_name(recv)
      return nil unless local && nil_arg?(args)

      NilFact.new(local: local, non_nil_when_true: mid == :!=)
    end

    def qcall_local(node, known)
      recv = node.children[0]
      local = local_name(recv)
      local if local && known.include?(local)
    end

    def local_name(node)
      return nil unless Ast.node?(node) && %i[LVAR DVAR].include?(node.type)

      node.children[0].to_s
    end

    def nil_arg?(args)
      return false unless Ast.node?(args)

      args.children.any? { |child| Ast.node?(child) && child.type == :NIL }
    end

    def stmts_for(node)
      return [] unless Ast.node?(node)

      node.type == :BLOCK ? node.children.compact : [node]
    end

    def terminating?(node)
      return false unless Ast.node?(node)
      return true if node.type == :RETURN
      return false unless %i[FCALL VCALL CALL].include?(node.type)

      mid = if node.type == :CALL
              node.children[1]
            else
              node.children[0]
            end
      TERMINATING_CALLS.include?(mid)
    end

    def span(node)
      [node.first_lineno, node.first_column, node.last_lineno, node.last_column]
    end
  end
end
