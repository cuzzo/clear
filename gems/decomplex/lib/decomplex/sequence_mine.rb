# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # Guarded-pair / protocol mining (Engler "Bugs as Deviant Behavior",
  # PR-Miner, JADET). If methods that call `allocMark` also call
  # `cleanup` (or push then flush, open then close), that co-call is an
  # implied protocol. A method that calls one without the other is the
  # deviant -- the "similar path, one missing the step" plague that is
  # the literal shape of bugs #1/#2/#9.
  #
  # Unit = the SET of distinct semantic call message-names in a method.
  # Domain-agnostic (Engler): no name heuristics, mine all
  # pairs, rank by support, accept FP. Same proven shape as co_update,
  # over calls instead of assigned attributes.
  class SequenceMine
    Call = Struct.new(:mid, :file, :defn, :line, :span, keyword_init: true)
    ZERO_ARG_ACTION_MIDS = %w[
      acquire begin close commit connect deinit disconnect drain finish flush
      lock open release rollback start stop unlock wait
    ].freeze
    ZERO_ARG_ACTION_PREFIXES = %w[
      analyze append apply build call check classify collect compile compute
      consume create declare emit enforce finalize find flush handle initialize
      lower mark normalize parse perform process push record register render
      resolve rewrite run scan set stamp sync transform validate verify visit
      walk warn write
    ].freeze
    def self.scan(files)
      calls = []
      files.each do |f|
        document = Syntax.parse(f, parser: "tree_sitter")
        e = new(f, document)
        e.collect
        calls.concat(e.calls)
      end
      Report.new(calls)
    end

    attr_reader :calls

    def initialize(file, document)
      @file = file
      @document = document
      @ignored_mids = Syntax.protocol_ignored_mids(document.language)
      @calls = []
    end

    def collect
      @document.call_sites.each do |call|
        mid = call.message.to_s
        nested_protocol_events(call).each do |nested_mid|
          @calls << Call.new(mid: nested_mid, file: @file,
                             defn: call.function || "(top-level)",
                             line: call.line,
                             span: call.span)
        end
        if protocol_event?(call, mid)
          @calls << Call.new(mid: mid, file: @file,
                             defn: call.function || "(top-level)",
                             line: call.line,
                             span: call.span)
        end
      end
    end

    private

    def protocol_event?(call, mid)
      return false if @ignored_mids.include?(mid)
      return false if passive_reader_call?(call, mid)

      true
    end

    def passive_reader_call?(call, mid)
      return false if zero_arg_action_name?(mid)

      return false unless call.arguments.to_a.empty?

      true
    end

    def nested_protocol_events(call)
      return [] unless @ignored_mids.include?(call.message.to_s)

      candidates = call.arguments.to_a
      candidates += source_text(call.span).scan(/\b[a-z_]\w*[!?]?\b/)
      candidates.uniq.select do |candidate|
        !@ignored_mids.include?(candidate) && zero_arg_action_name?(candidate)
      end
    end

    def zero_arg_action_name?(mid)
      return true if ZERO_ARG_ACTION_MIDS.include?(mid)
      return true if mid.end_with?("!")

      ZERO_ARG_ACTION_PREFIXES.any? do |prefix|
        mid == prefix || mid.start_with?("#{prefix}_")
      end
    end

    def source_text(span)
      return "" unless span

      first_line, first_column, last_line, last_column = span
      if first_line == last_line
        return @document.lines[first_line - 1].to_s[first_column...last_column].to_s
      end

      parts = []
      parts << @document.lines[first_line - 1].to_s[first_column..].to_s
      parts.concat(@document.lines[first_line...(last_line - 1)] || [])
      parts << @document.lines[last_line - 1].to_s[0...last_column].to_s
      parts.join
    end

    class Report
      # No frequency blocklist: a pervasive protocol (alloc_mark +
      # cleanup in every method) is exactly the high-frequency case we
      # must keep. Generic glue (`log`) is instead suppressed by
      # confidence ranking -- a violation only matters when nearly
      # every site that does A also does B.
      def initialize(calls)
        @by_unit = calls.group_by { |c| [c.file, c.defn] }
        @support = Hash.new(0)
        @by_unit.each_value { |cs| cs.map(&:mid).uniq.each { |m| @support[m] += 1 } }
      end

      def co_called_pairs(min_support: 4)
        counts = Hash.new { |h, k| h[k] = [] }
        @by_unit.each do |unit, cs|
          cs.map(&:mid).uniq.sort.combination(2).each { |p| counts[p] << unit }
        end
        counts.filter_map do |pair, us|
          next if us.size < min_support

          { pair: pair, support: us.size,
            sites: us.map { |f, d| "#{f}:#{d}" } }
        end.sort_by { |h| -h[:support] }
      end

      # A method doing exactly one of a high-support pair. Confidence =
      # support(pair) / support(has): the fraction of "did A" sites
      # that also "did B". Near-1 confidence with one violator is the
      # strong deviant; low confidence is incidental co-occurrence.
      def broken_protocol(min_support: 4, min_confidence: 0.75)
        pairs = co_called_pairs(min_support: min_support)
        out = []
        @by_unit.each do |(file, defn), cs|
          mids = cs.map(&:mid).uniq
          pairs.each do |h|
            a, b = h[:pair]
            has, miss =
              if mids.include?(a) && !mids.include?(b) then [a, b]
              elsif mids.include?(b) && !mids.include?(a) then [b, a]
              end
            next unless has

            conf = h[:support].to_f / @support[has]
            next if conf < min_confidence

            hc = cs.select { |c| c.mid == has }
                   .min_by { |c| [c.line.to_i, Array(c.span), c.mid.to_s] }
            loc = "#{file}:#{defn}:#{hc.line}"
            out << { pair: h[:pair], support: h[:support],
                     confidence: conf.round(2), has: has, missing: miss,
                     at: loc, spans: { loc => hc.span } }
          end
        end
        out.sort_by { |h| [-h[:confidence], -h[:support], h[:at].to_s] }
      end
    end
  end
end
