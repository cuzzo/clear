# typed: false
# frozen_string_literal: true
#
# Run `srb tc -a` repeatedly until errors stabilize, but PRESERVE all
# `&.` (safe-navigation) operators in src/. Sorbet's 7034 autocorrect
# removes `&.` whenever its (possibly observation-tight) sig analysis
# proves the receiver non-nil — but at runtime those `&.` were
# defensive against paths the corpus didn't exercise (e.g. AST nodes
# in test fixtures with nil captures). Stripping them breaks tests.
#
# Approach: snapshot every `&.` location in src/ before running -a,
# then after -a restore any line that lost a `&.` while otherwise
# matching the post-autocorrect line. Sorbet's other autocorrects
# (T.must wraps, etc.) are kept.
#
# Usage:
#   bundle exec ruby tools/safe_autocorrect.rb
#
# Run AFTER `bundle exec ruby tools/gen_sigs_from_trace.rb`.

require "open3"

SRC_DIR = File.expand_path("../src", __dir__)

def src_files
  Dir.glob(File.join(SRC_DIR, "**", "*.rb"))
end

# Returns { path => [{ line: N, content: "..." }, ...] } for every
# line in src/ that contains a `&.` operator (anywhere, regardless
# of whether it's actually a method call).
def snapshot_safe_navigation
  snap = {}
  src_files.each do |path|
    content = File.read(path)
    content.lines.each_with_index do |line, idx|
      next unless line.include?("&.")
      snap[path] ||= []
      snap[path] << { line: idx + 1, content: line }
    end
  end
  snap
end

# Whole-file snapshot for detecting "did you mean" autocorrect damage.
# Returns { path => [line1, line2, ...] }.
def snapshot_full_files
  src_files.each_with_object({}) do |path, h|
    h[path] = File.readlines(path)
  end
end

# Patterns that almost always indicate a Sorbet "did you mean"
# autocorrect gone wrong: it replaced a method we actually had with a
# similarly-named Class/Module reflection method whose semantics are
# entirely different. Real code basically never writes these.
BOGUS_AUTOCORRECT_PATTERNS = [
  /\.class\.module_eval\b/,
  /\.class\.class_eval\b/,
  # Add more as we find them.
].freeze

# After -a, walk every snapshot entry and revert any line that gained
# a bogus pattern. Sorbet's "did you mean" suggester maps unrecognised
# methods to similarly-named ones from the receiver's class — when the
# receiver is `node.class` (a Class), it picks up Module/Class methods
# like `module_eval`, but the original code wanted `node.module_alias`.
def restore_bogus_replacements(pre)
  restored = 0
  pre.each do |path, original_lines|
    next unless File.exist?(path)
    current = File.readlines(path)
    changed = false
    current.each_with_index do |line, i|
      next unless original_lines[i] && line != original_lines[i]
      next unless BOGUS_AUTOCORRECT_PATTERNS.any? { |re| line.match?(re) && !original_lines[i].match?(re) }
      current[i] = original_lines[i]
      restored += 1
      changed = true
    end
    File.write(path, current.join) if changed
  end
  restored
end

# After -a, walk every snapshot entry and check if the same line in
# the file (1) still exists, (2) lost the `&.` (now contains `.X`
# where X was previously `&.X`). Restore those lines.
#
# We're conservative: only restore if the new line equals the old line
# with `&.` replaced by `.` somewhere. That ensures we don't trample
# unrelated edits.
def restore_safe_navigation(snap)
  restored = 0
  snap.each do |path, entries|
    next unless File.exist?(path)
    lines = File.readlines(path)
    changed = false
    entries.each do |entry|
      idx = entry[:line] - 1
      next if idx >= lines.length
      cur = lines[idx]
      orig = entry[:content]
      next if cur == orig

      # Did the autocorrect remove `&.` from this line? Compare by
      # transforming current → would-be-orig: insert `&` before any
      # `.` that's at a position where the orig had `&.`. The simplest
      # correct check: replace each `&.` in orig with `.` and see if
      # it matches the current line.
      orig_stripped = orig.gsub("&.", ".")
      if cur == orig_stripped
        lines[idx] = orig
        restored += 1
        changed = true
      end
    end
    File.write(path, lines.join) if changed
  end
  restored
end

def run_srb_a
  _out, err, _status = Open3.capture3(
    { "SRB_YES" => "1", "NO_COLOR" => "1" },
    "bundle", "exec", "srb", "tc", "-a"
  )
  err
end

def srb_error_count
  _out, err, _status = Open3.capture3(
    { "SRB_YES" => "1", "NO_COLOR" => "1" },
    "bundle", "exec", "srb", "tc"
  )
  m = err.match(/Errors: (\d+)/)
  m ? m[1].to_i : nil
end

iter = 0
prev_count = nil
loop do
  iter += 1
  snap = snapshot_safe_navigation
  full_snap = snapshot_full_files
  run_srb_a
  restored = restore_safe_navigation(snap)
  bogus = restore_bogus_replacements(full_snap)
  count = srb_error_count
  puts "Iter #{iter}: errors=#{count}, &. restored=#{restored}, bogus reverted=#{bogus}"
  break if count.nil?
  break if iter >= 8
  break if prev_count && count >= prev_count && restored == 0 && bogus == 0
  prev_count = count
end
