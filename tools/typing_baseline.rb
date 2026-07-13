# frozen_string_literal: true

# tools/typing_baseline.rb -- reproducible count of untyped/nilable slots.
#
# Counts T.untyped and T.nilable occurrences split by SLOT CATEGORY:
#   params      -- inside a sig's `params(...)`
#   returns     -- inside a sig's `.returns(...)`
#   structs_ivars -- T.let(@ivar / T.let(self / T::Struct const|prop
#   collections -- T::Array[/T::Hash[/T::Set[/T::Enumerable[ with an
#                  untyped or nilable element
#
# Scope defaults to compiler/ruby/ (the compiler). Pass dirs as ARGV to override.
# Output is deterministic; diff two runs to measure epic progress.

require "json"

DIRS = ARGV.empty? ? %w[compiler/ruby] : ARGV
files = DIRS.flat_map { |d| Dir.glob(File.join(d, "**", "*.rb")) }.sort

C = Hash.new(0)

def scan_segment(seg, cat, counts)
  counts["#{cat}.untyped"] += seg.scan(/T\.untyped/).size
  counts["#{cat}.nilable"] += seg.scan(/T\.nilable\(/).size
end

# Extract balanced (...) starting at the index just after `kw(`.
def balanced(str, start)
  depth = 0
  i = start
  while i < str.length
    c = str[i]
    depth += 1 if c == "("
    if c == ")"
      depth -= 1
      return str[start...i] if depth.zero?
    end
    i += 1
  end
  str[start..]
end

files.each do |f|
  src = File.read(f)

  # Flatten multi-line sig blocks: sig { ... } may span lines.
  src.scan(/\bsig\s*(?:\(:final\)\s*)?\{(.+?)\}\s*(?=\n\s*(?:def |attr_|private|public|protected|sig\b|end))/m) do |m|
    body = m[0].gsub(/\s+/, " ")
    if (pi = body =~ /\bparams\(/)
      scan_segment(balanced(body, pi + "params(".length - 1 + 1), "params", C)
    end
    if (ri = body =~ /\breturns\(/)
      scan_segment(balanced(body, ri + "returns(".length - 1 + 1), "returns", C)
    end
  end

  # ivars / struct slots
  src.scan(/T\.let\(\s*(@|self)/) { C["structs_ivars.let"] += 1 }
  src.scan(/^\s*(?:const|prop)\s+:\w+,\s*(.+)$/) do |m|
    scan_segment(m[0], "structs_ivars", C)
  end

  # collections holding untyped/nilable
  src.scan(/T::(?:Array|Hash|Set|Enumerable|Range)\[[^\]]*\]/) do |coll|
    C["collections.untyped"] += 1 if coll.include?("T.untyped")
    C["collections.nilable"] += 1 if coll.include?("T.nilable")
  end
end

C["TOTAL.untyped"] = src_total = files.sum { |f| File.read(f).scan(/T\.untyped/).size }
C["TOTAL.nilable"] = files.sum { |f| File.read(f).scan(/T\.nilable\(/).size }

puts JSON.pretty_generate(
  scope: DIRS, files: files.size,
  counts: C.sort.to_h
)
