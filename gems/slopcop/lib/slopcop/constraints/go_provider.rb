# frozen_string_literal: true

require_relative "finding"

module SlopCop
  module Constraints
    module GoProvider
      module_function

      def rules
        [
          {
            "id" => "slopcop-go-race-uncovered",
            "name" => "Go race coverage missing",
            "shortDescription" => { "text" => "Go shared-concurrency site lacks race coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Go goroutine, atomic, lock, or sync primitive was not reached by race coverage."
            },
            "defaultConfiguration" => { "level" => "warning" }
          },
          {
            "id" => "slopcop-go-concurrency-uncovered",
            "name" => "Go concurrency coverage missing",
            "shortDescription" => { "text" => "Go channel/wait site lacks concurrency coverage evidence" },
            "fullDescription" => {
              "text" => "A changed Go channel or wait-group site was not reached by concurrency coverage."
            },
            "defaultConfiguration" => { "level" => "warning" }
          }
        ]
      end

      def findings(repo:, additions:, evidence:)
        repo = File.expand_path(repo)
        additions.each_with_object([]) do |(path, lines), out|
          next unless source_path?(path)

          lines.each do |line|
            source = source_line(repo, path, line)
            next if source.empty?

            scan_line(path, line, source).each do |hazard|
              next if covered?(evidence, hazard)

              out << Finding.new(
                path: path,
                line: line,
                rule_id: rule_id_for(hazard[:required_evidence]),
                message: "changed #{hazard[:label]} has no #{hazard[:required_evidence]} coverage evidence",
                source: source.strip,
                hazard_type: hazard[:hazard_type],
                required_evidence: hazard[:required_evidence],
                severity: "warning"
              )
            end
          end
        end
      end

      def source_path?(path)
        path.end_with?(".go") && !path.end_with?("_test.go") && !path.split("/").include?("vendor")
      end

      def scan_hazards(repo:, paths: nil)
        repo = File.expand_path(repo)
        files = if paths && !Array(paths).empty?
                  Array(paths).select { |path| source_path?(path) }
                else
                  Dir.chdir(repo) { Dir["**/*.go"] }.select { |path| source_path?(path) }
                end
        files.flat_map do |path|
          File.readlines(File.join(repo, path)).each_with_index.flat_map do |source, index|
            scan_line(path, index + 1, source).map do |hazard|
              hazard.merge(path: path, line: index + 1, source: source.strip)
            end
          end
        end.sort_by { |site| [site[:path], site[:line], site[:hazard_type]] }
      end

      def scan_line(path, line, source)
        code = strip_comment(source)
        return [] if code.strip.empty?

        hazards = []
        hazards << hazard(path, line, "go_race_goroutine", "race", "goroutine launch") if goroutine_site?(code)
        hazards << hazard(path, line, "go_race_atomic", "race", "atomic operation") if atomic_site?(code)
        hazards << hazard(path, line, "go_race_lock", "race", "lock/sync primitive") if lock_site?(code)
        hazards << hazard(path, line, "go_concurrency_waitgroup", "concurrency", "wait group operation") if waitgroup_site?(code)
        hazards << hazard(path, line, "go_concurrency_channel", "concurrency", "channel operation") if channel_site?(code)
        hazards
      end

      def covered?(evidence, hazard)
        evidence_type = hazard[:required_evidence]
        return false unless evidence.known_type?(evidence_type)

        evidence.line_covered?(evidence_type, hazard[:path], hazard[:line])
      end

      def rule_id_for(required_evidence)
        required_evidence == "race" ? "slopcop-go-race-uncovered" : "slopcop-go-concurrency-uncovered"
      end

      def hazard(path, line, hazard_type, required_evidence, label)
        {
          path: path,
          line: line,
          hazard_type: hazard_type,
          required_evidence: required_evidence,
          label: label
        }
      end

      def goroutine_site?(code)
        code.lstrip.start_with?("go ") || code.include?("; go ")
      end

      def atomic_site?(code)
        code.include?("atomic.")
      end

      def lock_site?(code)
        [
          "sync.Mutex",
          "sync.RWMutex",
          "sync.Map",
          "sync.Once",
          "sync.Cond",
          ".Lock(",
          ".Unlock(",
          ".RLock(",
          ".RUnlock("
        ].any? { |needle| code.include?(needle) }
      end

      def waitgroup_site?(code)
        ["sync.WaitGroup", ".Add(", ".Done(", ".Wait("].any? { |needle| code.include?(needle) }
      end

      def channel_site?(code)
        code.include?("make(chan") ||
          code.include?("select {") ||
          code.include?("<-")
      end

      def strip_comment(source)
        source.split("//", 2).first.to_s
      end

      def source_line(repo, path, line)
        file = File.join(repo, path)
        return "" unless File.file?(file)

        File.readlines(file)[line.to_i - 1].to_s.rstrip
      end
    end
  end
end
