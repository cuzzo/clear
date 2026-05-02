#!/usr/bin/env ruby
# scripts/migrate_returns_bang.rb
#
# Targeted migration: insert `!` before `RETURNS T` for fns that can fail.
# This script ONLY applies fixes whose Fix description matches the
# fallible-returns rule. No other autofix rule (MUTABLE-unused, typo,
# etc.) runs through this script.
#
# Usage:
#   ruby scripts/migrate_returns_bang.rb spec/         # dir
#   ruby scripts/migrate_returns_bang.rb spec/foo.rb   # single file

require 'set'
$LOAD_PATH.unshift(File.expand_path('..', __dir__))
require 'src/ast/lexer'
require 'src/ast/parser'
require 'src/ast/fixable_error'
require 'src/ast/syntax_typo_scanner'
require 'src/annotator'

FIX_DESCRIPTION_PREFIX = "Add `!` to the return type"

CLEAR_HEREDOC_MARKERS = %w[CLEAR FLUX CHT].freeze

# Detect quoted strings (' or ") whose body contains a CLEAR-shaped
# `FN <name>(...) RETURNS T ->` followed by a body and `END`. Returns
# `[ { content:, start_line:, indent:, col_offset: } ]` so positions
# inside can be translated back to .rb-file coords. Single-line strings
# only — multi-line `\n`-embedded strings inside Ruby are unusual and
# the heredoc extractor handles those.
def extract_clear_quoted_strings(rb_source)
  out = []
  rb_source.each_line.with_index do |line, idx|
    # Skip Ruby comments.
    next if line =~ /\A\s*#/
    # Match a quoted string that contains CLEAR-shaped `FN ... END`.
    line.scan(/(['"])((?:\\.|(?!\1).)*?)\1/) do |q, body|
      pos = $~.offset(0).first  # capture BEFORE doing any regex match on body
      next unless body =~ /\bFN\s+\w+!?\s*\(/ && body =~ /\bEND\s*\z/
      out << {
        content:    body,
        start_line: idx + 1,
        indent:     0,
        col_offset: pos + 1,  # +1 for the opening quote
      }
    end
  end
  out
end

def extract_clear_heredocs(rb_source)
  out = []
  lines = rb_source.lines
  i = 0
  while i < lines.length
    line = lines[i]
    # Skip Ruby-commented lines: `#  <<~CLEAR` is a doc/comment, not a real heredoc.
    if line =~ /\A\s*#/
      i += 1
      next
    end
    m = line.match(/<<(~|-)?(#{CLEAR_HEREDOC_MARKERS.join('|')})\b/)
    if m
      squiggle = m[1] == '~'
      marker   = m[2]
      body_start_idx = i + 1
      end_idx = nil
      (body_start_idx...lines.length).each do |j|
        if squiggle || m[1] == '-'
          end_idx = j and break if lines[j] =~ /\A\s*#{marker}\b/
        else
          end_idx = j and break if lines[j] =~ /\A#{marker}\b/
        end
      end
      if end_idx
        body_lines = lines[body_start_idx...end_idx]
        indent = 0
        if squiggle
          non_blank = body_lines.reject { |bl| bl.strip.empty? }
          unless non_blank.empty?
            indent = non_blank.map { |bl| bl[/\A[ \t]*/].length }.min || 0
          end
        end
        stripped = body_lines.map { |bl|
          squiggle && bl.length >= indent ? bl[indent..] : bl
        }.join
        out << { content: stripped, start_line: body_start_idx + 1, indent: indent }
        i = end_idx + 1
      else
        i += 1
      end
    else
      i += 1
    end
  end
  out
end

def stub_ruby_interpolations(src)
  # Replace `#{...}` (with brace-balanced inner expressions, possibly
  # spanning multiple Ruby blocks) with a same-length CLEAR-valid
  # placeholder. Byte positions are preserved so edit positions
  # computed against the stubbed source are still correct against the
  # original heredoc text.
  out = src.dup
  i = 0
  while (idx = out.index("\#{", i))
    # Find matching close brace, counting nested {}.
    depth = 1
    j = idx + 2
    while j < out.length && depth > 0
      c = out[j]
      if c == '{'
        depth += 1
      elsif c == '}'
        depth -= 1
      end
      j += 1
    end
    break if depth != 0
    span_len = j - idx
    # Replace with `S` + `s`*(len-1) -- a CLEAR TYPE_ID, length-preserving.
    placeholder = 'S' + ('s' * (span_len - 1))
    out[idx, span_len] = placeholder
    i = idx + span_len
  end
  out
end

def run_compiler_and_drain(src)
  src = stub_ruby_interpolations(src)
  FixCollector.enable!
  findings = []
  begin
    SyntaxTypoScanner.scan!(src)
    begin
      tokens = Lexer.new(src).tokenize
      ast    = Parser.new(tokens, src).parse
      annotator = SemanticAnnotator.new
      annotator.source_code = src
      annotator.annotate!(ast)
    rescue CompilerError, ParserError
    end
    findings = FixCollector.drain
  ensure
    FixCollector.disable!
  end
  findings
end

def fallible_returns_fix(finding)
  finding.fixes.find do |fx|
    fx.confidence == :auto && fx.description.start_with?(FIX_DESCRIPTION_PREFIX)
  end
end

def collect_edits_for_path(path)
  source = File.read(path)
  edits = []
  if path.end_with?('.rb')
    heredocs = extract_clear_heredocs(source)
    quoted   = extract_clear_quoted_strings(source)
    (heredocs + quoted).each do |hd|
      findings = []
      begin
        findings = run_compiler_and_drain(hd[:content])
      rescue => e
        warn "[skip-heredoc] #{path}:#{hd[:start_line]}: #{e.class}: #{e.message}"
        next
      end
      base_col = hd[:col_offset] || hd[:indent] || 0
      findings.each do |f|
        fix = fallible_returns_fix(f)
        next unless fix
        fix.edits.each do |e|
          # Heredocs use start_line + indent. Quoted strings are
          # single-line; their `start_line` is the .rb line and
          # `col_offset` is the column of the body's first char.
          line = e.span.line + hd[:start_line] - 1
          col  = if hd[:col_offset]
                   # Quoted: col_offset is the 1-based col of the opening
                   # quote in the .rb line; body's first char is at
                   # col_offset+1, so body 1-based col N maps to col_offset+N.
                   hd[:col_offset] + e.span.col
                 else
                   e.span.col + hd[:indent]
                 end
          edits << Edit.new(
            span: Span.new(file: path, line: line, col: col, length: e.span.length),
            replacement: e.replacement,
          )
        end
      end
    end
  else
    findings = run_compiler_and_drain(source)
    findings.each do |f|
      fix = fallible_returns_fix(f)
      next unless fix
      edits.concat(fix.edits)
    end
  end
  edits
end

def apply_edits_to_file(path, edits)
  return 0 if edits.empty?
  text = File.read(path)
  lines = text.lines
  # Right-to-left by (line, col) so column offsets stay stable.
  ordered = edits.uniq { |e| [e.span.line, e.span.col, e.replacement] }
                 .sort_by { |e| [e.span.line, e.span.col] }
                 .reverse
  ordered.each do |e|
    li = e.span.line - 1
    next unless lines[li]
    col = e.span.col - 1
    raise "col out of range #{path}:#{e.span.line}:#{e.span.col}" if col < 0 || col > lines[li].length
    lines[li] = lines[li][0...col] + e.replacement + lines[li][(col + e.span.length)..]
  end
  File.write(path, lines.join)
  ordered.length
end

# --- Driver ---

dry_run = ARGV.delete('--dry-run')
paths = ARGV.dup

if paths.empty?
  warn "Usage: ruby scripts/migrate_returns_bang.rb [--dry-run] <path>..."
  exit 1
end

# Expand directories.
files = []
paths.each do |p|
  if File.directory?(p)
    files.concat(Dir.glob(File.join(p, '**', '*.rb')))
    files.concat(Dir.glob(File.join(p, '**', '*.cht')))
  else
    files << p
  end
end

total_edits = 0
files.sort.each do |path|
  begin
    edits = collect_edits_for_path(path)
  rescue => e
    warn "[skip] #{path}: #{e.class}: #{e.message}"
    next
  end
  next if edits.empty?
  if dry_run
    puts "#{path}: #{edits.length} edit(s) (dry-run)"
    edits.each do |e|
      puts "  #{path}:#{e.span.line}:#{e.span.col} insert '#{e.replacement}'"
    end
  else
    n = apply_edits_to_file(path, edits)
    puts "#{path}: applied #{n}"
    total_edits += n
  end
end

puts "TOTAL: #{total_edits}" unless dry_run
