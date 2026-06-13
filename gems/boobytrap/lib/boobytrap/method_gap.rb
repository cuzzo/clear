# frozen_string_literal: true

require "json"
require "ripper"
require_relative "decomplex_risk"

module Boobytrap
  # Method-level coverage gaps from SimpleCov line + branch data.
  #
  # Boobytrap's original signal is file-level: fix-churn x branch gap.
  # This overlay answers a different triage question: "which whole
  # methods are still mostly dark, and are any of them stateful enough
  # to be risky?" It intentionally keeps method-range discovery local,
  # but delegates complexity/risk pressure to Decomplex's detector
  # score instead of maintaining a second complexity model here.
  module MethodGap
    Row = Struct.new(:file, :name, :first_line, :last_line,
                     :executable_lines, :covered_lines, :missed_lines,
                     :line_gap, :decomplex_score, :decomplex_findings,
                     :decomplex_detectors, :state_writes,
                     :uncovered_branches, :risk,
                     keyword_init: true)

    module_function

    def from_resultset(path, root:, min_lines: 5, decomplex_scores: {})
      data = JSON.parse(::File.read(path))
      coverage = merge_coverage(data)
      rootp = root.chomp("/") + "/"
      rows = []

      coverage.each do |abs, cov|
        next unless abs.start_with?(rootp) && ::File.file?(abs)

        rel = abs[rootp.length..]
        lines = cov["lines"] || []
        branch_misses = branch_misses_by_line(cov["branches"] || {})
        source_lines = ::File.readlines(abs, chomp: true)

        method_ranges_for_file(abs, source_lines).each do |m|
          exec = covered = 0
          (m[:first_line]..m[:last_line]).each do |ln|
            v = lines[ln - 1]
            next if v.nil?

            exec += 1
            covered += 1 if v.to_i.positive?
          end
          next if exec < min_lines

          missed = exec - covered
          next if missed.zero?

          body = source_lines[(m[:first_line] - 1)...m[:last_line]] || []
          state_writes = state_write_count(body)
          dark_branches = branch_misses.sum { |ln, n| m[:first_line] <= ln && ln <= m[:last_line] ? n : 0 }
          gap = missed.to_f / exec
          decomplex = decomplex_scores.fetch([rel, m[:name]], default_score)
          rows << Row.new(
            file: rel,
            name: m[:name] || "(anonymous)",
            first_line: m[:first_line],
            last_line: m[:last_line],
            executable_lines: exec,
            covered_lines: covered,
            missed_lines: missed,
            line_gap: gap,
            decomplex_score: decomplex.score,
            decomplex_findings: decomplex.findings,
            decomplex_detectors: decomplex.detectors,
            state_writes: state_writes,
            uncovered_branches: dark_branches,
            risk: risk_score(missed, gap, decomplex.score, state_writes, dark_branches)
          )
        end
      end

      rows.sort_by { |r| [-r.risk, -r.missed_lines, r.file, r.first_line] }
    end

    def from_static(files, root:, min_lines: 5, decomplex_scores: {})
      rows = []
      rootp = root.chomp("/") + "/"
      files.each do |file|
        abs = ::File.expand_path(file.start_with?("/") ? file : ::File.join(root, file))
        next unless ::File.file?(abs)
        next unless Boobytrap::DecomplexRisk.supported_source?(abs)

        rel = abs.start_with?(rootp) ? abs[rootp.length..] : abs
        source_lines = ::File.readlines(abs, chomp: true)
        branch_misses = static_branch_misses_by_line(abs)

        method_ranges_for_file(abs, source_lines).each do |m|
          exec = (m[:first_line]..m[:last_line]).count do |ln|
            executable_source_line?(source_lines[ln - 1])
          end
          next if exec < min_lines

          body = source_lines[(m[:first_line] - 1)...m[:last_line]] || []
          state_writes = state_write_count(body)
          dark_branches = branch_misses.sum { |ln, n| m[:first_line] <= ln && ln <= m[:last_line] ? n : 0 }
          decomplex = decomplex_scores.fetch([rel, m[:name]], default_score)
          rows << Row.new(
            file: rel,
            name: m[:name] || "(anonymous)",
            first_line: m[:first_line],
            last_line: m[:last_line],
            executable_lines: exec,
            covered_lines: 0,
            missed_lines: exec,
            line_gap: 1.0,
            decomplex_score: decomplex.score,
            decomplex_findings: decomplex.findings,
            decomplex_detectors: decomplex.detectors,
            state_writes: state_writes,
            uncovered_branches: dark_branches,
            risk: risk_score(exec, 1.0, decomplex.score, state_writes, dark_branches)
          )
        end
      end

      rows.sort_by { |r| [-r.risk, -r.missed_lines, r.file, r.first_line] }
    end

    def covered_files(path, root:)
      rootp = root.chomp("/") + "/"
      JSON.parse(::File.read(path)).each_value.flat_map do |entry|
        (entry["coverage"] || {}).keys
      end.uniq.filter_map do |abs|
        next unless abs.start_with?(rootp) && ::File.file?(abs)

        abs[rootp.length..]
      end
    end

    def merge_coverage(data)
      merged = {}
      data.each_value do |entry|
        (entry["coverage"] || {}).each do |abs, cov|
          next unless cov.is_a?(Hash)

          dst = (merged[abs] ||= { "lines" => [], "branches" => {} })
          merge_lines!(dst["lines"], cov["lines"] || [])
          merge_branches!(dst["branches"], cov["branches"] || {})
        end
      end
      merged
    end

    def merge_lines!(dst, src)
      src.each_with_index do |v, i|
        next if v.nil?

        dst[i] = 0 if dst[i].nil?
        dst[i] += v.to_i
      end
    end

    def merge_branches!(dst, src)
      src.each do |parent, arms|
        d = (dst[parent] ||= Hash.new(0))
        arms.each { |arm, n| d[arm] += n.to_i }
      end
    end

    def method_ranges(lines)
      toks = Ripper.lex(lines.join("\n"))
      stack = []
      ranges = []
      toks.each do |(pos, type, tok, _state)|
        line = pos[0]
        if type == :on_kw
          case tok
          when "def"
            stack << { first_line: line, name: nil }
          when "end"
            m = stack.pop
            ranges << m.merge(last_line: line) if m
          end
        elsif stack.any? && stack[-1][:name].nil? &&
              %i[on_ident on_const on_op on_kw].include?(type)
          stack[-1][:name] = tok
        end
      end
      ranges
    end

    def method_ranges_for_file(abs, lines)
      return method_ranges(lines) unless Boobytrap::DecomplexRisk.tree_sitter?
      return method_ranges(lines) unless Boobytrap::DecomplexRisk.load_decomplex_syntax
      return method_ranges(lines) unless Boobytrap::DecomplexRisk.supported_source?(abs)

      doc = Decomplex::Syntax.parse(abs, parser: "tree_sitter")
      ranges = doc.function_defs.map do |fn|
        {
          first_line: fn.span[0],
          last_line: fn.span[2],
          name: fn.name
        }
      end
      ranges.empty? ? fallback_function_ranges(lines) : ranges
    rescue LoadError, StandardError
      method_ranges(lines)
    end

    def fallback_function_ranges(lines)
      ranges = []
      lines.each_with_index do |raw, i|
        next unless (match = raw.match(/\bfn\s+([A-Za-z_]\w*)\s*\(/))

        first = i + 1
        last = find_brace_end(lines, i) || first
        ranges << { first_line: first, last_line: last, name: match[1] }
      end
      ranges
    end

    def find_brace_end(lines, start_idx)
      depth = 0
      opened = false
      lines[start_idx..].each_with_index do |raw, offset|
        raw.each_char do |ch|
          if ch == "{"
            depth += 1
            opened = true
          elsif ch == "}" && opened
            depth -= 1
            return start_idx + offset + 1 if depth <= 0
          end
        end
      end
      nil
    end

    def branch_misses_by_line(branches)
      out = Hash.new(0)
      branches.each_value do |arms|
        arms.each do |arm, count|
          next unless count.to_i.zero?

          fields = arm.gsub(/[\[\]:]/, "").split(",").map(&:strip)
          line = fields[2].to_i
          out[line] += 1 if line.positive?
        end
      end
      out
    end

    def state_write_count(lines)
      lines.count do |line|
        line.match?(/@\w+\s*(?:[+\-*\/%|&^]?=|<<)/) ||
          line.match?(/@\w+\.\w+!?[=(]/) ||
          line.match?(/\b[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+\s*(?:[+\-*\/%|&^]?=|<<)/)
      end
    end

    def static_branch_misses_by_line(abs)
      return {} unless Boobytrap::DecomplexRisk.load_decomplex_syntax

      doc = Decomplex::Syntax.parse(abs, parser: "tree_sitter")
      doc.branch_arms.each_with_object(Hash.new(0)) { |arm, out| out[arm.line] += 1 }
    rescue LoadError, StandardError
      {}
    end

    def executable_source_line?(line)
      stripped = line.to_s.strip
      return false if stripped.empty?
      return false if stripped.start_with?("#", "//", "/*", "*")
      return false if %w[end } { ) (].include?(stripped)

      true
    end

    def risk_score(missed, gap, decomplex_score, state_writes, dark_branches)
      (missed * gap) + (decomplex_score.to_f * 1.5) +
        (state_writes * 1.0) + (dark_branches * 0.5)
    end

    def default_score
      DecomplexRisk::Score.new(score: 0, findings: 0, detectors: [])
    end
  end
end
