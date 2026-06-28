# frozen_string_literal: true

require "json"

module SlopCop
  # Normalized mutation-testing evidence keyed by source file and method.
  #
  # Expected input:
  # {
  #   "schema": "mutant-facts/v1",
  #   "subjects": [
  #     { "file": "src/x.rb", "method": "Owner#call",
  #       "kill_rate": 82.4, "gate_status": "advisory" }
  #   ]
  # }
  module MutationFacts
    Fact = Struct.new(:file, :method, :kill_rate, :gate_status, keyword_init: true) do
      def weak?
        return true if kill_rate.nil?
        return true if kill_rate.to_f < 60.0

        %w[advisory soft open failed failing missing none unknown].include?(gate_status.to_s.downcase)
      end

      def moderate?
        !weak? && !strong?
      end

      def strong?
        kill_rate.to_f >= 90.0 &&
          %w[hard hard_gate hard-gated enforced required pass passed clean].include?(gate_status.to_s.downcase)
      end

      def summary
        rate = kill_rate.nil? ? "no mutation" : "#{format('%0.1f', kill_rate.to_f)}% killed"
        status = gate_status.to_s.empty? ? "unknown gate" : gate_status
        "#{rate} / #{status}"
      end
    end

    Index = Struct.new(:facts, :active, :label, keyword_init: true) do
      def active?
        active
      end

      def empty?
        facts.empty?
      end

      def lookup(file, method)
        candidates_for(file, method).each do |key|
          fact = facts[key]
          return fact if fact
        end
        file_default(file) || global_unique(method)
      end

      def status_for(file, method)
        lookup(file, method) || (active? ? MutationFacts.missing_fact(file, method) : nil)
      end

      private

      def candidates_for(file, method)
        rel = MutationFacts.clean_file(file)
        methods = MutationFacts.method_aliases(method)
        methods.map { |name| [rel, name] }
      end

      def file_default(file)
        facts[[MutationFacts.clean_file(file), MutationFacts::FILE_DEFAULT]]
      end

      def global_unique(method)
        MutationFacts.method_aliases(method).each do |name|
          fact = facts[[MutationFacts::GLOBAL_FILE, name]]
          return fact if fact
        end
        nil
      end
    end

    FILE_DEFAULT = "*"
    GLOBAL_FILE = "\0global"

    module_function

    def empty(active: false, label: nil)
      Index.new(facts: {}, active: active, label: label)
    end

    def load_from_data(payload, label:)
      return empty if payload.nil? || !payload["active"]

      subjects = Array(payload["subjects"])
      facts = {}
      subjects.each do |subject|
        fact = Fact.new(
          file: subject["file"],
          method: subject["method"],
          kill_rate: subject["kill_rate"],
          gate_status: subject["gate_status"]
        )
        method_aliases(fact.method).each do |method|
          facts[[fact.file, method]] ||= fact
        end
        facts[[fact.file, FILE_DEFAULT]] ||= fact if wildcard_method?(fact.method)
      end
      add_global_unique_methods!(facts)
      Index.new(facts: facts, active: true, label: label)
    end

    def load(path, root:)
      return empty unless path && ::File.file?(path)

      data = JSON.parse(::File.read(path))
      subjects = Array(data["subjects"] || data[:subjects])
      root = ::File.expand_path(root)
      facts = {}
      subjects.each do |subject|
        fact = fact_from(subject, root: root)
        next unless fact

        method_aliases(fact.method).each do |method|
          facts[[fact.file, method]] ||= fact
        end
        facts[[fact.file, FILE_DEFAULT]] ||= fact if wildcard_method?(fact.method)
      end
      add_global_unique_methods!(facts)
      Index.new(facts: facts, active: true, label: ::File.basename(path))
    rescue JSON::ParserError, SystemCallError
      empty
    end

    def fact_from(subject, root:)
      file = normalize_file(subject["file"] || subject[:file], root: root)
      method = (subject["method"] || subject[:method]).to_s
      return nil if file.empty? || method.empty?

      Fact.new(
        file: file,
        method: method,
        kill_rate: parse_kill_rate(subject["kill_rate"] || subject[:kill_rate]),
        gate_status: (subject["gate_status"] || subject[:gate_status]).to_s
      )
    end

    def missing_fact(file, method)
      Fact.new(file: clean_file(file), method: method.to_s, kill_rate: nil, gate_status: "missing")
    end

    def parse_kill_rate(value)
      return nil if value.nil?

      text = value.to_s.delete_suffix("%")
      rate = Float(text)
      rate <= 1.0 ? rate * 100.0 : rate
    rescue ArgumentError
      nil
    end

    def normalize_file(file, root:)
      raw = file.to_s
      return "" if raw.empty?

      rootp = ::File.expand_path(root).chomp("/") + "/"
      abs = ::File.absolute_path?(raw) ? ::File.expand_path(raw) : ::File.expand_path(raw, root)
      clean_file(abs.start_with?(rootp) ? abs[rootp.length..] : raw)
    end

    def clean_file(file)
      file.to_s.tr("\\", "/").sub(%r{\A\./}, "")
    end

    def method_aliases(method)
      raw = method.to_s
      aliases = [raw]
      aliases << raw.split("#").last if raw.include?("#")
      aliases << raw.split(".").last if raw.include?(".")
      aliases << raw.split("::").last if raw.include?("::")
      aliases.reject(&:empty?).uniq
    end

    def wildcard_method?(method)
      method.to_s.end_with?("*")
    end

    def add_global_unique_methods!(facts)
      grouped = Hash.new { |h, k| h[k] = [] }
      facts.each do |(file, method), fact|
        next if file == GLOBAL_FILE || method == FILE_DEFAULT || wildcard_method?(method)

        grouped[method] << fact
      end
      grouped.each do |method, candidates|
        unique = candidates.uniq { |fact| [fact.file, fact.method] }
        facts[[GLOBAL_FILE, method]] = unique.first if unique.one?
      end
    end

    def risk_multiplier(fact, active:, complexity:, history:, coverage_gap:)
      return 1.0 unless active

      fact ||= missing_fact("", "")
      high_complexity = complexity.to_f >= 5.0
      high_history = history.to_f >= 0.5
      high_gap = coverage_gap.to_f >= 0.8

      if fact.strong?
        high_complexity && high_history ? 0.9 : 0.75
      elsif fact.moderate?
        1.1
      elsif high_complexity && high_history && high_gap
        1.9
      elsif high_complexity && high_history
        1.7
      elsif high_history || high_complexity
        1.45
      else
        1.25
      end
    end

    def profile(fact, active:, complexity:, history:, coverage_gap:)
      return nil unless active

      fact ||= missing_fact("", "")
      high_complexity = complexity.to_f >= 5.0
      high_history = history.to_f >= 0.5
      high_gap = coverage_gap.to_f >= 0.8

      if fact.weak? && high_complexity && high_history && high_gap
        "lurking disaster"
      elsif fact.strong? && high_complexity
        "hardened veteran"
      elsif fact.weak? && high_history
        "fragile newcomer"
      elsif fact.weak?
        "weak verification"
      elsif fact.moderate?
        "partial verification"
      else
        "load-bearing tests"
      end
    end
  end
end
