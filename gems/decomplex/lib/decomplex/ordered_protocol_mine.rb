# frozen_string_literal: true

require "set"
require_relative "syntax"

module Decomplex
  # ImplicitControlFlow finds internal call order where order is state-dependent,
  # e.g. `prepare; validate` when `prepare` writes state that `validate` reads.
  # Generic call-order repetition is intentionally ignored.
  class ImplicitControlFlow
    MethodEffect = Syntax::ProtocolMethodEffect
    Call = Struct.new(:mid, :file, :owner, :defn, :line, :span, :reads, :writes, keyword_init: true)
    MethodSequence = Struct.new(:file, :owner, :defn, :line, :calls, keyword_init: true)

    def self.scan(files)
      documents = files.map { |file| Syntax.parse(file, parser: "tree_sitter") }
      effect_index = EffectIndex.new(documents.flat_map(&:protocol_method_effects))
      sequences = documents.flat_map { |document| sequences_for_document(document, effect_index) }
      diagnostics = documents.flat_map do |document|
        Syntax.protocol_lexicon_for(document.language).optional_diagnostic_mids
      end.uniq
      Report.new(sequences, optional_diagnostic_mids: diagnostics)
    end

    def self.sequences_for_document(document, effect_index)
      document.protocol_call_paths.filter_map do |path|
        calls = path.calls.map { |call| call_for_path(call, path, effect_index) }
        next if calls.count { |call| stateful_call?(call) } < 2

        MethodSequence.new(
          file: path.file,
          owner: path.owner,
          defn: path.name,
          line: path.line,
          calls: calls
        )
      end
    end

    def self.call_for_path(call, path, effect_index)
      effect = effect_index.effect_for(path.owner, call.mid)
      Call.new(
        mid: call.mid,
        file: path.file,
        owner: path.owner,
        defn: path.name,
        line: call.line,
        span: call.span,
        reads: effect ? effect.reads : [],
        writes: effect ? effect.writes : []
      )
    end

    def self.stateful_call?(call)
      !(call.reads + call.writes).empty?
    end

    class EffectIndex
      def initialize(effects)
        @by_owner_name = effects.to_h { |effect| [[effect.owner, effect.name], effect] }
        @by_name = effects.group_by(&:name)
      end

      def effect_for(owner, name)
        exact = @by_owner_name[[owner, name]]
        return exact if exact

        candidates = Array(@by_name[name]).select { |effect| effect_stateful?(effect) }
        return candidates.first if candidates.size == 1

        nil
      end

      private

      def effect_stateful?(effect)
        !(effect.reads + effect.writes).empty?
      end
    end

    class Report
      def initialize(sequences, optional_diagnostic_mids:)
        @sequences = sequences
        @optional_diagnostic_mids = optional_diagnostic_mids
        @site_call_sets = sequences.each_with_object(Hash.new { |h, k| h[k] = {} }) do |seq, out|
          state_calls(seq).each { |call| out[site_key(seq)][call.mid] = true }
        end
      end

      def ordered_protocols(min_support: 1)
        counts = Hash.new { |h, k| h[k] = {} }
        @sequences.each do |seq|
          calls = collapse_consecutive(state_calls(seq))
          calls.each_cons(2) do |left, right|
            edge = dependency_edge(left, right)
            next unless edge
            next if diagnostic_protocol?([left.mid, right.mid])

            key = [left.mid, right.mid, edge[:kind].join("|"), edge[:states].join("|")]
            counts[key][site_key(seq)] ||= {
              protocol: [left.mid, right.mid],
              dependency: edge[:kind],
              states: edge[:states],
              left: left,
              seq: seq
            }
          end
        end

        counts.filter_map do |_key, sites_by_key|
          next if sites_by_key.size < min_support

          first = sites_by_key.values.first
          at = seq_site(first[:seq])
          {
            kind: :protocol_pressure,
            protocol: first[:protocol],
            dependency: first[:dependency],
            states: first[:states],
            support: sites_by_key.size,
            confidence: 1.0,
            at: at,
            observed: first[:protocol],
            missing: [],
            sites: sites_by_key.values.map { |row| seq_site(row[:seq]) },
            spans: { at => first[:left].span }
          }
        end.sort_by { |row| [-row[:support], dependency_rank(row), row[:protocol].join("\u0000")] }
      end

      def ordered_triples(min_support: 1)
        ordered_protocols(min_support: min_support)
      end

      def drift(min_support: 4, min_confidence: 0.75)
        protocols = ordered_protocols(min_support: min_support)
        protocol_index = index_protocols_by_pair(protocols)
        denominator_cache = {}
        out = []
        @sequences.each do |seq|
          calls = collapse_consecutive(state_calls(seq))
          mids = calls.map(&:mid)
          positions = first_positions(mids)
          candidate_protocols(positions.keys, protocol_index).each do |protocol_row|
            protocol = protocol_row[:protocol]
            present = protocol.select { |mid| positions.key?(mid) }
            next if present.size < 2
            next if ordered_subsequence?(mids, protocol)

            denominator = denominator_for(present, denominator_cache)
            confidence = protocol_row[:support].to_f / denominator
            next if confidence < min_confidence

            out << finding(seq, protocol_row, present, positions, confidence)
          end
        end
        dedupe(out).sort_by { |row| [-row[:confidence], -row[:support], row[:at]] }
      end

      private

      def dependency_rank(row)
        dependency = row[:dependency]
        return 0 if dependency.include?("write_read")
        return 1 if dependency.include?("write_write")

        2
      end

      def state_calls(seq)
        seq.calls.select { |call| !(call.reads + call.writes).empty? }
      end

      def collapse_consecutive(calls)
        previous = nil
        calls.each_with_object([]) do |call, out|
          next if previous == call.mid

          previous = call.mid
          out << call
        end
      end

      def dependency_edge(left, right)
        left_writes = Set.new(left.writes)
        left_reads = Set.new(left.reads)
        right_writes = Set.new(right.writes)
        right_reads = Set.new(right.reads)
        kinds = []
        states = Set.new

        write_read = left_writes & right_reads
        unless write_read.empty?
          kinds << "write_read"
          states.merge(write_read)
        end

        write_write = left_writes & right_writes
        unless write_write.empty?
          kinds << "write_write"
          states.merge(write_write)
        end

        read_write = left_reads & right_writes
        unless read_write.empty?
          kinds << "read_write"
          states.merge(read_write)
        end

        return nil if kinds.empty?

        { kind: kinds.sort, states: states.to_a.sort }
      end

      def diagnostic_protocol?(protocol)
        protocol.any? do |mid|
          @optional_diagnostic_mids.include?(mid) ||
            @optional_diagnostic_mids.include?("#{mid}!")
        end
      end

      def index_protocols_by_pair(protocols)
        protocols.each_with_object(Hash.new { |h, k| h[k] = [] }) do |row, index|
          index[pair_key(row[:protocol])] << row
        end
      end

      def candidate_protocols(mids, protocol_index)
        seen = {}
        mids.combination(2).each_with_object([]) do |pair, out|
          protocol_index[pair_key(pair)].each do |row|
            key = [row[:protocol], row[:dependency], row[:states]]
            next if seen[key]

            seen[key] = true
            out << row
          end
        end
      end

      def pair_key(pair)
        pair.sort.join("\u0000")
      end

      def site_key(seq)
        [seq.file, seq.owner, seq.defn, seq.line]
      end

      def seq_site(seq)
        "#{seq.file}:#{seq.defn}:#{seq.line}"
      end

      def first_positions(values)
        values.each_with_index.each_with_object({}) do |(mid, idx), out|
          out[mid] ||= idx
        end
      end

      def ordered_subsequence?(mids, protocol)
        idx = 0
        mids.each do |mid|
          idx += 1 if mid == protocol[idx]
          return true if idx == protocol.size
        end
        false
      end

      def denominator_for(present, denominator_cache)
        key = pair_key(present)
        denominator_cache[key] ||= @site_call_sets.values.count do |mids|
          present.all? { |mid| mids.key?(mid) }
        end.then { |count| [count, 1].max }
      end

      def finding(seq, protocol_row, present, positions, confidence)
        protocol = protocol_row[:protocol]
        anchor_mid = present.min_by { |mid| positions[mid] }
        anchor = seq.calls.find { |call| call.mid == anchor_mid }
        loc = "#{seq.file}:#{seq.defn}:#{anchor&.line || seq.line}"
        {
          kind: :order_drift,
          protocol: protocol,
          observed: present.sort_by { |mid| positions[mid] },
          missing: [],
          dependency: protocol_row[:dependency],
          states: protocol_row[:states],
          support: protocol_row[:support],
          confidence: confidence.round(2),
          at: loc,
          sites: protocol_row[:sites],
          spans: { loc => anchor&.span }
        }
      end

      def dedupe(rows)
        seen = {}
        rows.each_with_object([]) do |row, out|
          key = [row[:kind], row[:at], row[:protocol], row[:observed], row[:states]]
          next if seen[key]

          seen[key] = true
          out << row
        end
      end
    end
  end

  OrderedProtocolMine = ImplicitControlFlow
end
