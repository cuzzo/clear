# typed: strict
require_relative "diagnostic_registry"
require_relative "../semantic/ownership_graph"

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
  extend T::Sig

  Example = T.type_alias { T::Hash[Symbol, T.untyped] }

  class FixScan < T::Struct
    const :fix_lines, T::Array[String]
    const :next_idx, Integer
  end

  # Default search path: every spec file the convention might live in.
  # New spec files using the convention should be added here.
  DEFAULT_SPEC_FILES = T.let([
    File.expand_path("../../../spec/error_emission_coverage_spec.rb", __FILE__),
    File.expand_path("../../../spec/capabilities_spec.rb", __FILE__),
    File.expand_path("../../../spec/snapshot_annotator_spec.rb", __FILE__),
    File.expand_path("../../../spec/with_view_spec.rb", __FILE__),
    File.expand_path("../../../spec/with_guard_spec.rb", __FILE__),
    File.expand_path("../../../spec/atomic_ptr_bare_mutation_spec.rb", __FILE__),
  ].freeze, T::Array[String])

  # Public entry point. Parses each spec file once, memoises results.
  # Returns a hash { CODE_SYM => { bad:, fix:, good:, file:, line: } }.
  sig { returns(T.untyped) }
  def self.all
    @all = T.let(@all, T.untyped)
    @all ||= load!
  end

  sig { params(code: T.untyped).returns(T.nilable(Example)) }
  def self.lookup(code)
    all[code.to_sym]
  end

  sig { params(spec_files: T.untyped).returns(T::Hash[T.untyped, T.untyped]) }
  def self.load!(spec_files = DEFAULT_SPEC_FILES)
    out = {}
    spec_files.each do |path|
      next unless File.exist?(path)
      scan_file(path, out)
    end
    out
  end

  # ---- internals ----

  sig { params(path: T.untyped, out: T.untyped).returns(NilClass) }
  def self.scan_file(path, out)
    lines = File.readlines(path)
    i = T.let(0, Integer)
    while i < lines.length
      m = T.must(lines[i]).match(/^\s*#\s*@example_for:\s*([A-Z][A-Z0-9_]+)\s*$/)
      unless m
        i += 1
        next
      end
      code = T.must(m[1]).to_sym
      fix_scan = scan_fix_lines(lines, i + 1)
      describe_idx = fix_scan.next_idx
      if describe_idx < lines.length &&
         (dm = T.must(lines[describe_idx]).match(/^(\s*)describe\b/))
        desc_indent = T.must(dm[1]).length
        desc_end = find_block_end(lines, describe_idx, desc_indent)
        if desc_end
          block = T.must(lines[describe_idx..desc_end])
          out[code] = {
            bad:  extract_first_heredoc_in_it(block, expecting_raise: true),
            fix:  fix_scan.fix_lines.join("\n"),
            good: extract_first_heredoc_in_it(block, expecting_raise: false),
            file: path,
            line: describe_idx + 1,
          }
          i = desc_end + 1
          next
        end
      end
      i = describe_idx
    end
  end

  sig { params(lines: T::Array[String], start_idx: Integer).returns(FixScan) }
  def self.scan_fix_lines(lines, start_idx)
    fix_lines = T.let([], T::Array[String])
    idx = start_idx
    while idx < lines.length
      line = T.must(lines[idx])
      if (match = line.match(/^\s*#\s*@fix:\s?(.*)$/))
        fix_lines << T.must(match[1]).rstrip
        idx += 1
      elsif line =~ /^\s*#/ || line.strip.empty?
        idx += 1
      else
        break
      end
    end
    FixScan.new(fix_lines: fix_lines, next_idx: idx)
  end

  # Walk forward from `start_idx` (line of `describe ... do`) and find
  # the `end` line at the same indentation level. Returns the index or
  # nil if the file is malformed.
  sig { params(lines: T.untyped, start_idx: T.untyped, indent: T.nilable(Integer)).returns(T.untyped) }
  def self.find_block_end(lines, start_idx, indent)
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
  sig { params(block_lines: T.untyped, expecting_raise: T.untyped).returns(T.nilable(String)) }
  def self.extract_first_heredoc_in_it(block_lines, expecting_raise:)
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
  # The heredoc body starts on the line AFTER the `<<~CLEAR` (or
  # legacy `<<~FLUX`) marker and ends at the next line whose only
  # non-whitespace is the matching marker name.
  sig { params(body: String).returns(T.nilable(String)) }
  def self.extract_heredoc(body)
    return nil unless body =~ /<<~(CLEAR|FLUX)\b/
    marker = $~[1]
    after = $~.post_match
    # Skip the rest of the marker line (e.g. ` ) }.to raise_error(...)`).
    nl = after.index("\n")
    return nil unless nl
    after_lines = after[(nl + 1)..].lines
    end_idx = after_lines.index { |l| l =~ /^\s*#{marker}\s*$/ }
    return nil unless end_idx
    raw_lines = after_lines[0...end_idx]
    nonempty = raw_lines.reject { |l| l.strip.empty? }
    return raw_lines.join if nonempty.empty?
    min_indent = nonempty.map { |l| l[/\A( *)/].length }.min
    raw_lines.map { |l| l.sub(/\A {0,#{min_indent}}/, "") }.join
  end

  private_class_method :extract_first_heredoc_in_it
  private_class_method :extract_heredoc
  private_class_method :load!
  private_class_method :scan_file
  private_class_method :scan_fix_lines

end
