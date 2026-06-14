# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # Co-update / inconsistent-update mining (cf. Lu et al., DynaMine).
  #
  # Plague targeted: "redundant state that drifts" and "the same path
  # in many places, one place misses the step." If attribute `.storage`
  # and attribute `.provenance` are assigned together in N methods, a
  # method that assigns one without the other is a probable desync --
  # exactly the documented invariant-#16 pairing whose violation is a
  # latent UAF.
  #
  # Unit of mutation = the ATTRIBUTE / ivar NAME (not the full receiver
  # chain): `node.storage =` and `decl.storage =` are the same logical
  # state edit, so they must cluster regardless of receiver. lvar
  # assignment is deliberately NOT mined (loop temps etc. are noise).
  #
  # Output is a ranked CANDIDATE list, not a verdict (Engler's
  # discipline): FP is acceptable, the receiver is printed so triage is
  # a one-line read.
  class CoUpdate
    Write = Struct.new(:attr, :recv, :file, :defn, :line, :span,
                       keyword_init: true)

    def self.scan(files)
      writes = files.flat_map do |file|
        Syntax.parse(file).state_writes.map do |write|
          Write.new(
            attr: write.field,
            recv: write.receiver,
            file: write.file,
            defn: write.function,
            line: write.line,
            span: write.span
          )
        end
      end
      Report.new(writes)
    end

    # Frequent co-written attribute pairs + the methods that break them.
    class Report
      def initialize(writes)
        @writes = writes
        @by_unit = writes.group_by { |w| [w.file, w.defn] }
      end

      # [{ pair:, support:, sites:[...] }, ...]
      def co_written_pairs(min_support: 3)
        counts = Hash.new { |h, k| h[k] = [] }
        @by_unit.each do |unit, ws|
          attrs = ws.map(&:attr).uniq.sort
          attrs.combination(2).each { |pair| counts[pair] << unit }
        end
        counts.filter_map do |pair, units|
          next if units.size < min_support

          { pair: pair, support: units.size,
            sites: units.map { |f, d| "#{f}:#{d}" } }
        end.sort_by { |h| -h[:support] }
      end

      # A method writing exactly one of a high-support pair. The other
      # attribute's absence next to a same-receiver write is the desync.
      # [{ pair:, support:, has:, missing:, at:, recv: }, ...]
      def neglected_updates(min_support: 3)
        pairs = co_written_pairs(min_support: min_support)
        out = []
        @by_unit.each do |(file, defn), ws|
          attrs = ws.map(&:attr).uniq
          pairs.each do |h|
            a, b = h[:pair]
            has, miss = if attrs.include?(a) && !attrs.include?(b)
                          [a, b]
                        elsif attrs.include?(b) && !attrs.include?(a)
                          [b, a]
                        end
            next unless has

            w = ws.find { |x| x.attr == has }
            out << { pair: h[:pair], support: h[:support], has: has,
                     missing: miss, at: "#{file}:#{defn}:#{w.line}",
                     spans: { "#{file}:#{defn}:#{w.line}" => w.span },
                     recv: w.recv }
          end
        end
        out.sort_by { |h| -h[:support] }
      end
    end
  end
end
