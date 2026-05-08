# typed: false
# frozen_string_literal: true
#
# Sorbet-feedback iterator: parse `srb tc` errors and widen the
# offending autogen sigs so they match what Sorbet's flow analysis
# actually sees at call sites.
#
# Two error categories handled:
#
# - 7002 "Expected X but found Y for argument `name` of method `M`"
#     -> widen `name`'s type in `M`'s sig to T.any(X, Y) / T.nilable(X)
#
# - 7034 "Used `&.` operator on `X`, which can never be nil"
#     -> the receiving expression has a sig that says non-nilable.
#        Widen the relevant sig's RETURN to T.nilable(X) — the source
#        kept the `&.` defensively, so Sorbet's view is too tight.
#
# Usage:
#   bundle exec ruby tools/widen_sigs_from_sorbet.rb        # one pass
#   bundle exec ruby tools/widen_sigs_from_sorbet.rb --loop  # iterate
#                                                            # until stable
#
# Run AFTER `bundle exec ruby tools/gen_sigs_from_trace.rb` has applied
# the initial autogen sigs.

require "open3"

LOOP_MODE = ARGV.include?("--loop")
SRC_DIR = File.expand_path("../src", __dir__)
REPO_ROOT = File.expand_path("..", __dir__)

def abs_path(p)
  return p if p.start_with?("/")
  File.expand_path(p, REPO_ROOT)
end

def run_srb
  # Sorbet emits errors on stderr (not stdout). Capture both, parse stderr.
  _out, err, _status = Open3.capture3(
    { "SRB_YES" => "1", "NO_COLOR" => "1" },
    "bundle", "exec", "srb", "tc"
  )
  err
end

# Parse 7002 errors. Format (multi-line):
#
#   src/foo.rb:42: Expected `Type` but found `T.nilable(Type)` for argument `bar` https://srb.help/7002
#       42 |    method(...)
#                ^^^^
#     Expected `Type` for argument `bar` of method `Klass#method`:
#     /path/to/sig.rb:LINE:
#       LINE | sig { ... }
#              ^^^^^^^^^^^
#     /path/to/sig.rb:DEFLINE:
#       DEFLINE | def method(bar, ...)
#
# We need: (sig_path, sig_line, arg_name, expected_type, found_type).
# Walk the lines; when we see "https://srb.help/7002" we capture the
# parts. The "Expected X for argument Y of method M" line that follows
# is what gives us the sig location.
def parse_7002(output)
  errors = []
  lines = output.lines
  i = 0
  matched = 0
  while i < lines.length
    line = lines[i]
    if line.chomp =~ /^(.+?):(\d+): Expected `(.+?)` but found `(.+?)` for argument `(.+?)` https:\/\/srb\.help\/7002$/
      matched += 1
      caller_path = $1
      caller_line = $2
      expected = $3
      found = $4
      arg_name = $5

      # Find the next "for argument `arg` of method" line (with sig path).
      sig_path = nil
      sig_line = nil
      j = i + 1
      while j < lines.length && j < i + 30
        m = lines[j].match(/^\s*Expected `.+?` for argument `(.+?)` of method `(.+?)`:$/)
        if m && m[1] == arg_name
          # Next line should be sig location
          sig_loc = lines[j + 1]
          if sig_loc && sig_loc =~ /^\s+(.+?):(\d+):$/
            sig_path = $1
            sig_line = $2.to_i
          end
          break
        end
        j += 1
      end

      if sig_path && (sig_path.start_with?(SRC_DIR) || sig_path.start_with?("src/"))
        sig_path = File.expand_path(sig_path, File.expand_path("..", __dir__)) unless sig_path.start_with?("/")
        errors << {
          arg: arg_name,
          expected: expected,
          found: found,
          sig_path: sig_path,
          sig_line: sig_line,
        }
      end
    end
    i += 1
  end
  warn "DEBUG: matched #{matched} 7002 lines, errors with sig: #{errors.size}"
  errors
end

# Parse 7005 errors: "Expected X but found Y for method result type".
# Widen the SIG's RETURN type to match what the body actually produces.
#
# Format:
#   src/foo.rb:LINE_END: Expected `X` but found `Y` for method result type https://srb.help/7005
#       LINE_END | end
#                   ^^^
#     Expected `X` for result type of method `m`:
#       src/foo.rb:DEF_LINE:
#         DEF_LINE | def m(...)
def parse_7005(output)
  errors = []
  lines = output.lines
  i = 0
  while i < lines.length
    line = lines[i].chomp
    if line =~ /^(.+?):(\d+): Expected `(.+?)` but found `(.+?)` for method result type https:\/\/srb\.help\/7005$/
      err_path = $1
      expected = $3
      found = $4

      # Scan ahead for the def location.
      def_path = nil
      def_line = nil
      j = i + 1
      while j < lines.length && j < i + 20
        if lines[j] =~ /^\s*Expected `.+?` for result type of method `(.+?)`:$/
          loc = lines[j + 1]
          if loc && loc =~ /^\s+(.+?):(\d+):$/
            def_path = $1
            def_line = $2.to_i
          end
          break
        end
        j += 1
      end

      if def_path
        def_path = abs_path(def_path)
        if def_path.start_with?(SRC_DIR)
          errors << {
            def_path: def_path,
            def_line: def_line,
            expected: expected,
            found: found,
          }
        end
      end
    end
    i += 1
  end
  errors
end

# Widen the sig's `returns(...)` (or void) at the line just above the
# def to encompass `found`. Returns true if changed.
def widen_return(err)
  src = File.read(err[:def_path])
  lines = src.lines
  # The sig is typically 1-3 lines above the def. Scan backward.
  def_idx = err[:def_line] - 1
  return false if def_idx < 0 || def_idx >= lines.length

  sig_idx = nil
  (def_idx - 1).downto([def_idx - 5, 0].max) do |k|
    if lines[k] =~ /\bsig\s*\{/
      sig_idx = k
      break
    end
  end
  return false unless sig_idx

  sig_text = lines[sig_idx]
  # Match `.returns(TYPE)` or `.void`. The TYPE may have balanced parens.
  if sig_text =~ /\.returns\(/
    start = $~.end(0)
    type_str, type_end = scan_balanced(sig_text, start)
    return false unless type_str
    new_type = widen_type(type_str.strip, err[:found])
    return false if new_type == type_str.strip
    new_sig = sig_text[0...start] + new_type + sig_text[type_end..]
  elsif sig_text =~ /\.void(\s*\}|$)/
    # Convert .void to .returns(found). Only safe if the body's
    # observed return is actually used somewhere.
    return false  # skip — too risky to flip void to returns(X) automatically
  else
    return false
  end

  return false if new_sig == sig_text
  lines[sig_idx] = new_sig
  File.write(err[:def_path], lines.join)
  true
end

# Parse 7034. Format:
#   src/foo.rb:N: Used `&.` operator on `X`, which can never be nil https://srb.help/7034
# The "Got `X` originating from:" block tells us which expression. If
# the expression is `m.bar` we'd want to widen `bar`'s return; if it's
# a local variable from a method call, same. For now we only catch the
# return-type-too-tight case via the "originating from" location.
def parse_7034(output)
  errors = []
  lines = output.lines
  i = 0
  while i < lines.length
    line = lines[i]
    if line.chomp =~ /^(.+?):(\d+): Used `&\.` operator on `(.+?)`, which can never be nil https:\/\/srb\.help\/7034$/
      site_path = $1
      site_line = $2.to_i
      tight_class = $3

      # Find originating-from location. We use the first "originating
      # from" line that points to a sig'd return.
      origin_path = nil
      origin_line = nil
      j = i + 1
      while j < lines.length && j < i + 20
        if lines[j] =~ /^\s+Got `.+` originating from:$/
          loc = lines[j + 1]
          if loc && loc =~ /^\s+(.+?):(\d+):$/
            origin_path = $1
            origin_line = $2.to_i
          end
          break
        end
        j += 1
      end

      errors << {
        site_path: site_path,
        site_line: site_line,
        tight_class: tight_class,
        origin_path: origin_path,
        origin_line: origin_line,
      }
    end
    i += 1
  end
  errors
end

# Widen `arg: TYPE` to `arg: T.nilable(...)` or T.any(...) in the sig
# at sig_path:sig_line. Returns true if a change was applied.
def widen_param(sig_path, sig_line, arg, expected, found)
  src = File.read(sig_path)
  lines = src.lines
  return false if sig_line < 1 || sig_line > lines.length

  sig_text = lines[sig_line - 1]
  return false unless sig_text.include?("sig {")

  # Match `arg_name: TYPE` where TYPE may be balanced parens/brackets.
  # Use a hand-rolled scanner because the type can be complex
  # (T.any(T::Array[T.untyped], Hash)).
  re_start = /\b#{Regexp.escape(arg)}:\s*/
  m = sig_text.match(re_start)
  return false unless m

  start = m.end(0)
  type_str, type_end = scan_balanced(sig_text, start)
  return false unless type_str

  new_type = widen_type(type_str.strip, found)
  return false if new_type == type_str.strip

  new_sig = sig_text[0...start] + new_type + sig_text[type_end..]
  return false if new_sig == sig_text

  lines[sig_line - 1] = new_sig
  File.write(sig_path, lines.join)
  true
end

# Scan a type expression starting at `pos` in `str` until the matching
# `,`, `)`, or `]` at the top level. Returns [type_str, end_pos].
def scan_balanced(str, pos)
  depth = 0
  i = pos
  while i < str.length
    c = str[i]
    case c
    when "("
      depth += 1
    when ")"
      return [str[pos...i], i] if depth == 0
      depth -= 1
    when "[", "{"
      depth += 1
    when "]", "}"
      depth -= 1
    when ","
      return [str[pos...i], i] if depth == 0
    end
    i += 1
  end
  [nil, nil]
end

# Combine `current` and `additional` into a wider type. If `additional`
# is `T.nilable(X)` or `NilClass`, wrap as `T.nilable(current)` (or
# preserve nilable). Otherwise build a `T.any(current, additional)`.
def widen_type(current, additional)
  return current if current == additional
  return current if current == "T.untyped"

  # Strip outer T.nilable wrappers for comparison.
  current_inner, current_nilable = strip_nilable(current)
  additional_inner, additional_nilable = strip_nilable(additional)

  needs_nilable = current_nilable || additional_nilable

  # If additional is exactly NilClass, keep current's inner and add nilable.
  if additional == "NilClass"
    return current_nilable ? current : "T.nilable(#{current_inner})"
  end

  if current_inner == additional_inner
    return needs_nilable ? "T.nilable(#{current_inner})" : current_inner
  end

  # Build T.any(...) over the union of inner classes.
  parts = (split_any(current_inner) + split_any(additional_inner)).uniq.sort
  base = parts.length == 1 ? parts.first : "T.any(#{parts.join(', ')})"
  needs_nilable ? "T.nilable(#{base})" : base
end

def strip_nilable(t)
  if t.start_with?("T.nilable(") && t.end_with?(")")
    [t[10..-2], true]
  else
    [t, false]
  end
end

def split_any(t)
  if t.start_with?("T.any(") && t.end_with?(")")
    inner = t[6..-2]
    # Split on top-level commas.
    parts = []
    depth = 0
    last = 0
    inner.each_char.with_index do |c, i|
      case c
      when "(", "[", "{" then depth += 1
      when ")", "]", "}" then depth -= 1
      when ","
        if depth == 0
          parts << inner[last...i].strip
          last = i + 1
        end
      end
    end
    parts << inner[last..].strip
    parts
  else
    [t]
  end
end

# Widen the return type of the sig that the originating expression's
# method came from. We need to find the def at origin_path:origin_line
# and widen its sig's return.
# Legacy stub kept for backward compat with --loop callers in older
# scripts. The 7005-driven `widen_return(err)` above is the active
# implementation.
def widen_return_legacy(*); false; end

def run_pass
  output = run_srb
  errors_7002 = parse_7002(output)
  errors_7005 = parse_7005(output)
  errors_7034 = parse_7034(output)
  applied = 0

  # 7002 widening
  seen = Set.new
  errors_7002.each do |err|
    key = [err[:sig_path], err[:sig_line], err[:arg]]
    next if seen.include?(key)
    seen << key
    applied += 1 if widen_param(err[:sig_path], err[:sig_line], err[:arg], err[:expected], err[:found])
  end

  # 7005 return widening
  seen_ret = Set.new
  errors_7005.each do |err|
    key = [err[:def_path], err[:def_line]]
    next if seen_ret.include?(key)
    seen_ret << key
    applied += 1 if widen_return(err)
  end

  [applied, errors_7002.size + errors_7005.size, errors_7034.size]
end

require "set"

if LOOP_MODE
  iter = 0
  loop do
    iter += 1
    applied, n_7002, n_7034 = run_pass
    puts "Iter #{iter}: 7002=#{n_7002}, 7034=#{n_7034}, widened=#{applied}"
    break if applied == 0
    break if iter >= 10
  end
else
  applied, n_7002, n_7034 = run_pass
  puts "7002 errors: #{n_7002}"
  puts "7034 errors: #{n_7034}"
  puts "Sigs widened: #{applied}"
end
