# frozen_string_literal: true

require "set"
require_relative "ast"

module Decomplex
  # ImplicitControlFlow finds internal call order where order is state-dependent,
  # e.g. `prepare; validate` when `prepare` writes state that `validate` reads.
  # Generic call-order repetition is intentionally ignored.
  class ImplicitControlFlow
    MethodEffect = Struct.new(:file, :owner, :name, :line, :reads, :writes, keyword_init: true)
    Call = Struct.new(:mid, :file, :owner, :defn, :line, :span, :reads, :writes, keyword_init: true)
    MethodSequence = Struct.new(:file, :owner, :defn, :line, :calls, keyword_init: true)
    Path = Struct.new(:calls, :terminal, keyword_init: true)
    PATH_LIMIT = 64

    DECLARATIVE_MIDS = %w[
      abstract! alias_method any attr_accessor attr_reader attr_writer bind
      cast checked enum extend final include interface! let must must_because
      nilable override overridable params prepend private private_class_method
      protected public require require_relative requires_ancestor sealed! sig
      type_member type_template untyped unsafe void
    ].freeze
    TEST_DSL_MIDS = %w[
      a_kind_of after around before be be_a be_an be_empty be_falsey be_nil
      be_truthy change contain_exactly context describe eq eql equal expect
      have_attributes have_key have_received it match not_to raise_error
      receive subject to
    ].freeze
    IGNORED_MIDS = (DECLARATIVE_MIDS + TEST_DSL_MIDS).freeze
    OPTIONAL_DIAGNOSTIC_MIDS = %w[
      error! fixable! warn!
    ].freeze
    MUTATING_MIDS = %w[
      << []= add append clear collect! compact! concat declare delete delete_if
      each_key= fill filter! keep_if mark merge! move push reject! replace
      resolve shift stamp store unshift update write
    ].freeze
    NON_MUTATING_OPERATOR_MIDS = %w[! != !~].freeze
    MUTATING_SUFFIXES = %w[!].freeze

    def self.scan(files)
      parsed = files.each_with_object({}) do |file, out|
        out[file] = Ast.parse(file)
      end
      effect_index = EffectIndex.build(parsed)
      sequences = []
      parsed.each do |file, (root, lines)|
        miner = new(file, lines, effect_index)
        miner.walk(root, [])
        sequences.concat(miner.sequences)
      end
      Report.new(sequences)
    end

    attr_reader :sequences

    def initialize(file, lines, effect_index)
      @file = file
      @lines = lines
      @effect_index = effect_index
      @sequences = []
    end

    def walk(node, owners)
      return unless Ast.node?(node)

      case node.type
      when :CLASS, :MODULE
        owners = owners + [owner_name(node)]
      when :DEFN, :DEFS
        record_method_paths(node, owners.join("::"))
        return
      end

      node.children.each { |child| walk(child, owners) }
    end

    private

    def record_method_paths(node, owner)
      defn = method_name(node)
      method_paths(node).each do |path|
        calls = path.calls.map { |call| call_for(call, owner, defn) }
        next if calls.count { |call| stateful_call?(call) } < 2

        @sequences << MethodSequence.new(
          file: @file,
          owner: owner,
          defn: defn,
          line: node.first_lineno,
          calls: calls
        )
      end
    end

    def method_paths(node)
      paths_for_statements(Ast.body_stmts(node))
    end

    def paths_for_statements(statements)
      statements.compact.each_with_object([empty_path]) do |statement, paths|
        next if Ast.node?(statement) && statement.type == :BEGIN

        statement_paths = paths_for(statement)
        paths.replace(append_statement_paths(paths, statement_paths))
      end
    end

    def append_statement_paths(paths, statement_paths)
      combine_path_lists(paths, statement_paths)
    end

    def combine_path_lists(left_paths, right_paths)
      combined = left_paths.flat_map do |path|
        if path.terminal
          [path]
        else
          right_paths.map do |right_path|
            Path.new(calls: path.calls + right_path.calls, terminal: right_path.terminal)
          end
        end
      end
      combined.first(PATH_LIMIT)
    end

    def paths_for(node)
      return [empty_path] unless Ast.node?(node)

      case node.type
      when :BLOCK
        paths_for_statements(node.children)
      when :SCOPE
        paths_for(scope_body(node))
      when :IF, :UNLESS
        branch_paths(node)
      when :CASE, :CASE2
        case_paths(node)
      when :RETURN, :BREAK, :NEXT, :REDO, :RETRY
        generic_paths(node).map { |path| Path.new(calls: path.calls, terminal: true) }
      else
        generic_paths(node)
      end
    end

    def branch_paths(node)
      condition = node.children[0]
      positive = node.children[1]
      negative = node.children[2]
      alternatives = paths_for(positive) + (negative ? paths_for(negative) : [empty_path])
      combine_path_lists(paths_for(condition), alternatives)
    end

    def case_paths(node)
      condition, first_when = case_parts(node)
      combine_path_lists(paths_for(condition), when_paths(first_when))
    end

    def case_parts(node)
      return [nil, node.children[0]] if node.type == :CASE2

      [node.children[0], node.children[1]]
    end

    def when_paths(node)
      return [empty_path] unless Ast.node?(node)

      return paths_for(node) unless node.type == :WHEN

      patterns = node.children[0]
      body = node.children[1]
      next_node = node.children[2]
      current_branch = combine_path_lists(paths_for(patterns), paths_for(body))
      (current_branch + when_paths(next_node)).first(PATH_LIMIT)
    end

    def generic_paths(node)
      return [empty_path] unless Ast.node?(node)
      return [empty_path] if %i[CLASS MODULE DEFN DEFS LAMBDA].include?(node.type)

      child_paths = node.children.each_with_object([empty_path]) do |child, paths|
        paths.replace(combine_path_lists(paths, paths_for(child)))
      end

      internal_mid = internal_protocol_call(node)
      return child_paths unless internal_mid

      combine_path_lists([Path.new(calls: [raw_call(internal_mid, node)], terminal: false)], child_paths)
    end

    def raw_call(mid, node)
      Call.new(
        mid: mid,
        file: @file,
        owner: nil,
        defn: nil,
        line: node.first_lineno,
        span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
        reads: [],
        writes: []
      )
    end

    def call_for(call, owner, defn)
      effect = @effect_index.effect_for(owner, call.mid)
      Call.new(
        mid: call.mid,
        file: call.file,
        owner: owner,
        defn: defn,
        line: call.line,
        span: call.span,
        reads: effect ? effect.reads : [],
        writes: effect ? effect.writes : []
      )
    end

    def stateful_call?(call)
      !(call.reads + call.writes).empty?
    end

    def empty_path
      Path.new(calls: [], terminal: false)
    end

    def scope_body(node)
      node.children[2]
    end

    def owner_name(node)
      Ast.slice(node.children[0], @lines).to_s.empty? ? "(anonymous)" : Ast.slice(node.children[0], @lines)
    end

    def method_name(node)
      node.children[node.type == :DEFS ? 1 : 0].to_s
    end

    def internal_protocol_call(node)
      mid = call_mid(node)
      return nil unless mid
      return nil if IGNORED_MIDS.include?(mid)
      return nil unless internal_receiver?(node)

      mid
    end

    def call_mid(node)
      case node.type
      when :CALL, :OPCALL, :ATTRASGN then node.children[1].to_s
      when :FCALL, :VCALL then node.children[0].to_s
      end
    end

    def internal_receiver?(node)
      return true if %i[FCALL VCALL].include?(node.type)

      receiver = node.children[0]
      Ast.node?(receiver) && receiver.type == :SELF
    end

    class EffectIndex
      def self.build(parsed)
        effects = []
        parsed.each do |file, (root, lines)|
          effects.concat(EffectCollector.new(file, lines).scan(root))
        end
        new(effects)
      end

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

    class EffectCollector
      def initialize(file, lines)
        @file = file
        @lines = lines
      end

      def scan(root)
        out = []
        walk(root, [], out)
        out
      end

      private

      def walk(node, owners, out)
        return unless Ast.node?(node)

        case node.type
        when :CLASS, :MODULE
          owners = owners + [owner_name(node)]
        when :DEFN, :DEFS
          out << method_effect(node, owners.join("::"))
          return
        end

        node.children.each { |child| walk(child, owners, out) }
      end

      def method_effect(node, owner)
        reads = Set.new
        writes = Set.new
        collect_state_access(node, reads, writes)
        MethodEffect.new(
          file: @file,
          owner: owner,
          name: method_name(node),
          line: node.first_lineno,
          reads: reads.to_a.sort,
          writes: writes.to_a.sort
        )
      end

      def collect_state_access(node, reads, writes)
        return unless Ast.node?(node)
        return if %i[CLASS MODULE DEFN DEFS LAMBDA].include?(node.type) && !%i[DEFN DEFS].include?(node.type)

        case node.type
        when :IASGN
          writes << normalize_state(node.children[0].to_s)
        when :IVAR
          reads << normalize_state(node.children[0].to_s)
        when :ATTRASGN
          collect_attr_write(node, writes)
        when :CALL, :OPCALL
          collect_receiver_mutation(node, writes)
          collect_self_reader(node, reads)
        when :VCALL, :FCALL
          collect_self_reader(node, reads)
        end

        node.children.each { |child| collect_state_access(child, reads, writes) }
      end

      def collect_attr_write(node, writes)
        receiver, mid = node.children
        attr = mid.to_s.sub(/=$/, "")
        if mid == :[]=
          writes << state_receiver_token(receiver) if state_receiver_token(receiver)
        elsif self_receiver?(receiver)
          writes << normalize_state(attr)
        elsif (receiver_token = state_receiver_token(receiver))
          writes << "#{receiver_token}.#{attr}"
        end
      end

      def collect_receiver_mutation(node, writes)
        receiver, mid = node.children
        return unless mutating_mid?(mid.to_s)

        token = state_receiver_token(receiver)
        writes << token if token
      end

      def collect_self_reader(node, reads)
        mid = call_mid(node)
        return unless mid
        return if mutating_mid?(mid)
        return if IGNORED_MIDS.include?(mid)
        return unless no_args?(node)
        return if node.type == :CALL && !self_receiver?(node.children[0])

        reads << normalize_state(mid)
      end

      def mutating_mid?(mid)
        return false if NON_MUTATING_OPERATOR_MIDS.include?(mid)

        MUTATING_MIDS.include?(mid) || MUTATING_SUFFIXES.any? { |suffix| mid.end_with?(suffix) }
      end

      def no_args?(node)
        case node.type
        when :CALL, :OPCALL
          node.children[2].nil?
        when :VCALL
          true
        when :FCALL
          node.children[1].nil?
        else
          false
        end
      end

      def state_receiver_token(node)
        return nil unless Ast.node?(node)

        case node.type
        when :IVAR
          normalize_state(node.children[0].to_s)
        when :SELF
          "self"
        when :VCALL, :FCALL
          normalize_state(node.children[0].to_s)
        when :CALL
          return nil unless no_args?(node)

          normalize_state(node.children[1].to_s)
        else
          nil
        end
      end

      def self_receiver?(node)
        Ast.node?(node) && node.type == :SELF
      end

      def call_mid(node)
        case node.type
        when :CALL, :OPCALL, :ATTRASGN then node.children[1].to_s
        when :FCALL, :VCALL then node.children[0].to_s
        end
      end

      def owner_name(node)
        Ast.slice(node.children[0], @lines).to_s.empty? ? "(anonymous)" : Ast.slice(node.children[0], @lines)
      end

      def method_name(node)
        node.children[node.type == :DEFS ? 1 : 0].to_s
      end

      def normalize_state(name)
        name.to_s.sub(/\A@/, "").sub(/=\z/, "")
      end
    end

    class Report
      def initialize(sequences)
        @sequences = sequences
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
        protocol.any? { |mid| OPTIONAL_DIAGNOSTIC_MIDS.include?(mid) }
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
