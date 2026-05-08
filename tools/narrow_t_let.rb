# typed: false
# frozen_string_literal: true
#
# Narrow `T.let(value, T.untyped)` declarations using runtime
# observation from tools/trace_t_let.rb.
#
# For each (file, line) where T.let was called, the tracer recorded
# the value's class at every invocation. If the line's source
# contains `T.let(..., T.untyped)` and observation has a single class
# (no nil), narrow `T.untyped` to that class.
#
# Threshold: MIN_OBSERVATIONS=20 calls before narrowing — same as
# tools/narrow_generics.rb. Skip AST::*/MIR::* polymorphic singletons.
# Returns the same conservative `fmt_set` policy.
#
# Usage:
#   bundle exec ruby tools/narrow_t_let.rb
#   DRY_RUN=1 bundle exec ruby tools/narrow_t_let.rb

require "json"
require "set"

OBS_DIR = File.expand_path("../tmp/sig_obs_tlet", __dir__)
SRC_DIR = File.expand_path("../src", __dir__)
DRY_RUN = ENV["DRY_RUN"] == "1"
MIN_OBSERVATIONS = ENV.fetch("MIN_OBSERVATIONS", "20").to_i

# Aggregate observations: { [path, line] => Set of classes }
records = Hash.new { |h, k| h[k] = { calls: 0, classes: Set.new } }

Dir.glob(File.join(OBS_DIR, "*.jsonl")).each do |file|
  File.foreach(file) do |line|
    obs = JSON.parse(line)
    key = [obs["path"], obs["line"]]
    records[key][:calls] += obs["calls"]
    obs["classes"].each { |c| records[key][:classes] << c }
  end
end
puts "Loaded #{records.size} (file, line) records"

def narrow_class_set(set)
  set = set.to_a.reject { |c| c.nil? || c.empty? }
  return nil if set.empty?
  has_nil = set.include?("NilClass")
  others = set.reject { |c| c == "NilClass" }
  return nil if others.empty?
  others = others.reject { |c| c.include?("#") || c.start_with?("Sorbet::Private::") }
  return nil if others.empty?
  return nil if others.size > 1  # Multi-class — too risky to narrow
  cls = others.first
  return nil if cls.start_with?("AST::") || cls.start_with?("MIR::")
  has_nil ? "T.nilable(#{cls})" : cls
end

total_narrowed = 0
files_changed = 0

# Group records by file.
by_file = Hash.new { |h, k| h[k] = [] }
records.each do |(path, line_no), rec|
  next if rec[:calls] < MIN_OBSERVATIONS
  next unless path&.start_with?(SRC_DIR)
  by_file[path] << [line_no, rec]
end

by_file.each do |path, entries|
  next unless File.exist?(path)
  lines = File.readlines(path)
  changed = false
  entries.each do |line_no, rec|
    idx = line_no - 1
    next if idx < 0 || idx >= lines.length
    line = lines[idx]
    # Match `T.let(VALUE, T.untyped)` and replace `T.untyped` with the
    # narrowed type. Use a balanced scan so VALUE can have nested
    # parens.
    m = line.match(/T\.let\(/)
    next unless m
    open_idx = m.end(0)
    depth = 1
    pos = open_idx
    comma_idx = nil
    while pos < line.length && depth > 0
      c = line[pos]
      case c
      when "(", "[", "{" then depth += 1
      when ")", "]", "}"
        depth -= 1
        break if depth == 0
      when ","
        if depth == 1
          comma_idx = pos
          # don't break — we want the LAST top-level comma so that
          # T.let(map { |k| ... }, T.untyped) splits correctly. Actually
          # T.let takes exactly 2 args, so the LAST comma at depth==1
          # IS the separator. But the simplest: assume one comma.
        end
      end
      pos += 1
    end
    next unless comma_idx
    # The arg after the comma until close paren
    type_start = comma_idx + 1
    type_end = pos  # position of close paren
    type_str = line[type_start...type_end].strip
    next unless type_str == "T.untyped"

    new_type = narrow_class_set(rec[:classes])
    next unless new_type

    new_line = line[0...type_start] + " #{new_type}" + line[type_end..]
    next if new_line == line

    lines[idx] = new_line
    total_narrowed += 1
    changed = true
  end
  if changed
    if DRY_RUN
      puts "DRY: #{path}"
    else
      File.write(path, lines.join)
    end
    files_changed += 1
  end
end

puts
puts "==== Stats ===="
puts "  T.let(..., T.untyped) narrowings: #{total_narrowed}"
puts "  Files changed:                    #{files_changed}"
puts "  Min observations:                 #{MIN_OBSERVATIONS}"
puts DRY_RUN ? "  (DRY_RUN — no files modified)" : "  Applied to disk."
