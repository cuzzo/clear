# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # Decision-pressure: attribute defensive type/nil guards to the
  # canonical root contract their subject comes from, then rank contracts
  # by how many re-derived decisions they drive.
  class DecisionPressure
    GUARD_MIDS = %w[
      is_a? kind_of? instance_of? nil? respond_to?
      is_none is_some is_null isNull
    ].freeze
    TRANSIENT_NOARG_MIDS = %w[pop shift].freeze
    Hit = Struct.new(:contract, :file, :defn, :line, :span,
                     keyword_init: true)

    def self.scan(files)
      guard = []
      dispatch = []
      files.each do |file|
        document = Syntax.parse(file, parser: "tree_sitter")
        assignment_maps = document.local_methods.to_h do |method|
          [method.name, build_assignment_map(method)]
        end

        document.call_sites.each do |call|
          next if call.receiver.to_s.empty?

          asgmap = assignment_maps.fetch(call.function, {})
          if eliminable_guard?(call)
            contract = contract_of(call.receiver, asgmap)
            guard << hit(contract, call) if contract
          elsif essential_dispatch?(call)
            contract = contract_of(call.receiver, asgmap)
            dispatch << hit(contract, call) if contract
          end
        end

        guard.concat(rescue_nil_hits(document, assignment_maps))
      end
      Report.new(guard, dispatch)
    end

    def self.eliminable_guard?(call)
      GUARD_MIDS.include?(call.message.to_s) || call.safe_navigation
    end

    def self.essential_dispatch?(call)
      call.message.to_s.end_with?("?")
    end

    def self.hit(contract, call)
      Hit.new(
        contract: contract,
        file: call.file,
        defn: call.function,
        line: call.line,
        span: call.span
      )
    end

    def self.rescue_nil_hits(document, assignment_maps)
      document.local_methods.flat_map do |method|
        asgmap = assignment_maps.fetch(method.name, {})
        method.statements.filter_map do |statement|
          next unless statement.source.match?(/\brescue\s+nil\b/)

          call = document.call_sites.find do |candidate|
            candidate.function == method.name && inside_span?(candidate.span, statement.span)
          end
          next unless call

          contract = contract_of(call_expression(call), asgmap)
          next unless contract

          Hit.new(
            contract: contract,
            file: method.file,
            defn: method.name,
            line: statement.line,
            span: statement.span
          )
        end
      end
    end

    def self.build_assignment_map(method)
      method.statements.each_with_object({}) do |statement, map|
        next unless statement.writes.size == 1

        name = statement.writes.first.to_s
        map[name] ||= simple_source_contract(statement.source)
      end.compact
    end

    def self.simple_source_contract(source)
      match = source.to_s.match(/\A\s*[A-Za-z_]\w*\s*=\s*(.+?)\s*\z/m)
      return nil unless match

      rhs = match[1].strip
      return nil if rhs.match?(/\s(?:if|unless|rescue)\s|\?|:/)

      contract_of(rhs, {})
    end

    def self.contract_of(receiver, assignment_map, depth = 0)
      source = receiver.to_s.strip
      return nil if source.empty? || depth >= 8

      mapped = assignment_map[source]
      return mapped if mapped

      return source if source.start_with?("@")

      if (match = source.match(/\A(?:[A-Za-z_]\w*|self)\s*\[(.+)\]\z/))
        return "[#{match[1].strip}]"
      end

      return "~local" if source.match?(/\A[A-Za-z_]\w*\z/)

      if source.include?(".")
        member = source.split(".").last.to_s
        member = member.sub(/\(.*\)\z/, "")
        return nil if TRANSIENT_NOARG_MIDS.include?(member)

        return ".#{member}" unless member.empty?
      end

      nil
    end

    def self.call_expression(call)
      [call.receiver, call.message].map(&:to_s).reject(&:empty?).join(".")
    end

    def self.inside_span?(inner, outer)
      return false unless inner && outer

      starts_after_or_at = (inner[0] > outer[0]) || (inner[0] == outer[0] && inner[1] >= outer[1])
      ends_before_or_at = (inner[2] < outer[2]) || (inner[2] == outer[2] && inner[3] <= outer[3])
      starts_after_or_at && ends_before_or_at
    end

    class Report
      def initialize(guard_hits, dispatch_hits)
        @guard = guard_hits
        @dispatch = dispatch_hits
      end

      def ranked
        ess = Hash.new(0)
        @dispatch.each { |h| ess[h.contract] += 1 }

        rows = @guard.group_by(&:contract).map do |contract, hs|
          {
            contract: contract,
            decisions: hs.size,
            essential: ess[contract],
            methods: hs.map { |h| [h.file, h.defn] }.uniq.size,
            sites: hs.map { |h| "#{h.file}:#{h.defn}:#{h.line}" },
            spans: hs.to_h { |h| ["#{h.file}:#{h.defn}:#{h.line}", h.span] }
          }
        end
        named = rows.reject { |r| r[:contract] == "~local" }
                    .sort_by { |r| [-r[:decisions], -r[:methods]] }
        local = rows.select { |r| r[:contract] == "~local" }
        named + local
      end
    end
  end
end
