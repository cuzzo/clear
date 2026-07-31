#!/usr/bin/env ruby
# frozen_string_literal: true

# Finds ruby-to-clear regressions by comparing generated CLEAR against a golden
# tree, without invoking the CLEAR compiler.
#
# The verifier is fail-fast and serialized behind shared providers: one bad line
# in ast/type.clear hides every other defect in the corpus, so a cold run only
# ever reveals the next single blocker. Generated CLEAR from a known-better
# revision is a complete oracle for the same information, available in seconds.
#
#   ruby tools/rtoc_regression_scan.rb --golden GOLDEN_SRC --new NEW_SRC
#
# Both paths are `raw/compiler/src` trees produced by ruby-to-clear-verify.

require "json"
require "optparse"
require "set"
require "fileutils"
require "etc"
require "zlib"
require "stringio"

# The frozen oracle is 2.5MB of JSON and compresses ~10x, so it is stored
# gzipped to keep it a reasonable thing to check in.
def read_facts(path)
  raw = File.binread(path)
  raw = Zlib::GzipReader.new(StringIO.new(raw)).read if path.end_with?(".gz")
  JSON.parse(raw)
end

def write_facts(path, data)
  json = JSON.generate(data)
  return File.write(path, json) unless path.end_with?(".gz")

  Zlib::GzipWriter.open(path) { |gz| gz.write(json) }
end

# A binding fact is what the frontend needs and cannot re-derive: whether a name
# was declared, its declared type, and whether its initializer materialized
# ownership or fallibility. Losing any of these is a regression even when the
# surrounding text legitimately changed.
BindingFact = Struct.new(:fn, :name, :declared, :type, :prefix, :rhs, :line, :deferred, keyword_init: true)

DECL = /^\s*(?:PUB\s+)?MUTABLE\s+([A-Za-z_]\w*)\s*(?::\s*([^=]+?))?\s*=\s*(.*)$/
ASSIGN = /^\s*([A-Za-z_]\w*)\s*=\s*(.*)$/
FN_START = /^\s*(?:PUB\s+|PRIVATE\s+)?FN\s+([A-Za-z_]\w*)/

# COPY/KEEP/GIVE and TRY are the materialization markers lowering must emit from
# facts; UNWRAP and CAST change what the value IS. A rendered initializer that
# drops one silently changes ownership or fallibility.
PREFIXES = %w[COPY KEEP GIVE OWN TRY UNWRAP CAST].freeze

def initializer_prefix(rhs)
  PREFIXES.find { |p| rhs.start_with?("#{p} ", "#{p}(") } || ""
end

# A binding may be predeclared with its type's default and then assigned by a
# following statement MATCH/IF. That is equivalent to an inline initializer, so
# the declaration line alone is not the whole fact -- reporting it as a loss
# manufactures work on correct output.
def reassigned_after?(lines, idx, name)
  # The assignment may sit inside a MATCH arm (`Variant AS item -> name = ...`),
  # so it is not anchored to the start of the line.
  lines[(idx + 1)..(idx + 12)].to_a.any? { |l| l =~ /(?<![\w.])#{Regexp.escape(name)}\s*=[^=]/ }
end

def facts_for(path)
  fn = "<file>"
  facts = {}
  lines = File.readlines(path)
  lines.each_with_index do |line, idx|
    if (m = FN_START.match(line))
      fn = m[1]
    end
    if (m = DECL.match(line))
      key = "#{fn}##{m[1]}"
      facts[key] ||= BindingFact.new(
        fn: fn, name: m[1], declared: true, type: m[2].to_s.strip,
        prefix: initializer_prefix(m[3].to_s.strip), rhs: m[3].to_s.strip[0, 240], line: idx + 1,
        deferred: reassigned_after?(lines, idx, m[1])
      )
    elsif (m = ASSIGN.match(line))
      key = "#{fn}##{m[1]}"
      facts[key] ||= BindingFact.new(
        fn: fn, name: m[1], declared: false, type: "",
        prefix: initializer_prefix(m[2].to_s.strip), rhs: m[2].to_s.strip[0, 240], line: idx + 1
      )
    end
  end
  facts
end

# A marker moving position is not a loss: `TRY (f)` becoming `UNWRAP (TRY (f))`
# still propagates, and `CAST(x AS T)` becoming a generated castXToY helper is
# the same conversion by another mechanism. Only a marker that disappears from
# the initializer entirely has been dropped.
CAST_HELPER = /\bcast[A-Z]\w*\(/.freeze

def marker_preserved?(prefix, new_fact)
  rhs = new_fact.rhs.to_s
  return true if rhs.include?("#{prefix} ") || rhs.include?("#{prefix}(")
  return true if prefix == "CAST" && (CAST_HELPER.match?(rhs) || rhs.include?(" AS "))

  false
end

# Only losses are reported. The rebuild legitimately changed output shape all
# over the corpus, so equality is the wrong oracle -- a dropped fact is not.
def regressions_for(rel, golden, new)
  out = []
  golden.each do |key, g|
    n = new[key]
    next unless n
    # Either side deferring its real value to a following assignment makes the
    # declaration-line comparison meaningless.
    next if g.deferred || n.deferred

    if g.declared && !n.declared
      out << { kind: "LOST_DECLARATION", file: rel, name: g.name, fn: g.fn,
               golden: "MUTABLE #{g.name}: #{g.type} = ...", new: "#{n.name} = ...",
               golden_line: g.line, new_line: n.line }
    elsif g.declared && n.declared && !g.type.empty? && n.type.empty?
      out << { kind: "LOST_TYPE_ANNOTATION", file: rel, name: g.name, fn: g.fn,
               golden: "MUTABLE #{g.name}: #{g.type}", new: "MUTABLE #{n.name}",
               golden_line: g.line, new_line: n.line }
    end
    next if g.prefix.empty? || marker_preserved?(g.prefix, n)

    out << { kind: "LOST_#{g.prefix}", file: rel, name: g.name, fn: g.fn,
             golden: "#{g.name} = #{g.prefix} ...", new: "#{n.name} = #{n.prefix.empty? ? '' : "#{n.prefix} "}...",
             golden_line: g.line, new_line: n.line }
  end
  out
end

options = {}
OptionParser.new do |o|
  o.on("--golden DIR") { |v| options[:golden] = v }
  o.on("--new DIR") { |v| options[:new] = v }
  o.on("--json PATH") { |v| options[:json] = v }
  o.on("--emit-facts PATH", "freeze the golden tree's facts so the oracle outlives tmp/") { |v| options[:emit_facts] = v }
  o.on("--facts PATH", "compare against frozen facts instead of a golden tree") { |v| options[:facts] = v }
  o.on("--regen REPORT", "transpile each corpus source with the current gem into a fresh tree first") { |v| options[:regen] = v }
  o.on("--only REGEX", "restrict regen and comparison to matching generated paths") { |v| options[:only] = Regexp.new(v) }
  o.on("--jobs N", Integer, "parallel regen workers (default: all cores)") { |v| options[:jobs] = v }
end.parse!

# Freezing facts keeps the oracle after the per-revision artifact tree is pruned.
if options[:emit_facts]
  abort "--emit-facts needs --golden" unless options[:golden]

  root = File.expand_path(options[:golden])
  frozen = Dir.glob("**/*.clear", base: root).sort.to_h do |rel|
    [rel, facts_for(File.join(root, rel)).transform_values(&:to_h)]
  end
  write_facts(options[:emit_facts], frozen)
  puts "wrote golden facts for #{frozen.size} file(s) to #{options[:emit_facts]}"
  exit 0
end

# Regenerating only the corpus sources with the current gem gives the tight loop:
# edit the transpiler, rerun, watch the finding count fall. No CLEAR compiler.
if options[:regen]
  require "tmpdir"

  report = JSON.parse(File.read(options[:regen]))
  out_root = options[:new] ? File.expand_path(options[:new]) : Dir.mktmpdir("rtoc-regen")
  units = report.fetch("units")
  units = units.select { |u| options[:only].match?(u.fetch("generated_relative")) } if options[:only]

  # One unit takes seconds to minutes to transpile (mir_lowering.rb alone is
  # ~240s), so a serial sweep of the corpus is unusable as a feedback loop.
  # Transpiles are independent, so fork one per unit and cap concurrency.
  jobs = options[:jobs] || Etc.nprocessors
  # Longest first: the tail is dominated by a few huge units, so starting them
  # last would leave 31 idle cores waiting on one straggler.
  queue = units.sort_by { |u| -u.fetch("source_loc", 0) }
  running = {}
  started = Time.now
  until queue.empty? && running.empty?
    while running.size < jobs && !queue.empty?
      unit = queue.shift
      dest = File.join(out_root, unit.fetch("generated_relative"))
      FileUtils.mkdir_p(File.dirname(dest))
      # Replay the verifier's own transpile argv (--strict, --helper-config,
      # --cfg-facts) against the current gem. Calling the library in-process
      # instead drops those inputs, which changes what the transpiler accepts
      # and would report differences the verifier never sees.
      argv = unit.fetch("commands").fetch("transpile").fetch("argv")
      pid = Process.spawn(*argv, out: dest, err: "#{dest}.stderr")
      running[pid] = unit
    end
    pid, status = Process.wait2
    unit = running.delete(pid)
    warn "regen nonzero #{unit.fetch('source')} (#{status.exitstatus})" if unit && !status.success?
  end
  options[:new] = out_root
  puts "regenerated #{units.size} unit(s) into #{out_root} in #{(Time.now - started).round(1)}s on #{jobs} job(s)"
end

abort "--new is required" unless options[:new]
abort "--golden or --facts is required" unless options[:golden] || options[:facts]

new_root = File.expand_path(options[:new])
frozen_facts = options[:facts] ? read_facts(options[:facts]) : nil
golden_root = options[:golden] ? File.expand_path(options[:golden]) : nil

golden_files = frozen_facts ? frozen_facts.keys.sort : Dir.glob("**/*.clear", base: golden_root).sort
golden_files = golden_files.grep(options[:only]) if options[:only]

findings = []
missing = []
golden_files.each do |rel|
  new_path = File.join(new_root, rel)
  unless File.exist?(new_path)
    missing << rel
    next
  end
  golden = if frozen_facts
    frozen_facts.fetch(rel).transform_values { |h| BindingFact.new(**h.transform_keys(&:to_sym)) }
  else
    facts_for(File.join(golden_root, rel))
  end
  findings.concat(regressions_for(rel, golden, facts_for(new_path)))
end

by_file = findings.group_by { |f| f[:file] }
puts "generated files compared: #{golden_files.size}"
puts "files missing from new tree: #{missing.size}"
puts "regression findings: #{findings.size} across #{by_file.size} file(s)"
puts

by_file.sort_by { |file, fs| [-fs.size, file] }.each do |file, fs|
  puts "#{file}  (#{fs.size} finding(s))"
  fs.group_by { |f| f[:kind] }.sort_by { |k, v| [-v.size, k] }.each do |kind, group|
    puts "  #{kind} x#{group.size}"
    group.first(6).each do |f|
      puts "    #{f[:fn]}##{f[:name]}  golden:#{f[:golden_line]} -> new:#{f[:new_line]}"
      puts "      golden: #{f[:golden]}"
      puts "      new:    #{f[:new]}"
    end
    puts "    ... #{group.size - 6} more" if group.size > 6
  end
  puts
end

puts "Kind totals:"
findings.group_by { |f| f[:kind] }.sort_by { |k, v| [-v.size, k] }.each { |k, v| puts "  #{v.size.to_s.rjust(4)}  #{k}" }

File.write(options[:json], JSON.pretty_generate(findings)) if options[:json]
