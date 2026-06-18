# frozen_string_literal: true

require_relative "ast"
require_relative "state_mesh"

module Decomplex
  # MutabilityPressure -- rank fields by how many methods participate in
  # writing them, and classify each field by lifecycle pattern.
  #
  # Post-analyzer over StateMesh. No new AST walks.
  #
  # Classifications:
  #   immutable_convention -- written once in initialize, never mutated.
  #       Also catches memos (same-method write+read with read-first pattern).
  #   pass_through          -- written and read in a SINGLE method body.
  #   shadow_state          -- always written in strict subset of another
  #       field's write methods. Zero operational autonomy. Coupled state.
  #   one_way_state         -- written in >=2 methods, read in <=1.
  #   mutable_entity        -- written in >=2 methods, read in >=2.
  #   dead_state            -- written but never read.
  class MutabilityPressure
    Finding = Struct.new(:field, :classification, :write_spread,
                         :read_spread, :total_writes, :total_reads,
                         :write_sites, :read_sites, :shadowed_by,
                         keyword_init: true) do
      def to_h
        h = {
          field: field,
          classification: classification,
          write_spread: write_spread,
          read_spread: read_spread,
          total_writes: total_writes,
          total_reads: total_reads,
          write_sites: write_sites,
          read_sites: read_sites
        }
        h[:shadowed_by] = shadowed_by if shadowed_by
        h
      end
    end

    def self.scan(files)
      sm = StateMesh.scan(files, min_writes: 1)
      sm.run
      new(sm).scan
    end

    def initialize(state_mesh)
      @sm = state_mesh
    end

    def scan
      group_by_field
      classify_and_rank
    end

    private

    def group_by_field
      @writes_by = Hash.new { |h, k| h[k] = [] }
      @reads_by  = Hash.new { |h, k| h[k] = [] }

      @sm.writes.each do |w|
        next unless w.recv == "self"
        @writes_by[w.norm] << w
      end
      @sm.reads.each do |r|
        next unless r.recv == "self"
        @reads_by[r.norm] << r
      end
    end

    def classify_and_rank
      results = []
      all_norms = (@writes_by.keys + @reads_by.keys).uniq

      # Build write-method signatures: field -> Set of (file, defn)
      field_write_sigs = {}
      all_norms.each do |norm|
        ws = @writes_by[norm] || []
        field_write_sigs[norm] = ws.map { |w| [w.file, w.defn] }.uniq.sort
      end

      # Shadow detection: field Y always written in strict subset of X's methods
      field_shadows = Hash.new { |h, k| h[k] = [] }
      field_write_sigs.each do |y_norm, y_methods|
        next if y_methods.size <= 1
        field_write_sigs.each do |x_norm, x_methods|
          next if x_norm == y_norm
          next if x_methods.size <= y_methods.size
          next if x_methods.size < 2
          next unless y_methods.all? { |ym| x_methods.include?(ym) }
          field_shadows[y_norm] << x_norm
        end
      end

      all_norms.each do |norm|
        writers = @writes_by[norm] || []
        readers = @reads_by[norm]  || []

        wmethods = writers.map { |w| [w.file, w.defn] }.uniq
        rmethods = readers.map { |r| [r.file, r.defn] }.uniq

        ws = wmethods.size
        rs = rmethods.size
        tw = writers.size
        tr = readers.size

        next if tw == 0 && tr == 0

        # ---- dead state: written but never read ----
        if tw > 0 && tr == 0
          next if @sm.reads.any? { |r| r.norm == norm }
          results << Finding.new(
            field: norm, classification: "dead_state",
            write_spread: ws, read_spread: 0,
            total_writes: tw, total_reads: 0,
            write_sites: writers.map { |w| "#{w.file}:#{w.defn}:#{w.line}" }.uniq,
            read_sites: []
          )
          next
        end

        next if tw == 0

        # ---- classify ----
        all_one_method = (wmethods + rmethods).uniq.size == 1
        init_only = ws == 1 && wmethods[0][1] == "initialize"

        is_memo = false
        if all_one_method
          first_read  = readers.map(&:line).min
          first_write = writers.map(&:line).min
          is_memo = first_read && first_write && first_read <= first_write
        end

        shadow = field_shadows[norm].first

        classification = if init_only
          "immutable_convention"
        elsif is_memo
          "immutable_convention"
        elsif all_one_method
          "pass_through"
        elsif shadow
          "shadow_state"
        elsif ws >= 2 && rs <= 1
          "one_way_state"
        elsif ws >= 2 && rs >= 2
          "mutable_entity"
        else
          "immutable_convention"
        end

        results << Finding.new(
          field: norm,
          classification: classification,
          write_spread: ws,
          read_spread: rs,
          total_writes: tw,
          total_reads: tr,
          write_sites: writers.map { |w| "#{w.file}:#{w.defn}:#{w.line}" }.uniq,
          read_sites: readers.map { |r| "#{r.file}:#{r.defn}:#{r.line}" }.uniq,
          shadowed_by: shadow
        )
      end

      results.sort_by do |r|
        c = case r.classification
            when "dead_state" then 0
            when "shadow_state" then 1
            when "one_way_state" then 2
            when "mutable_entity" then 3
            when "pass_through" then 4
            when "immutable_convention" then 5
            else 6 end
        [-r.write_spread, -r.read_spread, c, r.field]
      end
    end
  end
end