# typed: false
# frozen_string_literal: true
#
# Caller-side autofixer. Parses `srb tc` errors and wraps the offending
# expression with `T.must(...)` so the call site asserts non-nil and
# Sorbet's check passes. Runs to fixpoint.
#
# Handles two error categories:
#
# - 7002 "Expected X but found T.nilable(X) for argument Y"
#     -> wrap the caller arg expression with T.must
#
# - 7003 "Method M does not exist on NilClass component of T.nilable(X)"
#     -> wrap the receiver of `.M` with T.must
#
# Sorbet's error message includes the column range (via `^^^^` underline)
# pointing at the failing expression. We use that to splice T.must in.
#
# Usage:
#   bundle exec ruby tools/fix_callers_from_sorbet.rb         # one pass
#   bundle exec ruby tools/fix_callers_from_sorbet.rb --loop  # iterate
#
# Run AFTER `bundle exec ruby tools/gen_sigs_from_trace.rb` has applied
# the initial autogen sigs.

require "open3"
require "set"

LOOP_MODE = ARGV.include?("--loop")
DRY_RUN = ARGV.include?("--dry-run")
SRC_DIR = File.expand_path("../src", __dir__)
REPO_ROOT = File.expand_path("..", __dir__)

def run_srb
  _out, err, _status = Open3.capture3(
    { "SRB_YES" => "1", "NO_COLOR" => "1" },
    "bundle", "exec", "srb", "tc"
  )
  err
end

# Resolve a sorbet-relative path (`src/foo.rb`) to absolute.
def abs_path(p)
  return p if p.start_with?("/")
  File.expand_path(p, REPO_ROOT)
end

# Parse 7002 / 7003 error blocks. Each block is several lines:
#
#   src/foo.rb:LINE: Expected `X` but found `Y` for argument `arg` https://srb.help/7002
#       LINE | code...
#                    ^^^^^^   ← caret underline (col span)
#
# or:
#
#   src/foo.rb:LINE: Method `m` does not exist on `NilClass` ...     https://srb.help/7003
#       LINE | obj.m(...)
#              ^^^   ← caret underline (col span of the receiver)
#
# Returns array of:
#   { path:, line:, col_start:, col_end: }
#
# We don't need to know which error type — we just splice T.must
# around the underlined span.
def parse_caller_fixes(output)
  fixes = []
  lines = output.lines
  i = 0
  while i < lines.length
    line = lines[i].chomp
    if line =~ /srb\.help\/7002$/ || line =~ /srb\.help\/7003$/
      # Get the file:line from the error line
      next_unless = line.match(/^(.+?):(\d+):/)
      unless next_unless
        i += 1
        next
      end
      path = abs_path(next_unless[1])
      err_line = next_unless[2].to_i

      # Look at the next 1-3 lines for the source-pointer + caret
      # Format:
      #   ` 100 |    code here`
      #   `              ^^^^^^^`
      #
      # Find the caret line.
      caret_idx = nil
      (i + 1..i + 3).each do |k|
        next if k >= lines.length
        if lines[k].match?(/^\s+\^+\s*$/)
          caret_idx = k
          break
        end
      end
      i += 1 and next unless caret_idx

      # The line above the caret has the source. Compute the column
      # span by finding where ^^^ aligns with the source line.
      caret_line = lines[caret_idx]
      caret_match = caret_line.match(/^(\s+)(\^+)/)
      i += 1 and next unless caret_match
      caret_col = caret_match[1].length
      caret_len = caret_match[2].length

      # The source line is the line above caret. Sorbet renders it as
      # `   100 |    code here`. The first `|` separates the line
      # number from the source. Compute the offset to find the actual
      # column in the file.
      src_line_str = lines[caret_idx - 1]
      pipe_pos = src_line_str.index(" | ")
      i += 1 and next unless pipe_pos
      src_col_offset = pipe_pos + 3  # length of " | " = 3

      # The caret column is in the rendered text; subtract the offset
      # to get column in the actual source line.
      file_col_start = caret_col - src_col_offset
      file_col_end = file_col_start + caret_len

      if file_col_start >= 0 && path.start_with?(SRC_DIR)
        fixes << {
          path: path,
          line: err_line,
          col_start: file_col_start,
          col_end: file_col_end,
        }
      end
    end
    i += 1
  end
  fixes
end

# Wrap the source slice [col_start, col_end) on `path:line` with
# `T.must(...)`. Skips if the slice already starts with `T.must(`.
# Returns true if a change was applied.
def wrap_with_t_must(fix)
  src = File.read(fix[:path])
  lines = src.lines
  return false if fix[:line] < 1 || fix[:line] > lines.length

  line = lines[fix[:line] - 1]
  cs = fix[:col_start]
  ce = fix[:col_end]
  return false if cs < 0 || ce > line.length || cs >= ce

  expr = line[cs...ce]
  return false if expr.empty?
  return false if expr.start_with?("T.must(")
  return false if expr.start_with?("T.unsafe(")
  # Also skip if the expression is already wrapped — sometimes Sorbet
  # points at `T.must(x).bar` and the `.bar` is the issue.
  return false if expr =~ /^T\.must\(.*\)$/

  new_line = line[0...cs] + "T.must(#{expr})" + line[ce..]
  return false if new_line == line

  lines[fix[:line] - 1] = new_line
  File.write(fix[:path], lines.join) unless DRY_RUN
  true
end

def run_pass
  output = run_srb
  fixes = parse_caller_fixes(output)

  # Group fixes by (path, line) and apply only ONE per line per pass —
  # multiple T.must wrappings on the same line shift columns and corrupt
  # subsequent edits. The next iteration picks up remaining fixes.
  applied = 0
  seen_lines = Set.new
  # Reverse-sort by column so that wrapping inside a longer span on
  # the same line doesn't shift the larger span's coordinates.
  fixes.sort_by { |f| [-f[:line], -f[:col_start]] }.each do |fix|
    key = [fix[:path], fix[:line]]
    next if seen_lines.include?(key)
    seen_lines << key
    applied += 1 if wrap_with_t_must(fix)
  end

  [applied, fixes.size]
end

if LOOP_MODE
  iter = 0
  prev_total = nil
  loop do
    iter += 1
    applied, total = run_pass
    puts "Iter #{iter}: errors=#{total}, T.must wrapped=#{applied}"
    break if applied == 0
    break if iter >= 15
    break if prev_total && total >= prev_total  # not making progress
    prev_total = total
  end
else
  applied, total = run_pass
  puts "Caller-side errors (7002+7003): #{total}"
  puts "T.must wrappings applied: #{applied}"
end
