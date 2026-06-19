# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # TemporalOrderingPressure -- classes/modules whose public method
  # surface exposes a mutable lifecycle. If several public methods read
  # or write the same instance state, callers can invoke those methods
  # in many orders and create an implicit state machine.
  class TemporalOrderingPressure
    MethodState = Struct.new(:name, :line, :span, :visibility, :reads, :writes,
                             keyword_init: true)

    def self.scan(files)
      rows = files.flat_map do |file|
        document = Syntax.parse(file, parser: "tree_sitter")
        new(file, document).scan
      end
      rows.sort_by { |h| [-h[:score], -h[:state_methods], h[:file], h[:owner]] }
    end

    def initialize(file, document)
      @file = file
      @document = document
    end

    def scan
      temporal_owners.filter_map do |owner|
        row = pressure_row(owner, owner_methods(owner))
        row if row
      end
    end

    private

    def temporal_owners
      (@document.owner_defs.map(&:name) + @document.function_defs.map(&:owner)).compact.uniq
    end

    def owner_methods(owner)
      @document.function_defs.select { |function| function.owner == owner }.map do |function|
        MethodState.new(
          name: function.name,
          line: function.line,
          span: function.span,
          visibility: function.visibility || :public,
          reads: state_reads_for(function).uniq.sort,
          writes: state_writes_for(function).uniq.sort
        )
      end
    end

    def state_reads_for(function)
      @document.state_reads.select do |read|
        read.owner == function.owner && read.function == function.name
      end.map(&:field)
    end

    def state_writes_for(function)
      @document.state_writes.select do |write|
        write.owner == function.owner && write.function == function.name
      end.map(&:field)
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
