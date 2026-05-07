require_relative "diagnostic_registry"

# DiagnosticExamples — pulls canonical bad/good CLEAR snippets from
# spec files for `clear explain` to render.
#
# Convention (see spec/error_emission_coverage_spec.rb for the
# canonical pattern):
#
#   # @example_for: CODE_NAME
#   # @fix: One- or multi-line prose describing the fix. Continuation
#   # @fix: lines join with newlines.
#   describe ":CODE_NAME — short label" do
#     it "raises when ..." do
#       expect { run(<<~CLEAR) }.to raise_error(/regex/)
#         <bad source>
#       CLEAR
#     end
#
#     it "compiles when ..." do
#       run(<<~CLEAR)
#         <good source>
#       CLEAR
#     end
#   end
#
# Loader contract:
#   * `@example_for: CODE` is required; references a registered code.
#   * `@fix:` lines are optional; concatenated as the fix prose.
#   * The next `describe` block after the annotation owns the example.
#   * Inside the describe: first `it` whose body matches `raise_error`
#     is the BAD example; first `it` without `raise_error` is the GOOD
#     example. Either may be missing.
#   * The first `<<~CLEAR ... CLEAR` heredoc inside each `it` is the
#     example body (literal heredoc-trimmed text).
#
# The loader does NOT execute Ruby — it's a line-based scanner. Specs
# are still plain RSpec; the convention is comment annotations + a
# describe/it shape that the loader can extract verbatim.
module DiagnosticExamples
  module_function

  # Default search path: every spec file the convention might live in.
  # New spec files using the convention should be added here.
  DEFAULT_SPEC_FILES = [
    File.expand_path("../../../spec/error_emission_coverage_spec.rb", __FILE__),
  ].freeze

  # Public entry point. Parses each spec file once, memoises results.
  # Returns a hash { CODE_SYM => { bad:, fix:, good:, file:, line: } }.
  def all
    @all ||= load!
  end

  def lookup(code)
    all[code.to_sym]
  end

  def load!(spec_files = DEFAULT_SPEC_FILES)
    out = {}
    spec_files.each do |path|
      next unless File.exist?(path)
      scan_file(path, out)
    end
    out
  end

  # ---- internals ----

  def scan_file(path, out)
    lines = File.readlines(path)
    i = 0
    while i < lines.length
      m = lines[i].match(/^\s*#\s*@example_for:\s*([A-Z][A-Z0-9_]+)\s*$/)
      unless m
        i += 1
        next
      end
      code = m[1].to_sym
      fix_lines = []
      j = i + 1
      # Collect contiguous @fix: lines (and any blank/comment lines).
      while j < lines.length
        if lines[j] =~ /^\s*#\s*@fix:\s?(.*)$/
          fix_lines << $1.rstrip
          j += 1
        elsif lines[j] =~ /^\s*#/ || lines[j].strip.empty?
          j += 1
        else
          break
        end
      end
      if j < lines.length && (dm = lines[j].match(/^(\s*)describe\b/))
        desc_indent = dm[1].length
        desc_end = find_block_end(lines, j, desc_indent)
        if desc_end
          block = lines[j..desc_end]
          out[code] = {
            bad:  extract_first_heredoc_in_it(block, expecting_raise: true),
            fix:  fix_lines.join("\n"),
            good: extract_first_heredoc_in_it(block, expecting_raise: false),
            file: path,
            line: j + 1,
          }
          i = desc_end + 1
          next
        end
      end
      # Annotation didn't lead to a describe — skip past it.
      i = j
    end
  end

  # Walk forward from `start_idx` (line of `describe ... do`) and find
  # the `end` line at the same indentation level. Returns the index or
  # nil if the file is malformed.
  def find_block_end(lines, start_idx, indent)
    depth = 1
    k = start_idx + 1
    while k < lines.length
      l = lines[k]
      # `do` blocks at any deeper indent open new sub-scopes; `end` at
      # any indent closes one. We just count `^do$`-ish openers and
      # `^end\b`-ish closers — RSpec's structure is regular enough.
      if l =~ /\bdo\b\s*(?:\|[^|]*\|)?\s*$/
        depth += 1
      elsif l =~ /^\s*end\b/
        depth -= 1
        return k if depth.zero?
      end
      k += 1
    end
    nil
  end

  # Inside a describe's lines, find the first `it ... do ... end` whose
  # body satisfies `expecting_raise` (true == contains `raise_error`,
  # false == does not). Extract the first `<<~CLEAR ... CLEAR` heredoc
  # body within that `it`.
  def extract_first_heredoc_in_it(block_lines, expecting_raise:)
    block_lines.each_with_index do |line, i|
      next unless line =~ /^(\s*)it\b/
      it_indent = $1.length
      it_end = find_block_end(block_lines, i, it_indent)
      next unless it_end
      body = block_lines[i..it_end].join
      has_raise = body.include?("raise_error")
      next unless has_raise == expecting_raise
      return extract_heredoc(body)
    end
    nil
  end

  # Extract the first <<~CLEAR ... CLEAR heredoc body, mimicking
  # Ruby's tilde-heredoc indent strip. Returns nil if not found.
  # The heredoc body starts on the line AFTER the `<<~CLEAR` marker
  # and ends at the next line whose only non-whitespace is `CLEAR`.
  def extract_heredoc(body)
    return nil unless body =~ /<<~CLEAR\b/
    after = $'
    # Skip the rest of the marker line (e.g. ` ) }.to raise_error(...)`).
    nl = after.index("\n")
    return nil unless nl
    after_lines = after[(nl + 1)..].lines
    end_idx = after_lines.index { |l| l =~ /^\s*CLEAR\s*$/ }
    return nil unless end_idx
    raw_lines = after_lines[0...end_idx]
    nonempty = raw_lines.reject { |l| l.strip.empty? }
    return raw_lines.join if nonempty.empty?
    min_indent = nonempty.map { |l| l[/\A( *)/].length }.min
    raw_lines.map { |l| l.sub(/\A {0,#{min_indent}}/, "") }.join
  end
end
