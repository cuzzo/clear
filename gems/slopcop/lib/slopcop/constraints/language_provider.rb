# frozen_string_literal: true

require "set"

require_relative "finding"

module SlopCop
  module Constraints
    module LanguageProvider
      module_function

      def findings(provider, repo:, additions:, evidence:)
        repo = File.expand_path(repo)
        changed_files = additions.keys.select { |path| provider.source_path?(path) }
        return [] if changed_files.empty?

        hazards = provider.scan_hazards(repo: repo, paths: changed_files)

        hazards.each_with_object([]) do |hazard, out|
          path = hazard[:path] || hazard["path"]
          lines = additions[path]
          next unless lines

          changed = lines.to_set
          line = hazard[:line] || hazard["line"]
          next unless changed.include?(line)
          next if covered?(evidence, hazard)

          req_ev = hazard[:required_evidence] || hazard["required_evidence"]
          out << Finding.new(
            path: path,
            line: line,
            rule_id: provider.rule_id_for(req_ev),
            message: "changed #{hazard[:label] || hazard["label"]} has no #{req_ev} coverage evidence",
            source: hazard[:source] || hazard["source"],
            hazard_type: hazard[:hazard_type] || hazard["hazard_type"],
            required_evidence: req_ev,
            severity: "warning"
          )
        end
      end

      def scan_hazards(provider, repo:, paths: nil)
        repo = File.expand_path(repo)
        files = if paths && !Array(paths).empty?
                  Array(paths).select { |path| provider.source_path?(path) }
                else
                  Dir.chdir(repo) { Dir["**/*"] }.select { |path| File.file?(File.join(repo, path)) && provider.source_path?(path) }
                end
        files.flat_map do |path|
          provider.scan_file(path, source_contents(repo, path))
        end.sort_by { |site| [site[:path], site[:line], site[:hazard_type]] }
      end

      def covered?(evidence, hazard)
        evidence_type = hazard[:required_evidence] || hazard["required_evidence"]
        return false unless evidence.known_type?(evidence_type)

        path = hazard[:path] || hazard["path"]
        line = hazard[:line] || hazard["line"]
        evidence.line_covered?(evidence_type, path, line)
      end

      def source_contents(repo, path)
        file = File.join(repo, path)
        File.file?(file) ? File.read(file) : ""
      end

      def hazard(path, line, source, hazard_type, required_evidence, label)
        {
          path: path,
          line: line,
          source: source.strip,
          hazard_type: hazard_type,
          required_evidence: required_evidence,
          label: label
        }
      end

      def c_style_code(line, in_block_comment)
        out = +""
        rest = line.to_s
        loop do
          if in_block_comment[:active]
            after = rest.split("*/", 2)[1]
            return strip_strings(out) unless after

            in_block_comment[:active] = false
            rest = after
            next
          end

          block = rest.index("/*")
          comment = rest.index("//")
          case
          when block && comment && comment < block
            out << rest[0...comment]
            return strip_strings(out)
          when block
            out << rest[0...block]
            rest = rest[(block + 2)..].to_s
            in_block_comment[:active] = true
          when comment
            out << rest[0...comment]
            return strip_strings(out)
          else
            out << rest
            return strip_strings(out)
          end
        end
      end

      def strip_strings(code)
        code.to_s.gsub(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/, '""')
      end

      def excluded_path?(path, dirs:, file_suffixes: [])
        parts = path.split("/")
        return true if parts.any? { |part| dirs.include?(part) || part.start_with?(".") }

        file_suffixes.any? { |suffix| path.end_with?(suffix) }
      end

      def token?(code, token)
        code.match?(/(?<![A-Za-z0-9_])#{Regexp.escape(token)}(?![A-Za-z0-9_])/)
      end

      def any_include?(code, needles)
        needles.any? { |needle| code.include?(needle) }
      end
    end
  end
end
