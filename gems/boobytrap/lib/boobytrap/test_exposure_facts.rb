# frozen_string_literal: true

require "json"
require "set"

module Boobytrap
  # Normalized per-test exposure facts. This is intentionally separate
  # from coverage data: coverage inputs usually aggregate hits, while
  # this side input preserves named test identity, test type, and
  # mutation status.
  module TestExposureFacts
    Hit = Struct.new(:test_id, :test_type, :mutation_status,
                     :line, :branch_id, keyword_init: true)

    class Fact
      attr_reader :file, :method, :function_tests, :line_tests, :branch_tests

      def initialize(file:, method:)
        @file = TestExposureFacts.clean_file(file)
        @method = method.to_s
        @function_tests = []
        @line_tests = Hash.new { |h, k| h[k] = [] }
        @branch_tests = Hash.new { |h, k| h[k] = [] }
      end

      def add_function_hit(hit)
        @function_tests << hit
      end

      def add_line_hit(line, hit)
        @line_tests[line.to_i] << hit if line.to_i.positive?
      end

      def add_branch_hit(branch_id, hit)
        key = branch_id.to_s.empty? ? "line:#{hit.line}" : branch_id.to_s
        @branch_tests[key] << hit unless key.empty?
      end

      def merge!(other)
        other.function_tests.each { |hit| add_function_hit(hit) }
        other.line_tests.each { |line, hits| hits.each { |hit| add_line_hit(line, hit) } }
        other.branch_tests.each { |id, hits| hits.each { |hit| add_branch_hit(id, hit) } }
        self
      end

      def empty?
        all_hits.empty?
      end

      def missing?
        empty?
      end

      def distinct_test_count
        test_ids.size
      end

      def tested_line_count
        line_tests.count { |_, hits| hits.any? }
      end

      def tested_branch_count
        branch_tests.count { |_, hits| hits.any? }
      end

      def test_type_counts
        counts = Hash.new { |h, k| h[k] = Set.new }
        all_hits.each do |hit|
          counts[normalized_test_type(hit)] << hit.test_id
        end
        counts.transform_values(&:size).sort.to_h
      end

      def mutant_verified_test_count
        all_hits.select { |hit| mutation_status?(hit) }.map(&:test_id).uniq.size
      end

      def mutant_killed_test_count
        all_hits.select { |hit| killed_status?(hit) }.map(&:test_id).uniq.size
      end

      def mutant_survived_test_count
        all_hits.select { |hit| survived_status?(hit) }.map(&:test_id).uniq.size
      end

      def summary
        return "no named tests" if distinct_test_count.zero?

        type_text = test_type_counts.map { |type, count| "#{type}=#{count}" }.join("/")
        mutant = "mutant killed #{mutant_killed_test_count}/#{mutant_verified_test_count}"
        "#{distinct_test_count} tests; #{type_text}; #{mutant}; " \
          "lines=#{tested_line_count}; branches=#{tested_branch_count}"
      end

      private

      def all_hits
        function_tests + line_tests.values.flatten + branch_tests.values.flatten
      end

      def test_ids
        all_hits.map(&:test_id).reject(&:empty?).uniq
      end

      def normalized_test_type(hit)
        type = hit.test_type.to_s.strip
        type.empty? ? "unknown" : type
      end

      def mutation_status?(hit)
        status = hit.mutation_status.to_s.downcase
        !status.empty? && !%w[none no false unverified].include?(status)
      end

      def killed_status?(hit)
        %w[killed kill pass passed hard hard-gated].include?(hit.mutation_status.to_s.downcase)
      end

      def survived_status?(hit)
        %w[survived survive timeout timedout error failed failing].include?(
          hit.mutation_status.to_s.downcase
        )
      end
    end

    Index = Struct.new(:method_facts, :line_facts, :branch_facts,
                       :active, :label, keyword_init: true) do
      def active?
        active
      end

      def empty?
        method_facts.empty? && line_facts.empty? && branch_facts.empty?
      end

      def status_for(file, method, first_line: nil, last_line: nil)
        file = TestExposureFacts.clean_file(file)
        fact = Fact.new(file: file, method: method)
        TestExposureFacts.method_aliases(method).each do |name|
          existing = method_facts[[file, name]]
          fact.merge!(existing) if existing
        end
        if first_line && last_line
          (first_line.to_i..last_line.to_i).each do |line|
            Array(line_facts[[file, line]]).each { |hit| fact.add_line_hit(line, hit) }
          end
          branch_facts.each do |(branch_file, _branch_id, line), hits|
            next unless branch_file == file
            next unless line.to_i >= first_line.to_i && line.to_i <= last_line.to_i

            hits.each { |hit| fact.add_branch_hit(hit.branch_id, hit) }
          end
        end
        return fact unless fact.empty?

        active? ? Fact.new(file: file, method: method) : nil
      end
    end

    module_function

    def empty(active: false, label: nil)
      Index.new(
        method_facts: {},
        line_facts: Hash.new { |h, k| h[k] = [] },
        branch_facts: Hash.new { |h, k| h[k] = [] },
        active: active,
        label: label
      )
    end

    def load_from_data(payload, label:)
      return empty if payload.nil?

      index = empty(active: true, label: label)
      (payload["method_hits"] || []).each do |entry|
        hit = hit_from_payload(entry["hit"])
        add_method_hit!(index, entry["file"], entry["method"], hit)
      end
      (payload["line_hits"] || []).each do |entry|
        hit = hit_from_payload(entry["hit"])
        add_line_hit!(index, entry["file"], entry["line"], hit)
      end
      (payload["branch_hits"] || []).each do |entry|
        hit = hit_from_payload(entry["hit"])
        add_branch_hit!(index, entry["file"], entry["branch_id"], hit)
      end
      index
    end

    def hit_from_payload(entry)
      Hit.new(
        test_id: entry["test_id"].to_s,
        test_type: entry["test_type"].to_s,
        mutation_status: entry["mutation_status"].to_s,
        line: entry["line"].to_i,
        branch_id: entry["branch_id"].to_s
      )
    end

    def load(path, root:)
      return empty unless path && ::File.file?(path)

      data = JSON.parse(::File.read(path))
      index = empty(active: true, label: ::File.basename(path))
      root = ::File.expand_path(root)
      Array(data["hits"] || data[:hits]).each do |entry|
        add_flat_hit!(index, entry, root: root)
      end
      Array(data["files"] || data[:files]).each do |file_entry|
        add_file_entry!(index, file_entry, root: root)
      end
      index
    rescue JSON::ParserError, SystemCallError
      empty
    end

    def add_flat_hit!(index, entry, root:)
      file = normalize_file(entry["file"] || entry[:file], root: root)
      return if file.empty?

      method = method_name(entry)
      hit = hit_from(entry)
      add_method_hit!(index, file, method, hit) unless method.empty?
      add_line_hit!(index, file, hit.line, hit)
      add_branch_hit!(index, file, hit.branch_id, hit)
    end

    def add_file_entry!(index, file_entry, root:)
      file = normalize_file(file_entry["file"] || file_entry[:file], root: root)
      return if file.empty?

      Array(file_entry["functions"] || file_entry[:functions]).each do |fn|
        method = (fn["name"] || fn[:name] || fn["method"] || fn[:method]).to_s
        Array(fn["tests"] || fn[:tests]).each do |test|
          add_method_hit!(index, file, method, hit_from(test)) unless method.empty?
        end
      end
      Array(file_entry["lines"] || file_entry[:lines]).each do |line_entry|
        line = (line_entry["line"] || line_entry[:line]).to_i
        Array(line_entry["tests"] || line_entry[:tests]).each do |test|
          add_line_hit!(index, file, line, hit_from(test, line: line))
        end
      end
      Array(file_entry["branches"] || file_entry[:branches]).each do |branch_entry|
        branch_id = branch_entry["branch_id"] || branch_entry[:branch_id] ||
                    branch_entry["id"] || branch_entry[:id]
        line = (branch_entry["line"] || branch_entry[:line]).to_i
        Array(branch_entry["tests"] || branch_entry[:tests]).each do |test|
          add_branch_hit!(index, file, branch_id, hit_from(test, line: line, branch_id: branch_id))
        end
      end
    end

    def add_method_hit!(index, file, method, hit)
      method_aliases(method).each do |name|
        key = [file, name]
        index.method_facts[key] ||= Fact.new(file: file, method: name)
        index.method_facts[key].add_function_hit(hit)
      end
    end

    def add_line_hit!(index, file, line, hit)
      return unless line.to_i.positive?

      index.line_facts[[file, line.to_i]] << hit
    end

    def add_branch_hit!(index, file, branch_id, hit)
      return if branch_id.to_s.empty? && !hit.line.to_i.positive?

      key = [file, branch_id.to_s, hit.line.to_i]
      index.branch_facts[key] << hit
    end

    def hit_from(entry, line: nil, branch_id: nil)
      Hit.new(
        test_id: (entry["test_id"] || entry[:test_id] || entry["id"] || entry[:id]).to_s,
        test_type: (entry["test_type"] || entry[:test_type] || entry["type"] || entry[:type]).to_s,
        mutation_status: (
          entry["mutation_status"] || entry[:mutation_status] ||
            entry["mutant_status"] || entry[:mutant_status] ||
            entry["mutation"] || entry[:mutation]
        ).to_s,
        line: (line || entry["line"] || entry[:line]).to_i,
        branch_id: (branch_id || entry["branch_id"] || entry[:branch_id]).to_s
      )
    end

    def method_name(entry)
      (entry["function"] || entry[:function] || entry["method"] || entry[:method] ||
        entry["defn"] || entry[:defn]).to_s
    end

    def risk_multiplier(fact, active:, complexity:, history:, coverage_gap:)
      return 1.0 unless active

      fact ||= Fact.new(file: "", method: "")
      high_risk_shape = complexity.to_f >= 5.0 || history.to_f >= 0.5 || coverage_gap.to_f >= 0.8
      return high_risk_shape ? 1.15 : 1.05 if fact.distinct_test_count.zero?

      killed = fact.mutant_killed_test_count
      tests = fact.distinct_test_count
      types = fact.test_type_counts.size
      return 0.55 if killed >= 3
      return 0.70 if killed.positive?
      return 0.80 if tests >= 5 && types >= 2
      return 0.90 if tests >= 2

      0.98
    end

    def profile(fact, active:)
      return nil unless active

      fact ||= Fact.new(file: "", method: "")
      return "unobserved by named tests" if fact.distinct_test_count.zero?
      return "mutation-killed exposure" if fact.mutant_killed_test_count.positive?
      return "diverse named coverage" if fact.test_type_counts.size >= 2
      return "named coverage" if fact.distinct_test_count >= 2

      "thin named coverage"
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
  end
end
