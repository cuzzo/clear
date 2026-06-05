# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # TemporalOrderingPressure -- classes/modules whose public method
  # surface exposes a mutable lifecycle. If several public methods read
  # or write the same instance state, callers can invoke those methods
  # in many orders and create an implicit state machine.
  class TemporalOrderingPressure
    MethodState = Struct.new(:name, :line, :span, :visibility, :reads, :writes,
                             keyword_init: true)

    def self.scan(files)
      rows = []
      files.each do |file|
        root, lines = Ast.parse(file)
        rows.concat(new(file, lines).scan(root))
      end
      rows.sort_by { |h| [-h[:score], -h[:state_methods], h[:file], h[:owner]] }
    end

    def initialize(file, lines)
      @file = file
      @lines = lines
    end

    def scan(root)
      out = []
      walk_owners(root, [], out)
      out
    end

    def walk_owners(node, owners, out)
      return unless Ast.node?(node)

      if %i[CLASS MODULE].include?(node.type)
        owner = owner_name(node)
        methods = owner_methods(node)
        row = pressure_row(owner, methods)
        out << row if row
        node.children.each { |child| walk_owners(child, owners + [owner], out) }
      else
        node.children.each { |child| walk_owners(child, owners, out) }
      end
    end

    def owner_name(node)
      Ast.slice(node.children[0], @lines).to_s.empty? ? "(anonymous)" : Ast.slice(node.children[0], @lines)
    end

    def owner_methods(owner_node)
      body = owner_body(owner_node)
      return [] unless Ast.node?(body)

      stmts = body.type == :BLOCK ? body.children.compact : [body]
      visibility = :public
      methods = []
      stmts.each do |stmt|
        next unless Ast.node?(stmt)

        if visibility_marker?(stmt)
          visibility = stmt.children[0].to_sym
        elsif %i[DEFN DEFS].include?(stmt.type)
          methods << method_state(stmt, visibility)
        end
      end
      methods
    end

    def owner_body(owner_node)
      scope = owner_node.children[2]
      return nil unless Ast.node?(scope) && scope.type == :SCOPE

      scope.children[2]
    end

    def visibility_marker?(node)
      node.type == :VCALL && %i[public protected private].include?(node.children[0])
    end

    def method_state(defn_node, visibility)
      reads = []
      writes = []
      collect_state_access(defn_node, reads, writes)
      MethodState.new(
        name: defn_node.children[defn_node.type == :DEFS ? 1 : 0].to_s,
        line: defn_node.first_lineno,
        span: [defn_node.first_lineno, defn_node.first_column,
               defn_node.last_lineno, defn_node.last_column],
        visibility: visibility,
        reads: reads.uniq.sort,
        writes: writes.uniq.sort
      )
    end

    def collect_state_access(node, reads, writes)
      return unless Ast.node?(node)

      case node.type
      when :IASGN
        writes << node.children[0].to_s
      when :IVAR
        reads << node.children[0].to_s
      end
      node.children.each { |child| collect_state_access(child, reads, writes) }
    end

    def pressure_row(owner, methods)
      public_methods = methods.select { |m| m.visibility == :public }
      state_methods = public_methods.select { |m| !(m.reads + m.writes).empty? }
      writers = public_methods.select { |m| !m.writes.empty? }
      return nil if state_methods.size < 3 || writers.size < 2

      fields = state_methods.flat_map { |m| m.reads + m.writes }.uniq.sort
      shared_fields = fields.select do |field|
        state_methods.count { |m| (m.reads + m.writes).include?(field) } >= 2
      end
      return nil if shared_fields.empty?

      n = state_methods.size
      state_space = 2**[fields.size, 12].min
      score = (n * writers.size * [shared_fields.size, 1].max) + state_space
      {
        at: "#{@file}:#{owner}:#{state_methods.first.line}",
        file: @file,
        owner: owner,
        public_methods: public_methods.size,
        state_methods: n,
        writers: writers.size,
        state_fields: fields,
        shared_fields: shared_fields,
        orderings: factorial_label(n),
        state_space: "2^#{fields.size}",
        score: score,
        sites: state_methods.map { |m| "#{@file}:#{m.name}:#{m.line}" },
        spans: state_methods.to_h { |m| ["#{@file}:#{m.name}:#{m.line}", m.span] }
      }
    end

    def factorial_label(n)
      "#{n}!"
    end
  end
end
