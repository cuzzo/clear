# typed: strict

require "set"
require "stringio"
require "sorbet-runtime"

require_relative "../ast/lexer"
require_relative "../ast/parser"
require_relative "../ast/fixable_error"
require_relative "../ast/syntax_typo_scanner"
require_relative "../tools/predicate_rewriter"
require_relative "../tools/multi_statement_linter"
require_relative "../compiler/module_importer"
require_relative "../annotator"

module ClearFixSupport
  extend T::Sig

  class UsageError < StandardError; end
  class FileMissingError < StandardError; end

  OutputStream = T.type_alias { T.any(IO, StringIO) }
  InputStream = T.type_alias { T.any(IO, StringIO) }

  class Options < T::Struct
    const :dry_run, T::Boolean
    const :take_first, T::Boolean
    const :only_set, T.nilable(T::Set[Symbol])
    const :loop_until_clean, T::Boolean
    const :loop_max, Integer
    const :paths, T::Array[String]
  end

  class RunResult < T::Struct
    const :passes, Integer
    const :edits_applied, Integer
  end

  class Heredoc < T::Struct
    const :content, String
    const :start_line, Integer
    const :indent, Integer
  end

  class LocationToken
    extend T::Sig

    sig { returns(Integer) }
    attr_reader :line
    sig { returns(Integer) }
    attr_reader :column

    sig { params(line: Integer, column: Integer).void }
    def initialize(line:, column:)
      @line = line
      @column = column
    end
  end

  CLEAR_HEREDOC_MARKERS = T.let(%w[CLEAR FLUX CHT].freeze, T::Array[String])

  sig { params(args: T::Array[String]).returns(Options) }
  def self.parse_args(args)
    dry_run = T.let(false, T::Boolean)
    take_first = T.let(false, T::Boolean)
    only_set = T.let(nil, T.nilable(T::Set[Symbol]))
    loop_until_clean = T.let(false, T::Boolean)
    loop_max = T.let(20, Integer)
    paths = T.let([], T::Array[String])

    args.each do |arg|
      case arg
      when "--dry-run"
        dry_run = true
      when "--yes"
        take_first = true
      when "--loop"
        loop_until_clean = true
        take_first = true
      when /\A--loop=(\d+)\z/
        loop_until_clean = true
        take_first = true
        loop_max = T.must(Regexp.last_match)[1].to_i
      when /\A--only=(.+)\z/
        only_set = T.must(Regexp.last_match)[1].split(",").map(&:to_sym).to_set
      when /\A-/
        raise UsageError, "Unknown flag for fix: #{arg}"
      else
        paths << arg
      end
    end

    raise UsageError, "Usage: clear fix [--dry-run|--yes|--loop[=N]|--only=cat1,cat2] <file.cht|file.rb>..." if paths.empty?
    raise UsageError, "--loop and --dry-run are mutually exclusive" if loop_until_clean && dry_run

    Options.new(
      dry_run: dry_run,
      take_first: take_first,
      only_set: only_set,
      loop_until_clean: loop_until_clean,
      loop_max: loop_max,
      paths: paths
    )
  end

  sig { params(args: T::Array[String], out: OutputStream, err: OutputStream, input: InputStream).returns(RunResult) }
  def self.run_args(args, out: $stdout, err: $stderr, input: $stdin)
    run(parse_args(args), out: out, err: err, input: input)
  end

  sig { params(options: Options, out: OutputStream, err: OutputStream, input: InputStream).returns(RunResult) }
  def self.run(options, out: $stdout, err: $stderr, input: $stdin)
    iter = T.let(0, Integer)
    total = T.let(0, Integer)

    loop do
      iter += 1
      applied = run_one_pass(options, out: out, err: err, input: input)
      total += applied
      break unless options.loop_until_clean

      if applied.zero?
        out.puts("[fix --loop] converged after #{iter} pass(es)")
        break
      end
      if iter >= options.loop_max
        out.puts("[fix --loop] hit loop_max=#{options.loop_max}; stopping (#{applied} edits in last pass)")
        break
      end
      out.puts("[fix --loop] pass #{iter}: #{applied} edit(s); re-running")
    end

    RunResult.new(passes: iter, edits_applied: total)
  end

  sig { params(source: String).returns(T::Array[FixableFinding]) }
  def self.collect_findings(source)
    FixCollector.enable!
    begin
      SyntaxTypoScanner.scan!(source)
      PredicateRewriter.lint!(source)
      MultiStatementLinter.lint!(source)
      begin
        tokens = Lexer.new(source).tokenize
        ast = Parser.new(tokens, source).parse
        annotator = SemanticAnnotator.new
        annotator.source_code = source
        annotator.annotate!(ast)
      rescue CompilerError, ParserError
      end
      FixCollector.drain
    ensure
      FixCollector.disable!
    end
  end

  sig { params(text: String, edits: T::Array[Edit]).returns(String) }
  def self.apply_edits(text, edits)
    lines = text.split("\n", -1)
    edits.each do |edit|
      span = edit.span
      idx = span.line - 1
      next if idx.negative? || idx >= lines.length

      line = T.must(lines[idx])
      start_col = span.col - 1
      start_col = 0 if start_col.negative?
      start_col = line.length if start_col > line.length
      end_col = start_col + span.length
      end_col = line.length if end_col > line.length
      lines[idx] = line[0...start_col] + edit.replacement + line[end_col..]
    end
    lines.join("\n")
  end

  sig { params(edits: T::Array[Edit]).returns(T::Array[Edit]) }
  def self.dedupe_overlapping_edits(edits)
    kept = T.let([], T::Array[Edit])
    edits.each do |edit|
      start_col = edit.span.col
      end_col = start_col + edit.span.length
      conflict = kept.find do |previous|
        next false if previous.span.line != edit.span.line

        previous_start = previous.span.col
        previous_end = previous_start + previous.span.length
        within_previous = start_col >= previous_start && start_col <= previous_end
        ranges_overlap = start_col < previous_end && previous_start < end_col
        within_previous || ranges_overlap
      end
      kept << edit unless conflict
    end
    kept
  end

  sig { params(source: String).returns(T::Array[Heredoc]) }
  def self.extract_clear_heredocs(source)
    out = T.let([], T::Array[Heredoc])
    lines = source.lines
    i = T.let(0, Integer)
    marker_pattern = CLEAR_HEREDOC_MARKERS.join("|")

    while i < lines.length
      line = T.must(lines[i])
      match = line.match(/<<(~|-)?(#{marker_pattern})\b/)
      unless match
        i += 1
        next
      end

      squiggle = match[1] == "~"
      marker = T.must(match[2])
      body_start_idx = i + 1
      end_idx = T.let(nil, T.nilable(Integer))
      j = body_start_idx
      while j < lines.length
        candidate = T.must(lines[j])
        if squiggle || match[1] == "-"
          if candidate.match?(/\A\s*#{marker}\b/)
            end_idx = j
            break
          end
        elsif candidate.match?(/\A#{marker}\b/)
          end_idx = j
          break
        end
        j += 1
      end

      unless end_idx
        i += 1
        next
      end

      body_lines = lines[body_start_idx...end_idx] || []
      indent = heredoc_indent(body_lines, squiggle: squiggle)
      stripped = body_lines.map do |body_line|
        squiggle && body_line.length >= indent ? body_line[indent..] : body_line
      end.join
      out << Heredoc.new(content: stripped, start_line: body_start_idx + 1, indent: indent)
      i = end_idx + 1
    end

    out
  end

  sig { params(fixes: T::Array[Fix], heredoc: Heredoc, rb_path: String).returns(T::Array[Fix]) }
  def self.translate_fixes_for_heredoc(fixes, heredoc, rb_path)
    fixes.map do |fix|
      translated = fix.edits.map do |edit|
        Edit.new(
          span: Span.new(
            file: rb_path,
            line: edit.span.line + heredoc.start_line - 1,
            col: edit.span.col + heredoc.indent,
            length: edit.span.length
          ),
          replacement: edit.replacement
        )
      end
      Fix.new(description: fix.description, confidence: fix.confidence, edits: translated)
    end
  end

  sig { params(finding: FixableFinding, heredoc: Heredoc, rb_path: String).returns(FixableFinding) }
  def self.translate_finding_for_heredoc(finding, heredoc, rb_path)
    token = translated_token(finding, heredoc)
    FixableFinding.new(
      level: finding.level,
      message: finding.message,
      token: token,
      category: finding.category,
      fixes: translate_fixes_for_heredoc(finding.fixes, heredoc, rb_path)
    )
  end

  sig { params(finding: FixableFinding, out: OutputStream).void }
  def self.describe_finding(finding, out: $stdout)
    out.puts("\n[#{finding.category}] #{finding.message} (line #{token_line(finding)}, col #{token_column(finding)})")
    finding.fixes.each_with_index do |fix, index|
      marker = fix.confidence == :auto ? "*" : " "
      out.puts("  #{marker} [#{index + 1}] #{fix.description}")
    end
  end

  sig { params(finding: FixableFinding, err: OutputStream, input: InputStream).returns(T.nilable(Fix)) }
  def self.prompt_choice(finding, err: $stderr, input: $stdin)
    err.print("Apply which fix? [1-#{finding.fixes.length}, 0 to skip]: ")
    raw = input.gets&.strip
    return nil if raw.nil? || raw.empty?

    index = raw.to_i
    return nil if index.zero?

    finding.fixes[index - 1]
  end

  sig { params(finding: FixableFinding).returns(T.nilable(Integer)) }
  def self.token_line(finding)
    token_integer(finding, :line)
  end

  sig { params(finding: FixableFinding).returns(T.nilable(Integer)) }
  def self.token_column(finding)
    token_integer(finding, :column)
  end

  sig { params(source: String, only_set: T.nilable(T::Set[Symbol]), take_first: T::Boolean).returns([String, Integer, T::Array[FixableFinding]]) }
  def self.apply_to_source(source, only_set: nil, take_first: false)
    findings = filter_findings(collect_findings(source), only_set)
    edits = T.let([], T::Array[Edit])
    findings.each do |finding|
      fix = chosen_fix(finding, take_first: take_first)
      edits.concat(fix.edits) if fix
    end
    ordered = dedupe_overlapping_edits(edits.sort_by { |edit| [edit.span.line, edit.span.col] }).reverse
    [apply_edits(source, ordered), ordered.length, findings]
  end

  sig { params(source: String, only_set: T.nilable(T::Set[Symbol])).returns(T::Array[FixableFinding]) }
  def self.preview_source(source, only_set: nil)
    filter_findings(collect_findings(source), only_set)
  end

  sig { params(options: Options, out: OutputStream, err: OutputStream, input: InputStream).returns(Integer) }
  def self.run_one_pass(options, out:, err:, input:)
    pass_applied = T.let(0, Integer)

    options.paths.each do |path|
      raise FileMissingError, "No such file: #{path}" unless File.file?(path)

      source = File.read(path)
      findings = findings_for_path(path, source, out: out)
      findings = filter_findings(findings, options.only_set)

      if findings.empty?
        out.puts("#{path}: no fixable findings")
        next
      end

      queued_edits = T.let([], T::Array[[String, Edit]])
      findings.each do |finding|
        if options.dry_run
          describe_finding(finding, out: out)
          next
        end

        fix = chosen_fix(finding, take_first: options.take_first)
        unless fix
          describe_finding(finding, out: out)
          fix = prompt_choice(finding, err: err, input: input)
        end
        next unless fix

        out.puts("  #{path}:#{token_line(finding)}:#{token_column(finding)}  [#{finding.category}]  #{finding.message}")
        out.puts("    -> #{fix.description}")
        fix.edits.each do |edit|
          queued_edits << [path, edit]
        end
      end

      next if options.dry_run || queued_edits.empty?

      applied_count = apply_queued_edits(queued_edits, fallback_path: path)
      out.puts("#{path}: applied #{applied_count} edit(s)")
      pass_applied += applied_count
    end

    pass_applied
  end
  private_class_method :run_one_pass

  sig { params(path: String, source: String, out: OutputStream).returns(T::Array[FixableFinding]) }
  def self.findings_for_path(path, source, out:)
    return collect_findings(source) unless path.end_with?(".rb")

    heredocs = extract_clear_heredocs(source)
    if heredocs.empty?
      out.puts("#{path}: no CLEAR heredocs found")
      return []
    end

    findings = T.let([], T::Array[FixableFinding])
    heredocs.each do |heredoc|
      collect_findings(heredoc.content).each do |finding|
        findings << translate_finding_for_heredoc(finding, heredoc, path)
      end
    end
    findings
  end
  private_class_method :findings_for_path

  sig { params(findings: T::Array[FixableFinding], only_set: T.nilable(T::Set[Symbol])).returns(T::Array[FixableFinding]) }
  def self.filter_findings(findings, only_set)
    filtered = only_set ? findings.select { |finding| only_set.include?(finding.category) } : findings
    filtered.sort_by { |finding| [token_line(finding) || 0, token_column(finding) || 0] }
  end
  private_class_method :filter_findings

  sig { params(finding: FixableFinding, take_first: T::Boolean).returns(T.nilable(Fix)) }
  def self.chosen_fix(finding, take_first:)
    auto_fix = finding.fixes.find { |fix| fix.confidence == :auto }
    return auto_fix if auto_fix
    return finding.fixes.first if take_first

    nil
  end
  private_class_method :chosen_fix

  sig { params(queued_edits: T::Array[[String, Edit]], fallback_path: String).returns(Integer) }
  def self.apply_queued_edits(queued_edits, fallback_path:)
    applied_count = T.let(0, Integer)
    queued_edits.group_by(&:first).each do |file_key, rows|
      target_path = file_key || fallback_path
      edits = rows.map(&:last).sort_by { |edit| [edit.span.line, edit.span.col] }
      edits = dedupe_overlapping_edits(edits).reverse
      File.write(target_path, apply_edits(File.read(target_path), edits))
      applied_count += edits.length
    end
    applied_count
  end
  private_class_method :apply_queued_edits

  sig { params(finding: FixableFinding, heredoc: Heredoc).returns(T.nilable(LocationToken)) }
  def self.translated_token(finding, heredoc)
    line = token_line(finding)
    return nil unless line

    LocationToken.new(line: line + heredoc.start_line - 1, column: (token_column(finding) || 0) + heredoc.indent)
  end
  private_class_method :translated_token

  sig { params(finding: FixableFinding, method_name: Symbol).returns(T.nilable(Integer)) }
  def self.token_integer(finding, method_name)
    token = finding.token
    return nil unless token.respond_to?(method_name)

    value = T.unsafe(token).public_send(method_name)
    value.is_a?(Integer) ? value : nil
  end
  private_class_method :token_integer

  sig { params(lines: T::Array[String], squiggle: T::Boolean).returns(Integer) }
  def self.heredoc_indent(lines, squiggle:)
    return 0 unless squiggle

    non_blank = lines.reject { |line| line.strip.empty? }
    return 0 if non_blank.empty?

    non_blank.map { |line| line[/\A[ \t]*/].length }.min || 0
  end
  private_class_method :heredoc_indent
end
