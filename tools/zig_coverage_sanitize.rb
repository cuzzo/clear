# frozen_string_literal: true

require "optparse"
require "open3"
require "rexml/document"
require_relative "zig_dwarf_line_audit"

module ZigCoverageSanitizer
  ROOT = File.expand_path("..", __dir__)
  RUNTIME_HEADER_SOURCE = "zig/runtime/runtime-header.zig"
  RUNTIME_HEADER_COVERAGE = "runtime/runtime-header.zig"

  FunctionRange = Struct.new(:name, :start_line, :end_line, keyword_init: true)
  Removal = Struct.new(:file, :function, :line, :hits, keyword_init: true)
  OrphanHit = Struct.new(:file, :function, :line, :hits, :reason, keyword_init: true)

  # These helpers have reproduced orphan hits whose PCs addr2line back to an
  # unrelated generic instantiation. The sanitizer only strips the orphan shape;
  # real multi-line coverage in these ranges is preserved.
  SUSPECT_RUNTIME_HEADER_FUNCTIONS = {
    "readAsync" => {
      reason: "orphan hit mapped from unrelated generated code",
      proof: :missing_symbol,
    },
    "socketAccept" => {
      reason: "orphan hit mapped from concurrentListSelect instantiation",
      proof: :missing_symbol,
    },
    "socketConnect" => {
      reason: "orphan hit mapped from unrelated generated code",
      proof: :missing_symbol,
    },
    "parseIpv4Addr" => {
      reason: "orphan hit mapped from intAdd instantiation",
      proof: :audit_only,
    },
  }.freeze

  class Error < StandardError; end

  def self.sanitize_file!(path, root: ROOT, functions: SUSPECT_RUNTIME_HEADER_FUNCTIONS, binary: nil, symbols: nil, allowed_removals: nil)
    return [] unless File.file?(path)

    source_path = File.join(root, RUNTIME_HEADER_SOURCE)
    ranges = suspect_ranges(source_path, functions)
    return [] if ranges.empty?

    symbol_names = symbols || (binary && symbol_names_for(binary))
    audit_issue_keys = nil
    xml = File.read(path)
    doc = REXML::Document.new(xml)
    removals = []

    REXML::XPath.each(doc, "//class") do |klass|
      filename = normalize_filename(klass.attributes["filename"].to_s)
      next unless filename == RUNTIME_HEADER_COVERAGE

      lines_node = REXML::XPath.first(klass, "lines")
      next unless lines_node

      ranges.each do |name, range|
        entries = line_entries(lines_node, range)
        next unless orphan_runtime_header_hit?(entries, range)
        config = functions.fetch(name)
        audit_issue_keys ||= dwarf_orphan_removal_keys(binary, root: root) if binary && config.fetch(:proof) == :audit_only
        next unless proof_backed_false_positive?(name, config, symbol_names) ||
                    proof_backed_dwarf_audit?(filename, name, entries, config, audit_issue_keys) ||
                    proof_backed_merge_removal?(filename, name, entries, allowed_removals)

        entries.select { |line| line.attributes["hits"].to_i.positive? }.each do |line|
          removals << Removal.new(
            file: filename,
            function: name,
            line: line.attributes["number"].to_i,
            hits: line.attributes["hits"].to_i,
          )
          lines_node.delete_element(line)
        end
      end
    end

    write_xml(path, doc) unless removals.empty?
    removals
  end

  def self.orphan_hits(path, root: ROOT, functions: SUSPECT_RUNTIME_HEADER_FUNCTIONS)
    return [] unless File.file?(path)

    source_path = File.join(root, RUNTIME_HEADER_SOURCE)
    ranges = suspect_ranges(source_path, functions)
    return [] if ranges.empty?

    doc = REXML::Document.new(File.read(path))
    hits = []
    REXML::XPath.each(doc, "//class") do |klass|
      filename = normalize_filename(klass.attributes["filename"].to_s)
      next unless filename == RUNTIME_HEADER_COVERAGE

      lines_node = REXML::XPath.first(klass, "lines")
      next unless lines_node

      ranges.each do |name, range|
        entries = line_entries(lines_node, range)
        next unless orphan_runtime_header_hit?(entries, range)

        entries.select { |line| line.attributes["hits"].to_i.positive? }.each do |line|
          hits << OrphanHit.new(
            file: filename,
            function: name,
            line: line.attributes["number"].to_i,
            hits: line.attributes["hits"].to_i,
            reason: functions.fetch(name).fetch(:reason),
          )
        end
      end
    end
    hits
  end

  def self.assert_no_orphan_hits!(path, root: ROOT)
    hits = orphan_hits(path, root: root)
    return [] if hits.empty?

    summary = format_hits(hits)
    raise Error, "unproven orphan runtime-header coverage hit(s) remain in #{path}: #{summary}"
  end

  def self.suspect_ranges(source_path, functions)
    return {} unless File.file?(source_path)

    wanted = functions.keys.to_h { |name| [name, true] }
    function_ranges(File.readlines(source_path))
      .select { |range| wanted[range.name] }
      .to_h { |range| [range.name, range] }
  end

  def self.line_entries(lines_node, range)
    REXML::XPath.each(lines_node, "line").select do |line|
      number = line.attributes["number"].to_i
      number >= range.start_line && number <= range.end_line
    end
  end

  def self.orphan_runtime_header_hit?(entries, range)
    return false if entries.empty?

    covered = entries.select { |line| line.attributes["hits"].to_i.positive? }
    missed = entries.select { |line| line.attributes["hits"].to_i.zero? }
    body_lines = range.end_line - range.start_line + 1

    covered.length.between?(1, 2) && missed.empty? && body_lines >= 5
  end

  def self.proof_backed_false_positive?(name, config, symbol_names)
    return false unless symbol_names
    return false unless config.fetch(:proof) == :missing_symbol

    pattern = /runtime\.runtime-header(?:\.CheatLib)?\.#{Regexp.escape(name)}(?:\z|__|\b)/
    symbol_names.none? { |symbol| symbol.match?(pattern) }
  end

  def self.proof_backed_dwarf_audit?(filename, name, entries, config, audit_issue_keys)
    return false unless config.fetch(:proof) == :audit_only
    return false unless audit_issue_keys

    covered = entries.select { |line| line.attributes["hits"].to_i.positive? }
    return false if covered.empty?

    covered.all? do |line|
      audit_issue_keys[removal_key(filename, name, line.attributes["number"].to_i)]
    end
  end

  def self.proof_backed_merge_removal?(filename, name, entries, allowed_removals)
    return false unless allowed_removals

    covered = entries.select { |line| line.attributes["hits"].to_i.positive? }
    return false if covered.empty?

    covered.all? do |line|
      allowed_removals[removal_key(filename, name, line.attributes["number"].to_i)]
    end
  end

  def self.removal_key(file, function, line)
    "#{normalize_filename(file)}\0#{function}\0#{line.to_i}"
  end

  def self.symbol_names_for(binary)
    output, status = Open3.capture2e("nm", "-C", binary)
    raise Error, "nm failed for #{binary}:\n#{output}" unless status.success?

    output.lines.map(&:strip)
  end

  def self.dwarf_orphan_removal_keys(binary, root: ROOT, functions: SUSPECT_RUNTIME_HEADER_FUNCTIONS)
    return {} unless binary && File.file?(binary)

    symbols = ZigDwarfLineAudit.parse_nm(ZigDwarfLineAudit.run_command!("nm", "-n", "-S", "-C", binary))
    rows = ZigDwarfLineAudit.parse_decoded_line(
      ZigDwarfLineAudit.run_command!("readelf", "--debug-dump=decodedline", binary),
      root: root,
    )
    issues, = ZigDwarfLineAudit.audit_rows(rows, symbols, root: root, same_file_only: false)
    keys = issues.each_with_object({}) do |issue, issue_keys|
      issue_keys[removal_key(issue.row.file, issue.source_function.name, issue.row.line)] = true
    end
    runtime_ranges = ZigDwarfLineAudit.function_ranges_for(RUNTIME_HEADER_SOURCE, root: root, cache: {})
    rows.each do |row|
      next unless normalize_filename(row.file) == RUNTIME_HEADER_COVERAGE

      source_function = ZigDwarfLineAudit.function_at(runtime_ranges, row.line)
      next unless source_function
      next unless functions[source_function.name]&.fetch(:proof) == :audit_only

      symbol = ZigDwarfLineAudit.owner_for_pc(symbols, row.pc)
      next unless symbol

      owner_file = ZigDwarfLineAudit.owner_file_from_symbol(symbol.name)
      next if owner_file == row.file
      next if owner_file.nil? && symbol.name.start_with?("runtime.runtime-header")

      keys[removal_key(row.file, source_function.name, row.line)] = true
    end
    keys
  end

  def self.normalize_filename(filename)
    filename
      .sub(%r{\A\./}, "")
      .sub(%r{\A/+}, "")
      .sub(%r{\Azig/}, "")
  end

  def self.function_ranges(lines)
    ranges = []
    current = nil
    lines.each_with_index do |line, idx|
      line_number = idx + 1
      if current.nil? && (match = line.match(/\bfn\s+([A-Za-z_]\w*)\s*\(/))
        current = { name: match[1], start: line_number, depth: 0 }
      end
      next unless current

      strip_line_comment(line).each_char do |ch|
        current[:depth] += 1 if ch == "{"
        current[:depth] -= 1 if ch == "}"
      end
      if current[:depth].zero? && line_number > current[:start]
        ranges << FunctionRange.new(
          name: current[:name],
          start_line: current[:start],
          end_line: line_number,
        )
        current = nil
      end
    end
    ranges
  end

  def self.strip_line_comment(line)
    line.sub(%r{//.*\z}, "")
  end

  def self.write_xml(path, doc)
    File.open(path, "w") do |file|
      doc.write(file, 2)
      file.write("\n")
    end
  end

  def self.format_hits(hits)
    hits.group_by(&:function).map do |fn, rows|
      lines = rows.map(&:line).uniq.sort.join(",")
      "#{fn}:#{lines}"
    end.join(" ")
  end

  class CLI
    def self.run(argv)
      options = { root: ROOT, quiet: false, binary: nil, fail_on_orphan: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby tools/zig_coverage_sanitize.rb [options] COBERTURA_XML..."
        opts.on("--root PATH", "Repository root (default: current repository)") { |v| options[:root] = File.expand_path(v) }
        opts.on("--binary PATH", "Binary that produced this Cobertura XML; enables proof-backed removals") { |v| options[:binary] = File.expand_path(v, options[:root]) }
        opts.on("--fail-on-orphan", "Fail if suspicious orphan hits remain after proof-backed removals") { options[:fail_on_orphan] = true }
        opts.on("--quiet", "Suppress no-op messages") { options[:quiet] = true }
      end
      parser.parse!(argv)
      raise OptionParser::MissingArgument, "at least one Cobertura XML path is required" if argv.empty?

      total = 0
      argv.each do |path|
        expanded = File.expand_path(path, options[:root])
        removals = ZigCoverageSanitizer.sanitize_file!(expanded, root: options[:root], binary: options[:binary])
        total += removals.length
        if removals.empty?
          puts "Zig coverage sanitizer: no proof-backed removals in #{path}" unless options[:quiet]
        else
          grouped = ZigCoverageSanitizer.format_hits(removals)
          puts "Zig coverage sanitizer: removed #{removals.length} orphan runtime-header hit(s) from #{path} (#{grouped})"
        end
        ZigCoverageSanitizer.assert_no_orphan_hits!(expanded, root: options[:root]) if options[:fail_on_orphan]
      end
      total
    end
  end
end

if $PROGRAM_NAME == __FILE__
  ZigCoverageSanitizer::CLI.run(ARGV)
end
