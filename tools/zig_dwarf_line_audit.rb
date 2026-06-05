# frozen_string_literal: true

require "optparse"
require "open3"

module ZigDwarfLineAudit
  ROOT = File.expand_path("..", __dir__)
  DEFAULT_SOURCE_RE = %r{\Azig/(?:runtime|lib|experimental)/.*\.zig\z}.freeze

  LineRow = Struct.new(:file, :line, :pc, :flags, keyword_init: true)
  Symbol = Struct.new(:addr, :size, :name, keyword_init: true)
  FunctionRange = Struct.new(:name, :start_line, :end_line, :inline_fn, keyword_init: true)
  Issue = Struct.new(
    :row,
    :symbol,
    :owner_file,
    :owner_function,
    :source_function,
    keyword_init: true,
  )

  class Error < StandardError; end

  def self.run_command!(*argv)
    output, status = Open3.capture2e(*argv)
    raise Error, "#{argv.join(" ")} failed:\n#{output}" unless status.success?

    output
  end

  def self.parse_nm(text)
    text.each_line.filter_map do |line|
      line = line.chomp
      next unless line =~ /\A([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+\S\s+(.+)\z/

      Symbol.new(
        addr: Regexp.last_match(1).to_i(16),
        size: Regexp.last_match(2).to_i(16),
        name: Regexp.last_match(3).strip,
      )
    end.sort_by(&:addr)
  end

  def self.parse_decoded_line(text, root: ROOT)
    current_file = nil
    rows = []

    text.each_line do |line|
      stripped = line.strip
      if (match = stripped.match(/\A(.+\.zig):(?:\[.*\])?\z/))
        current_file = normalize_source_path(match[1], root: root)
        next
      end

      next unless current_file
      next unless stripped =~ /\A\S+\.zig\s+(\d+)\s+0x([0-9a-fA-F]+)(.*)\z/

      line_number = Regexp.last_match(1).to_i
      next if line_number.zero?

      rows << LineRow.new(
        file: current_file,
        line: line_number,
        pc: Regexp.last_match(2).to_i(16),
        flags: Regexp.last_match(3).to_s.strip,
      )
    end

    rows
  end

  def self.normalize_source_path(path, root: ROOT)
    clean = path.sub(/:\z/, "")
    if clean.start_with?("#{root}/")
      clean.delete_prefix("#{root}/")
    else
      clean.sub(%r{\A\./}, "").sub(%r{\A/+}, "")
    end
  end

  def self.owner_for_pc(symbols, pc)
    idx = bsearch_symbol_index(symbols, pc)
    return nil unless idx

    sym = symbols[idx]
    pc < sym.addr + sym.size ? sym : nil
  end

  def self.bsearch_symbol_index(symbols, pc)
    lo = 0
    hi = symbols.length - 1
    best = nil
    while lo <= hi
      mid = (lo + hi) / 2
      if symbols[mid].addr <= pc
        best = mid
        lo = mid + 1
      else
        hi = mid - 1
      end
    end
    best
  end

  def self.owner_file_from_symbol(symbol_name)
    parts = symbol_name.split(".")
    case parts[0]
    when "runtime"
      "zig/runtime/#{parts[1]}.zig" if parts[1]
    when "lib"
      "zig/lib/#{parts[1]}.zig" if parts[1]
    when "experimental"
      "zig/experimental/#{parts[1]}.zig" if parts[1]
    end
  end

  def self.owner_function_from_symbol(symbol_name, function_names)
    return nil if function_names.empty?

    symbol_name.split(".").reverse_each do |part|
      base = base_symbol_component(part)
      return base if function_names.include?(base)
    end

    function_names.sort_by { |name| -name.length }.find do |name|
      symbol_name.match?(%r{(?:\.|\A)#{Regexp.escape(name)}(?:__|\.|\z)})
    end
  end

  def self.base_symbol_component(part)
    part
      .sub(/__anon_\d+.*/, "")
      .sub(/__struct_\d+.*/, "")
  end

  def self.function_ranges_for(file, root:, cache:)
    cache[file] ||= begin
      path = File.join(root, file)
      File.file?(path) ? function_ranges(File.readlines(path)) : []
    end
  end

  def self.source_lines_for(file, root:, cache:)
    cache[file] ||= begin
      path = File.join(root, file)
      File.file?(path) ? File.readlines(path) : []
    end
  end

  def self.function_ranges(lines)
    ranges = []
    stack = []

    lines.each_with_index do |line, idx|
      line_number = idx + 1
      clean = strip_line_comment(line)
      if (match = clean.match(/\bfn\s+([A-Za-z_]\w*)\s*\(/))
        tail = clean[match.end(0)..]
        inline_fn = clean.match?(/\binline\s+fn\s+#{Regexp.escape(match[1])}\s*\(/)
        unless tail&.include?(";") && !tail.include?("{")
          stack << { name: match[1], start: line_number, depth: 0, has_body: false, inline_fn: inline_fn }
        end
      end

      next if stack.empty?

      opens = clean.count("{")
      closes = clean.count("}")
      stack.each do |frame|
        frame[:has_body] ||= opens.positive?
        frame[:depth] += opens
        frame[:depth] -= closes
      end

      while stack.any? && stack.last[:has_body] && stack.last[:depth].zero?
        frame = stack.pop
        ranges << FunctionRange.new(
          name: frame[:name],
          start_line: frame[:start],
          end_line: line_number,
          inline_fn: frame[:inline_fn],
        )
      end
    end

    ranges
  end

  def self.strip_line_comment(line)
    line.sub(%r{//.*\z}, "")
  end

  def self.function_at(ranges, line)
    ranges
      .select { |range| line >= range.start_line && line <= range.end_line }
      .min_by { |range| range.end_line - range.start_line }
  end

  def self.lexically_related?(owner_ranges, owner_function, source_function)
    owner_ranges.any? do |range|
      next false unless range.name == owner_function

      contains_range?(range, source_function) || contains_range?(source_function, range)
    end
  end

  def self.contains_range?(outer, inner)
    outer.start_line <= inner.start_line && outer.end_line >= inner.end_line
  end

  def self.call_graph_for(file, root:, ranges:, lines_cache:, graph_cache:)
    graph_cache[file] ||= begin
      lines = source_lines_for(file, root: root, cache: lines_cache)
      names = ranges.map(&:name).uniq
      ranges.each_with_object(Hash.new { |h, k| h[k] = [] }) do |range, graph|
        body = lines[(range.start_line - 1)..(range.end_line - 1)]
          .to_a
          .map { |line| strip_line_comment(line) }
          .join("\n")
        names.each do |name|
          next if name == range.name

          graph[range.name] << name if body.match?(/\b#{Regexp.escape(name)}\s*\(/)
        end
      end.transform_values(&:uniq)
    end
  end

  def self.reachable_call?(graph, from, to)
    return true if from == to

    seen = {}
    stack = Array(graph[from])
    until stack.empty?
      name = stack.pop
      next if seen[name]

      return true if name == to

      seen[name] = true
      stack.concat(graph[name] || [])
    end
    false
  end

  def self.audit_rows(rows, symbols, root: ROOT, source_re: DEFAULT_SOURCE_RE, same_file_only: true, include_inline: false)
    ranges_cache = {}
    lines_cache = {}
    graph_cache = {}
    issues = []
    counters = Hash.new(0)

    rows.each do |row|
      counters[:rows] += 1
      next unless row.file.match?(source_re)

      counters[:repo_rows] += 1
      symbol = owner_for_pc(symbols, row.pc)
      next unless symbol

      counters[:with_symbol] += 1
      owner_file = owner_file_from_symbol(symbol.name)
      next unless owner_file
      next if same_file_only && owner_file != row.file

      owner_ranges = function_ranges_for(owner_file, root: root, cache: ranges_cache)
      source_ranges = function_ranges_for(row.file, root: root, cache: ranges_cache)
      owner_names = owner_ranges.map(&:name)
      owner_function = owner_function_from_symbol(symbol.name, owner_names)
      source_function = function_at(source_ranges, row.line)
      next unless owner_function && source_function

      counters[:checked] += 1
      next if owner_function == source_function.name
      if source_function.inline_fn && !include_inline
        counters[:inline_suppressed] += 1
        next
      end
      if owner_file == row.file && lexically_related?(owner_ranges, owner_function, source_function)
        counters[:lexical_suppressed] += 1
        next
      end
      if owner_file == row.file
        graph = call_graph_for(owner_file, root: root, ranges: owner_ranges, lines_cache: lines_cache, graph_cache: graph_cache)
        if reachable_call?(graph, owner_function, source_function.name)
          counters[:callgraph_suppressed] += 1
          next
        end
      end

      issues << Issue.new(
        row: row,
        symbol: symbol,
        owner_file: owner_file,
        owner_function: owner_function,
        source_function: source_function,
      )
    end

    [issues, counters]
  end

  def self.group_issues(issues)
    issues.group_by do |issue|
      [
        issue.row.file,
        issue.row.line,
        issue.source_function.name,
        issue.owner_file,
        issue.owner_function,
      ]
    end
  end

  def self.format_report(binary:, issues:, counters:, limit:)
    lines = []
    lines << "Zig DWARF line-table audit: #{binary}"
    lines << "  line rows:       #{counters[:rows]}"
    lines << "  repo rows:       #{counters[:repo_rows]}"
    lines << "  rows with symbol: #{counters[:with_symbol]}"
    lines << "  checked rows:    #{counters[:checked]}"
    lines << "  inline suppressed: #{counters[:inline_suppressed]}"
    lines << "  lexical suppressed: #{counters[:lexical_suppressed]}"
    lines << "  callgraph suppressed: #{counters[:callgraph_suppressed]}"
    lines << "  suspicious rows: #{issues.length}"
    lines << ""

    grouped = group_issues(issues)
    if grouped.empty?
      lines << "No same-file function/line-table contradictions found."
      return lines.join("\n")
    end

    lines << "| Rows | Symbols | Reported line | Reported function | Owning function | Sample symbol | Sample PC |"
    lines << "| ---: | ---: | --- | --- | --- | --- | --- |"
    grouped.sort_by { |_key, rows| [-rows.length, rows.first.row.file, rows.first.row.line] }.first(limit).each do |key, rows|
      reported_file, reported_line, reported_fn, _owner_file, owner_fn = key
      sample = rows.first
      symbol_count = rows.map { |issue| issue.symbol.name }.uniq.length
      lines << [
        "| #{rows.length}",
        symbol_count,
        "`#{reported_file}:#{reported_line}`",
        "`#{reported_fn}`",
        "`#{owner_fn}`",
        "`#{sample.symbol.name}`",
        "`0x#{sample.row.pc.to_s(16)}` |",
      ].join(" | ")
    end

    if grouped.length > limit
      lines << ""
      lines << "_#{grouped.length - limit} more groups omitted by `--limit #{limit}`._"
    end

    lines.join("\n")
  end

  class CLI
    def self.run(argv)
      options = {
        root: ROOT,
        limit: 50,
        same_file_only: true,
        include_inline: false,
        fail_on_issues: false,
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby tools/zig_dwarf_line_audit.rb [options] BINARY"
        opts.on("--root PATH", "Repository root (default: current repository)") { |v| options[:root] = File.expand_path(v) }
        opts.on("--limit N", Integer, "Issue groups to print (default: 50)") { |v| options[:limit] = v }
        opts.on("--cross-file", "Also flag rows where the owning symbol and line row are in different files") { options[:same_file_only] = false }
        opts.on("--include-inline", "Also report rows attributed to inline source functions") { options[:include_inline] = true }
        opts.on("--fail-on-issues", "Exit non-zero if suspicious rows are found") { options[:fail_on_issues] = true }
      end
      parser.parse!(argv)
      raise OptionParser::MissingArgument, "binary path is required" if argv.empty?

      binary = File.expand_path(argv.fetch(0), options[:root])
      symbols = ZigDwarfLineAudit.parse_nm(ZigDwarfLineAudit.run_command!("nm", "-n", "-S", "-C", binary))
      rows = ZigDwarfLineAudit.parse_decoded_line(
        ZigDwarfLineAudit.run_command!("readelf", "--debug-dump=decodedline", binary),
        root: options[:root],
      )
      issues, counters = ZigDwarfLineAudit.audit_rows(
        rows,
        symbols,
        root: options[:root],
        same_file_only: options[:same_file_only],
        include_inline: options[:include_inline],
      )

      puts ZigDwarfLineAudit.format_report(binary: binary, issues: issues, counters: counters, limit: options[:limit])
      exit 1 if options[:fail_on_issues] && issues.any?
      issues
    end
  end
end

if $PROGRAM_NAME == __FILE__
  ZigDwarfLineAudit::CLI.run(ARGV)
end
