# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # Guarded-pair / protocol mining (Engler "Bugs as Deviant Behavior",
  # PR-Miner, JADET). If methods that call `allocMark` also call
  # `cleanup` (or push then flush, open then close), that co-call is an
  # implied protocol. A method that calls one without the other is the
  # deviant -- the "similar path, one missing the step" plague that is
  # the literal shape of bugs #1/#2/#9.
  #
  # Unit = the SET of distinct call message-names in a method (FCALL /
  # CALL mid). Domain-agnostic (Engler): no name heuristics, mine all
  # pairs, rank by support, accept FP. Same proven shape as co_update,
  # over calls instead of assigned attributes.
  class SequenceMine
    Call = Struct.new(:mid, :file, :defn, :line, :span, keyword_init: true)
    DECLARATIVE_MIDS = %w[
      abstract! alias_method any attr_accessor attr_reader attr_writer bind
      cast checked enum extend final include interface! let must must_because
      nilable override overridable params prepend private private_class_method
      public require require_relative requires_ancestor sealed! sig type_member
      type_template untyped unsafe void
    ].freeze
    TEST_DSL_MIDS = %w[
      a_kind_of after around before be be_a be_an be_empty be_falsey be_nil
      be_truthy change contain_exactly context describe eq eql equal expect
      have_attributes have_key have_received it match not_to raise_error
      receive subject to
    ].freeze
    ZERO_ARG_ACTION_MIDS = %w[
      acquire begin close commit connect deinit disconnect drain finish flush
      lock open release rollback start stop unlock wait
    ].freeze
    IGNORED_MIDS = (DECLARATIVE_MIDS + TEST_DSL_MIDS).freeze

    def self.scan(files)
      calls = []
      files.each do |f|
        root, lines = Ast.parse(f)
        e = new(f)
        e.walk(root, [])
        calls.concat(e.calls)
      end
      Report.new(calls)
    end

    attr_reader :calls

    def initialize(file)
      @file = file
      @calls = []
    end

    def walk(node, defstack)
      return unless Ast.node?(node)

      defstack = Ast.def_push(node, defstack)
      if %i[CALL FCALL VCALL].include?(node.type)
        mid = node.children[node.type == :CALL ? 1 : 0]
        if protocol_event?(node, mid.to_s)
          @calls << Call.new(mid: mid.to_s, file: @file,
                             defn: defstack.last || "(top-level)",
                             line: node.first_lineno,
                             span: [node.first_lineno, node.first_column,
                                    node.last_lineno, node.last_column])
        end
      end
      node.children.each { |c| walk(c, defstack) }
    end

    private

    def protocol_event?(node, mid)
      return false if IGNORED_MIDS.include?(mid)
      return false if passive_reader_call?(node, mid)

      true
    end

    def passive_reader_call?(node, mid)
      node.type == :CALL && node.children[2].nil? &&
        !ZERO_ARG_ACTION_MIDS.include?(mid)
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

            hc = cs.find { |c| c.mid == has }
            loc = "#{file}:#{defn}:#{hc.line}"
            out << { pair: h[:pair], support: h[:support],
                     confidence: conf.round(2), has: has, missing: miss,
                     at: loc, spans: { loc => hc.span } }
          end
        end
        out.sort_by { |h| [-h[:confidence], -h[:support]] }
      end
    end
  end
end
