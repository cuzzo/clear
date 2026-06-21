# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # Decision-pressure: attribute defensive type/nil guards to the
  # canonical root contract their subject comes from, then rank contracts
  # by how many re-derived decisions they drive.
  class DecisionPressure
    TRANSIENT_NOARG_MIDS = %w[pop shift].freeze
    Hit = Struct.new(:contract, :file, :defn, :line, :span,
                     keyword_init: true)

    def self.scan(files)
      guard = []
      dispatch = []
      files.each do |file|
        document = Syntax.parse(file, parser: "tree_sitter")
        assignment_maps = document.local_methods.to_h do |method|
          [method.name, build_assignment_map(document, method)]
        end

        document.call_sites.each do |call|
          next if call.receiver.to_s.empty?

          asgmap = assignment_maps.fetch(call.function, {})
          if eliminable_guard?(document, call)
            contract = contract_of(call.receiver, asgmap)
            guard << hit(contract, call) if contract
          elsif essential_dispatch?(call)
            contract = contract_of(call.receiver, asgmap)
            dispatch << hit(contract, call) if contract
          end
        end
        document.semantic_effect_sites.each do |effect|
          next unless effect.kind.to_s == "eliminable_guard"

          asgmap = assignment_maps.fetch(effect.function, {})
          contract = contract_of(effect.detail, asgmap)
          guard << hit(contract, effect) if contract
        end
      end
      guard.uniq! { |hit| [hit.contract, hit.file, hit.defn, hit.line] }
      Report.new(guard, dispatch)
    end

    def self.eliminable_guard?(document, call)
      Syntax.guard_mid?(document.language, call.message) || call.safe_navigation
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

    def self.build_assignment_map(document, method)
      document.local_contract_assignments(method).transform_values do |source|
        contract_of(source, {})
      end.compact
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
            sites: hs.sort_by { |h| [h.file.to_s, h.line.to_i, h.defn.to_s] }
                     .map { |h| "#{h.file}:#{h.defn}:#{h.line}" },
            spans: hs.to_h { |h| ["#{h.file}:#{h.defn}:#{h.line}", h.span] }
          }
        end
        named = rows.reject { |r| r[:contract] == "~local" }
                    .sort_by { |r| [-r[:decisions], -r[:methods], r[:contract].to_s] }
        local = rows.select { |r| r[:contract] == "~local" }
        named + local
      end
    end
  end
end
