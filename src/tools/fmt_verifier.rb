# typed: strict
# Fmt-verifier — confirms `Formatter.format` is semantics-preserving for a
# given CLEAR source by transpiling the original AND the formatted form to
# Zig and comparing the outputs byte-for-byte.
#
# Why: the formatter operates on tokens (with two source-level pre-passes
# in MethodRewriter and PredicateRewriter). The tests under spec/ exercise
# specific formatter rules but can't catch every pathological interaction.
# This tool gives us a much wider net: every benchmark / example / test
# .cht file becomes a "did fmt change emitted Zig?" sanity check.
#
# Usage:
#   FmtVerifier.verify("benchmarks/sequential/01_call_overhead/bench.cht")
#   # => Result(ok: true, ...)
#
#   FmtVerifier.verify_dir("benchmarks/sequential")
#   # => array of Results
#
# CLI: `clear fmt --verify <file-or-dir>` wires through to this module.

require_relative '../backends/transpiler'
require_relative '../backends/importer'
require_relative 'formatter'
require 'tempfile'

module FmtVerifier
  Result = Struct.new(:path, :ok, :error, :diff_excerpt) do
    def status_label
      return "OK" if ok
      return "ERROR" if error
      "DIFFERS"
    end
  end

  module_function

  # Verify a single .cht file. Returns a Result struct.
  #
  # source_dir: directory used by the importer to resolve REQUIRE paths.
  # Defaults to the file's containing directory, which is what `clear`
  # itself uses when transpiling that file directly.
  def verify(cht_path, source_dir: nil)
    abs_path   = File.expand_path(cht_path)
    source_dir ||= File.dirname(abs_path)
    source     = File.read(abs_path)

    before = transpile(source, source_dir)
    formatted = Formatter.format(source)
    after  = transpile(formatted, source_dir)

    norm_before = normalize_for_compare(before)
    norm_after  = normalize_for_compare(after)
    return Result.new(cht_path, true, nil, nil) if norm_before == norm_after
    Result.new(cht_path, false, nil, diff_excerpt(norm_before, norm_after))
  rescue => e
    Result.new(cht_path, false, "#{e.class}: #{e.message}", nil)
  end

  # Strip irrelevant differences from the emitted Zig before comparing:
  #
  # - `// CLR:N` line-number markers — debug metadata mapping a Zig
  #   statement back to the originating CLEAR source line. fmt
  #   intentionally rearranges source (one-liner expansion, blank-line
  #   normalization) so these line numbers shift; the actual code
  #   doesn't change.
  #
  # - `// CLEAR_PROFILE_TASK_SITE ...` — task-site profiling metadata
  #   that embeds line/column coordinates. Same shift, same non-
  #   semantic delta.
  #
  # Rule of thumb: any comment line whose only purpose is "remember
  # where the emitter was when it wrote this," normalize away.
  def normalize_for_compare(zig_source)
    zig_source
      .gsub(%r{^\s*// CLR:\d+\n}, '')
      .gsub(%r{^\s*// CLEAR_PROFILE_TASK_SITE\b[^\n]*\n}, '')
      # Lowering-emitted guard / temp identifiers carry a numeric ID
      # that depends on AST node positions. Equivalent CLEAR programs
      # whose AST shifted under fmt (predicate canonicalization,
      # MUTABLE drop, etc) emit the same Zig logic with different IDs.
      # Normalize the IDs to a placeholder so the byte-compare tracks
      # semantics, not the lowerer's internal counter.
      .gsub(/__([A-Za-z]\w*?)_(\d+)(_\d+)?\b/) { "__#{$1}_N#{$3}" }
  end

  # Verify every .cht file under `dir` (recursive). Useful for sweeping
  # large corpora like benchmarks/ or examples/. Returns an Array of
  # Results in path order.
  def verify_dir(dir)
    paths = Dir.glob(File.join(dir, '**', '*.cht')).sort
    paths.map { |p| verify(p) }
  end

  # Print a one-line summary per result and a totals footer.
  # Returns the count of non-OK results so callers can use it as an
  # exit code: zero on clean, positive on any failure.
  def report(results, io: $stdout)
    fail_count = 0
    results.each do |r|
      label = r.ok ? "\e[32mOK\e[0m" : "\e[31m#{r.status_label}\e[0m"
      io.puts "  #{label}  #{r.path}"
      next if r.ok
      fail_count += 1
      if r.error
        io.puts "        \e[33m#{r.error}\e[0m"
      elsif r.diff_excerpt
        r.diff_excerpt.each_line { |ln| io.puts "        #{ln.chomp}" }
      end
    end
    io.puts ""
    total = results.length
    if fail_count.zero?
      io.puts "  \e[32m#{total} passed, 0 failed.\e[0m"
    else
      io.puts "  \e[31m#{total - fail_count} passed, #{fail_count} failed.\e[0m"
    end
    fail_count
  end

  # ---- internals ----

  def transpile(cheat_code, source_dir)
    importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)
    ZigTranspiler.new(importer: importer, source_dir: source_dir).transpile(cheat_code)
  end

  # Use shell `diff -u` for a familiar unified diff. Truncates to the
  # first ~40 lines of context — enough to see what shifted, not so
  # much that a sweep of N files spams the terminal.
  def diff_excerpt(before, after, max_lines: 40)
    Tempfile.create('before') do |bf|
      Tempfile.create('after') do |af|
        bf.write(before); bf.flush
        af.write(after);  af.flush
        out = `diff -u #{bf.path} #{af.path} 2>&1`
        lines = out.lines
        excerpt = lines.first(max_lines).join
        excerpt += "  ... (#{lines.length - max_lines} more lines)\n" if lines.length > max_lines
        excerpt
      end
    end
  end
end
