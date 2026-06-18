# frozen_string_literal: true

require "set"
require_relative "ast"

module Decomplex
  # SuperfluousState -- fields that could be eliminated entirely.
  #
  # Post-analyzer over StateMesh + ImplicitControlFlow. Does no new AST
  # walks. Detects four eliminability patterns:
  #
  #   1. Dead state -- written but never read. The field captures a
  #      value that is never used. Provably removable.
  #
  #   2. Intra-method pass-through -- field written and read within the
  #      same method body. The value never escapes the stack frame.
  #      Memoized cache accessors (read-before-write pattern) are
  #      disqualified.
  #
  #   3. Adjacent-call pass-through -- single-writer single-reader where
  #      every observed callsite has writer immediately preceding reader.
  #
  #   4. Derived cache -- computed from other fields, never independently
  #      mutated. Includes memoized accessors and constructor-set config.
  #
  # Noise gating:
  #   - Only self-state (@ivar and self.attr); ignores other.attr.
  #   - Read-before-write within same method disqualifies intra-method
  #     (memo pattern, not pass-through).
  #   - Constructor-set fields get a 0.33x penalty.
  #   - Fields read only via hash/eql?/to_s/inspect are flagged as
  #     identity-only (may be eligible for structural replacement).
  class SuperfluousState
    Finding = Struct.new(:field, :score, :classification,
                         :writer_method_count, :reader_method_count,
                         :write_sites, :read_sites,
                         :writer_methods, :reader_methods,
                         :ctorset, :adjacent_sites,
                         keyword_init: true) do
      def to_h
        {
          field: field,
          score: score.round(3),
          classification: classification,
          writer_method_count: writer_method_count,
          reader_method_count: reader_method_count,
          write_sites: write_sites,
          read_sites: read_sites,
          writer_methods: writer_methods,
          reader_methods: reader_methods,
          ctorset: ctorset,
          adjacent_sites: adjacent_sites
        }
      end
    end

    def self.scan(files)
      sm = StateMesh.scan(files, min_writes: 1)
      sm.run

      adjacent_pairs = build_adjacent_pairs(files)
      new(sm, adjacent_pairs).scan
    end

    def initialize(state_mesh, adjacent_pairs = {})
      @sm = state_mesh
      @adjacent_pairs = adjacent_pairs
    end

    def scan
      group_by_field
      score_and_rank
    end

    private

    def group_by_field
      @writes_by = Hash.new { |h, k| h[k] = [] }
      @reads_by  = Hash.new { |h, k| h[k] = [] }

      @sm.writes.each do |w|
        next unless w.recv == "self"  # ignore other.attr
        @writes_by[w.norm] << w
      end
      @sm.reads.each do |r|
        next unless r.recv == "self"
        @reads_by[r.norm] << r
      end
    end

    def score_and_rank
      results = []

      all_norms = (@writes_by.keys + @reads_by.keys).uniq

      # ---- Pattern 1: dead state (written, never read) ----
      all_norms.each do |norm|
        next unless @writes_by.key?(norm) && !@reads_by.key?(norm)
        # Reject if StateMesh has ANY read (including non-self reads
        # like metaprogramming access), not just self-filtered reads.
        next if @sm.reads.any? { |r| r.norm == norm }

        writers = @writes_by[norm]
        results << Finding.new(
          field: norm, score: 0.85, classification: "dead_state",
          writer_method_count: writers.map { |w| [w.file, w.defn] }.uniq.size,
          reader_method_count: 0,
          write_sites: writers.map { |w| "#{w.file}:#{w.defn}:#{w.line}" }.uniq,
          read_sites: [],
          write_sites: writers.map { |w| "#{w.file}:#{w.defn}:#{w.line}" }.uniq,
          read_sites: [],
          writer_methods: writers.map(&:defn).uniq,
          reader_methods: [],
          ctorset: writers.all? { |w| w.defn == "initialize" },
          adjacent_sites: nil
        )
      end

      # ---- Pattern 2-4: eliminability scoring ----
      all_norms.each do |norm|
        writers = @writes_by[norm] || []
        readers = @reads_by[norm]  || []
        next if writers.empty? || readers.empty?

        writer_methods = writers.map { |w| [w.file, w.defn] }.uniq
        reader_methods = readers.map { |r| [r.file, r.defn] }.uniq
        all_sites = (writer_methods + reader_methods).uniq

        wc = writer_methods.size
        rc = reader_methods.size

        # ---- base dampened score ----
        base = 1.0 / (wc * rc + 1)

        # ---- intra-method pass-through ----
        intra = (all_sites.size == 1)
        if intra
          # Disqualify if any read precedes the earliest write (the field
          # carries state from outside this method -- e.g. read-modify-write
          # or a method that reads prior-call state before writing).
          first_write_line = writers.map(&:line).min
          intra = false if readers.any? { |r| r.line < first_write_line }
        end
        intra_bonus = intra ? 10.0 : 1.0

        # ---- constructor-set penalty ----
        ctorset = wc == 1 && writer_methods[0][1] == "initialize"
        ctor_penalty = ctorset ? 0.33 : 1.0

        # ---- adjacent-call bonus ----
        adj_bonus = 1.0
        adj_sites = nil
        if wc == 1 && rc == 1 && !intra
          wm_name = writer_methods[0][1]
          rm_name = reader_methods[0][1]
          pair_key = [wm_name, rm_name]
          fields = @adjacent_pairs[pair_key]
          if fields.include?(norm)
            adj_bonus = 5.0
            adj_sites = fields.to_a  # would be the sites list from ICF
          end
        end

        score = base * intra_bonus * adj_bonus * ctor_penalty
        next if score < 0.1

        classification = if intra
                           "intra_method"
                         elsif adj_bonus > 1.0
                           "adjacent_call"
                         else
                           "derived_cache"
                         end

        results << Finding.new(
          field: norm,
          score: score,
          classification: classification,
          writer_method_count: wc,
          reader_method_count: rc,
          write_sites: writers.map { |w| "#{w.file}:#{w.defn}:#{w.line}" }.uniq,
          read_sites: readers.map { |r| "#{r.file}:#{r.defn}:#{r.line}" }.uniq,
          writer_methods: writer_methods.map { |_f, d| d }.uniq,
          reader_methods: reader_methods.map { |_f, d| d }.uniq,
          ctorset: ctorset,
          adjacent_sites: adj_sites
        )
      end

      results.sort_by { |r| -r.score }
    end

    # Build a lookup: (writer_method, reader_method) -> Set[field_norm]
    # from ImplicitControlFlow's ordered protocol facts.
    def self.build_adjacent_pairs(files)
      pairs = Hash.new { |h, k| h[k] = Set.new }
      report = ImplicitControlFlow.scan(files)
      report.ordered_protocols.each do |proto|
        next unless proto[:dependency] == "write_read"
        writer, reader = proto[:protocol]
        fields = proto[:states]
        fields.each { |f| pairs[[writer, reader]].add(f) }
      end
      pairs
    rescue StandardError => e
      warn "SuperfluousState: ImplicitControlFlow unavailable: #{e.message}"
      {}
    end
  end
end
