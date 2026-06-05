# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # StateBranchDensity -- branches whose predicate reads mutable or
  # object-owned state. This is the "state + control flow" surface:
  # branch decisions over ivars, globals, or receiver attributes.
  class StateBranchDensity
    BRANCH_TYPES = %i[IF UNLESS WHILE UNTIL].freeze
    NOISE_MIDS = %i[! != == === < <= > >= [] []= to_s inspect class].freeze
    Decision = Struct.new(:file, :defn, :line, :span, :predicate,
                          :state_refs, keyword_init: true)

    def self.scan(files)
      decisions = []
      files.each do |file|
        root, lines = Ast.parse(file)
        scanner = new(file, lines)
        scanner.walk(root, [])
        decisions.concat(scanner.decisions)
      end
      Report.new(decisions)
    end

    attr_reader :decisions

    def initialize(file, lines)
      @file = file
      @lines = lines
      @decisions = []
      @totals = Hash.new(0)
    end

    def walk(node, defstack)
      return unless Ast.node?(node)

      defstack = Ast.def_push(node, defstack)
      record_branch(node, defstack)
      node.children.each { |child| walk(child, defstack) }
    end

    def record_branch(node, defstack)
      cond =
        case node.type
        when *BRANCH_TYPES
          node.children[0]
        when :CASE
          node.children[0]
        else
          nil
        end
      return unless Ast.node?(cond)

      defn = defstack.last || "(top-level)"
      @totals[[@file, defn]] += 1
      refs = state_refs(cond)
      return if refs.empty?

      @decisions << Decision.new(
        file: @file,
        defn: defn,
        line: node.first_lineno,
        span: [node.first_lineno, node.first_column,
               node.last_lineno, node.last_column],
        predicate: Ast.slice(cond, @lines),
        state_refs: refs.uniq.sort
      )
    end

    def state_refs(node)
      refs = []
      collect_state_refs(node, refs)
      refs
    end

    def collect_state_refs(node, refs)
      return unless Ast.node?(node)

      case node.type
      when :IVAR
        refs << node.children[0].to_s
      when :GVAR
        refs << node.children[0].to_s
      when :CALL, :QCALL, :OPCALL
        recv, mid, args = node.children
        if state_attr_read?(recv, mid, args)
          refs << "#{Ast.slice(recv, @lines)}.#{mid}"
        end
      end
      node.children.each { |child| collect_state_refs(child, refs) }
    end

    def state_attr_read?(recv, mid, args)
      return false unless recv
      return false if NOISE_MIDS.include?(mid)
      return false unless args.nil? || empty_arg_list?(args)

      # `user.admin?`, `user.name`, `@cart.empty?`, `config.enabled`
      # are state-derived decisions. `a == 0` has no no-arg receiver
      # read and is deliberately not counted.
      true
    end

    def empty_arg_list?(args)
      Ast.node?(args) && args.type == :LIST && args.children.compact.empty?
    end

    class Report
      def initialize(decisions)
        @decisions = decisions
      end

      def findings
        @decisions.group_by { |d| [d.file, d.defn] }.map do |(file, defn), ds|
          refs = ds.flat_map(&:state_refs).uniq.sort
          {
            at: "#{file}:#{defn}:#{ds.first.line}",
            file: file,
            method: defn,
            decisions: ds.size,
            state_refs: refs,
            predicate: ds.first.predicate,
            score: ds.size * [refs.size, 1].max,
            sites: ds.map { |d| "#{d.file}:#{d.defn}:#{d.line}" },
            spans: ds.to_h { |d| ["#{d.file}:#{d.defn}:#{d.line}", d.span] }
          }
        end.sort_by { |h| [-h[:score], -h[:decisions], h[:file], h[:method]] }
      end
    end
  end
end
