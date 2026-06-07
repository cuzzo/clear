# frozen_string_literal: true

require "optparse"
require "rexml/document"

module ZigCoverageVisibility
  ROOT = File.expand_path("..", __dir__)
  SOURCE_DIRS = %w[zig/runtime zig/lib zig/experimental].freeze
  TEST_FILE_RE = %r{
    (?:^|/)testing/|(?:^|/)
    (?:
      all-tests\.zig|
      all-fuzz\.zig|
      \._clear_cov_[^/]*\.zig|
      vopr-[^/]*\.zig|
      loom-[^/]*\.zig|
      [^/]*-test\.zig|
      [^/]*-vopr\.zig|
      [^/]*-loom\.zig|
      [^/]*(?:_|-)bench\.zig|
      [^/]*-benchmark-test\.zig|
      test_[^/]*\.zig
    )\z
  }x.freeze

  Function = Struct.new(:name, :start_line, :end_line, keyword_init: true)
  FunctionReport = Struct.new(
    :name,
    :start_line,
    :end_line,
    :code_lines,
    :tracked_lines,
    :covered_lines,
    :missed_lines,
    :executable_no_data_lines,
    :sample_line,
    :sample_source,
    keyword_init: true,
  )
  FileReport = Struct.new(
    :file,
    :source_lines,
    :code_lines,
    :tracked_lines,
    :covered_lines,
    :missed_lines,
    :no_data_code_lines,
    :expected_no_data_lines,
    :executable_no_data_lines,
    :zero_tracked_functions,
    :missed_functions,
    :partial_visibility_functions,
    keyword_init: true,
  )

  class CoverageMap
    attr_reader :paths

    def initialize(paths)
      @paths = paths.flat_map { |path| expand_coverage_path(path) }.uniq.sort
      @hits_by_file = Hash.new { |h, k| h[k] = {} }
      load!
    end

    def hits_for(source_file)
      candidates = normalized_candidates(source_file)
      merged = {}
      candidates.each do |candidate|
        @hits_by_file.fetch(candidate, {}).each do |line, hits|
          merged[line] = [merged.fetch(line, 0), hits].max
        end
      end
      merged
    end

    private

    def expand_coverage_path(path)
      return Dir[File.join(path, "**", "cobertura.xml")] if File.directory?(path)

      [path]
    end

    def load!
      @paths.each do |path|
        next unless File.file?(path)

        doc = REXML::Document.new(File.read(path))
        REXML::XPath.each(doc, "//class") do |klass|
          filename = normalize_coverage_filename(klass.attributes["filename"].to_s)
          next if filename.empty?

          REXML::XPath.each(klass, "lines/line") do |line|
            number = line.attributes["number"].to_i
            hits = line.attributes["hits"].to_i
            current = @hits_by_file[filename].fetch(number, 0)
            @hits_by_file[filename][number] = [current, hits].max
          end
        end
      end
    end

    def normalize_coverage_filename(filename)
      filename.sub(%r{\A\./}, "").sub(%r{\A/+}, "").sub(%r{\Azig/}, "")
    end

    def normalized_candidates(source_file)
      rel = source_file.sub(%r{\A\./}, "").sub(%r{\A/+}, "")
      no_zig = rel.sub(%r{\Azig/}, "")
      [rel, no_zig].uniq
    end
  end

  class Analyzer
    attr_reader :coverage

    def initialize(coverage)
      @coverage = coverage
    end

    def self.prod_files(root: ROOT, source_dirs: SOURCE_DIRS)
      source_dirs.flat_map do |dir|
        Dir[File.join(root, dir, "**", "*.zig")]
      end
        .map { |path| path.sub(%r{\A#{Regexp.escape(root)}/?}, "") }
        .reject { |path| test_file?(path) }
        .sort
    end

    def self.test_file?(path)
      path.match?(TEST_FILE_RE)
    end

    def analyze_file(file, root: ROOT)
      source_path = File.join(root, file)
      source_path = File.join(root, "zig", file) unless File.file?(source_path)
      lines = File.readlines(source_path)
      hits = coverage.hits_for(file)
      code_line_numbers = (1..lines.length).select { |line| code_line?(lines[line - 1]) }
      tracked_line_numbers = hits.keys
      no_data_code = code_line_numbers.reject { |line| hits.key?(line) }
      expected_no_data = no_data_code.select { |line| expected_no_data_line?(lines[line - 1]) }
      executable_no_data = no_data_code - expected_no_data
      functions = function_ranges(lines).map do |fn|
        function_report(fn, lines, hits)
      end

      FileReport.new(
        file: file.sub(%r{\Azig/}, "zig/"),
        source_lines: lines.length,
        code_lines: code_line_numbers.length,
        tracked_lines: tracked_line_numbers.length,
        covered_lines: hits.values.count(&:positive?),
        missed_lines: hits.values.count(&:zero?),
        no_data_code_lines: no_data_code.length,
        expected_no_data_lines: expected_no_data.length,
        executable_no_data_lines: executable_no_data.length,
        zero_tracked_functions: functions.select { |fn| fn.tracked_lines.zero? && fn.executable_no_data_lines.positive? },
        missed_functions: functions.select { |fn| fn.tracked_lines.positive? && fn.missed_lines.positive? },
        partial_visibility_functions: functions.select { |fn| fn.tracked_lines.positive? && fn.executable_no_data_lines.positive? },
      )
    end

    def self.markdown(reports, coverage_paths:, limit: 20)
      out = []
      out << "# Zig Coverage Visibility Audit"
      out << ""
      out << "This report audits what kcov can see in production Zig files. It does not modify Codecov input and does not treat every source line as executable. Instead, it flags production functions whose executable-looking bodies have no kcov denominator, plus functions with tracked misses."
      out << ""
      out << "- Coverage XML inputs: #{coverage_paths.length}"
      out << "- Files audited: #{reports.length}"
      out << "- Total tracked lines: #{reports.sum(&:tracked_lines)}"
      out << "- Total covered tracked lines: #{reports.sum(&:covered_lines)}"
      out << "- Total missed tracked lines: #{reports.sum(&:missed_lines)}"
      out << "- Total executable-looking no-data lines: #{reports.sum(&:executable_no_data_lines)}"
      out << ""
      out << "## Summary"
      out << ""
      out << "| File | Tracked | Covered | Missed | Executable no-data | Zero-tracked fns | Missed fns |"
      out << "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"
      reports.each do |report|
        out << "| `#{report.file}` | #{report.tracked_lines} | #{report.covered_lines} | #{report.missed_lines} | #{report.executable_no_data_lines} | #{report.zero_tracked_functions.length} | #{report.missed_functions.length} |"
      end
      out << ""

      reports.each do |report|
        out << "## #{report.file}"
        out << ""
        out << "- Source lines: #{report.source_lines}"
        out << "- Simple code lines: #{report.code_lines}"
        out << "- kcov tracked lines: #{report.tracked_lines}"
        out << "- kcov covered/missed: #{report.covered_lines}/#{report.missed_lines}"
        out << "- No-data code lines: #{report.no_data_code_lines} (#{report.expected_no_data_lines} expected declaration/comptime/type lines, #{report.executable_no_data_lines} executable-looking lines)"
        out << ""
        append_function_table(out, "Zero-Tracked Executable-Looking Functions", report.zero_tracked_functions, limit)
        append_function_table(out, "Tracked Functions With Misses", report.missed_functions.sort_by { |fn| [-fn.missed_lines, fn.start_line] }, limit)
        append_function_table(out, "Tracked Functions With Partial Visibility", report.partial_visibility_functions.sort_by { |fn| [-fn.executable_no_data_lines, fn.start_line] }, limit)
      end

      out.join("\n")
    end

    def self.append_function_table(out, title, functions, limit)
      out << "### #{title}"
      out << ""
      if functions.empty?
        out << "None."
        out << ""
        return
      end

      out << "| Function | Lines | Tracked | Covered | Missed | Exec no-data | Sample |"
      out << "| --- | ---: | ---: | ---: | ---: | ---: | --- |"
      functions.first(limit).each do |fn|
        sample = fn.sample_line ? "`L#{fn.sample_line}: #{escape_markdown(fn.sample_source)}`" : ""
        out << "| `#{fn.name}` | #{fn.start_line}-#{fn.end_line} | #{fn.tracked_lines} | #{fn.covered_lines} | #{fn.missed_lines} | #{fn.executable_no_data_lines} | #{sample} |"
      end
      if functions.length > limit
        out << ""
        out << "_#{functions.length - limit} more omitted by `--limit #{limit}`._"
      end
      out << ""
    end

    def self.escape_markdown(text)
      text.to_s.gsub("|", "\\|")
    end

    private

    def function_report(fn, lines, hits)
      range = (fn.start_line..fn.end_line).to_a
      code_lines = range.select { |line| code_line?(lines[line - 1]) }
      tracked = range.select { |line| hits.key?(line) }
      executable_no_data = code_lines.reject do |line|
        hits.key?(line) || expected_no_data_line?(lines[line - 1])
      end
      sample_line = executable_no_data.first
      FunctionReport.new(
        name: fn.name,
        start_line: fn.start_line,
        end_line: fn.end_line,
        code_lines: code_lines.length,
        tracked_lines: tracked.length,
        covered_lines: tracked.count { |line| hits[line].positive? },
        missed_lines: tracked.count { |line| hits[line].zero? },
        executable_no_data_lines: executable_no_data.length,
        sample_line: sample_line,
        sample_source: sample_line && lines[sample_line - 1].strip,
      )
    end

    def code_line?(line)
      stripped = line.strip
      !stripped.empty? && !stripped.start_with?("//")
    end

    def expected_no_data_line?(line)
      stripped = line.strip
      return true unless code_line?(line)
      return true if stripped.match?(/\A(?:pub\s+)?const\s+\w+\s*=\s*@import\(/)
      return true if stripped.match?(/\A(?:pub\s+)?const\s+\w+\s*=\s*(?:struct|enum|union)\b/)
      return true if stripped.match?(/\A(?:pub\s+)?const\s+\w+\s*:\s*type\s*=/)
      return true if stripped.match?(/\A(?:pub\s+)?const\s+\w+\s*=\s*@This\(\);?\z/)
      return true if stripped.match?(/\A(?:pub\s+)?const\s+\w+\s*=\s*@import\([^)]*\)\.\w+\s*;?\z/)
      return true if stripped.match?(/\A(?:pub\s+)?const\s+\w+\s*=\s*[^;]*\.(?:Runtime|Task|Fiber|WaitGroup|Semaphore|EbrContext|Scheduler|FsmTask|FsmStatus|YieldReason)\s*;?\z/)
      return true if stripped.match?(/\A(?:pub\s+)?extern\b/)
      return true if stripped.match?(/\A(?:pub\s+)?threadlocal\s+var\s+/)
      return true if stripped.match?(/\A(?:pub\s+)?var\s+\w[\w\s:.*?\[\]]*=\s*(?:false|true|null|undefined|\.empty|\.{})\s*;?\z/)
      return true if stripped.match?(/\A(?:pub\s+)?fn\s+\w+/)
      return true if stripped.match?(/\A(?:pub\s+)?(?:inline\s+)?fn\s+\w+/)
      return true if stripped.match?(/\A(?:pub\s+)?(?:noinline\s+)?fn\s+\w+/)
      return true if stripped.match?(/\A(?:pub\s+)?(const|var)\s+\w+\s*:\s*[^=;]+;?\z/)
      return true if stripped.match?(/\Acomptime\s+\w+\s*:\s*type,?\z/)
      return true if stripped.match?(/\A\w[\w_]*\s*:\s*[^=]+,\z/)
      return true if stripped.match?(/\A\w[\w_]*\s*:\s*[^=]+=.*,\z/)
      return true if stripped.match?(/\A[{}]?[;,]?\z/)
      return true if stripped.match?(/\A};?\z/)
      return true if stripped.match?(/\A}\s*(?:else|\)|,|;)?\z/)

      false
    end

    def function_ranges(lines)
      ranges = []
      current = nil
      lines.each_with_index do |line, idx|
        line_number = idx + 1
        if current.nil? && (match = line.match(/\bfn\s+([A-Za-z_]\w*)\s*\(/))
          current = { name: match[1], start: line_number, depth: 0 }
        end
        next unless current

        scrubbed = strip_line_comment(line)
        scrubbed.each_char do |ch|
          current[:depth] += 1 if ch == "{"
          current[:depth] -= 1 if ch == "}"
        end
        if current[:depth].zero? && line_number > current[:start]
          ranges << Function.new(name: current[:name], start_line: current[:start], end_line: line_number)
          current = nil
        end
      end
      ranges
    end

    def strip_line_comment(line)
      line.sub(%r{//.*\z}, "")
    end
  end

  class CLI
    def self.run(argv)
      options = {
        root: ROOT,
        files: [],
        coverage: [],
        all_prod: false,
        limit: 20,
        report: nil,
      }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby tools/zig_coverage_visibility.rb --coverage PATH [--file zig/runtime/foo.zig | --all-prod]"
        opts.on("--coverage PATH", "Cobertura XML file or directory containing cobertura.xml files") { |v| options[:coverage] << v }
        opts.on("--file PATH", "Production Zig source file to audit") { |v| options[:files] << v }
        opts.on("--all-prod", "Audit all production Zig files under zig/runtime, zig/lib, and zig/experimental") { options[:all_prod] = true }
        opts.on("--limit N", Integer, "Rows per table (default: 20)") { |v| options[:limit] = v }
        opts.on("--report PATH", "Write Markdown report to PATH instead of stdout") { |v| options[:report] = v }
        opts.on("--root PATH", "Repository root (default: current repository)") { |v| options[:root] = File.expand_path(v) }
      end
      parser.parse!(argv)
      raise OptionParser::MissingArgument, "--coverage is required" if options[:coverage].empty?

      files = if options[:all_prod] || options[:files].empty?
        Analyzer.prod_files(root: options[:root])
      else
        options[:files].map { |path| path.sub(%r{\A\./}, "") }
      end
      coverage = CoverageMap.new(options[:coverage].map { |path| File.expand_path(path, options[:root]) })
      analyzer = Analyzer.new(coverage)
      reports = files.map { |file| analyzer.analyze_file(file, root: options[:root]) }
      markdown = Analyzer.markdown(reports, coverage_paths: coverage.paths, limit: options[:limit])
      if options[:report]
        File.write(File.expand_path(options[:report], options[:root]), markdown)
      else
        puts markdown
      end
      reports
    end
  end
end

if $PROGRAM_NAME == __FILE__
  ZigCoverageVisibility::CLI.run(ARGV)
end
