# frozen_string_literal: true

# WIP: hub/god-component and Martin-instability report over an Espalier
# architecture artifact, churn-weighted via git history.
#
# Usage: ruby hub_report.rb architecture.json [repo_root]

require "json"

artifact = JSON.parse(File.read(ARGV[0]))
repo = ARGV[1] || Dir.pwd

nodes = artifact.fetch("nodes")
edges = artifact.fetch("edges")

node_by_id = nodes.to_h { |n| [n["id"], n] }

def unit_for(node)
  path = node["path"]
  return nil unless path && node["id"].start_with?("fn:")
  # class/module owner if present, else file
  owner = node["owner"]
  gem = path[%r{gems/([^/]+)/}, 1] || "(root)"
  file_unit = path.sub(%r{^gems/[^/]+/(lib|src)/}, "")
  [gem, owner && !owner.empty? ? owner : file_unit]
end

# ---- churn: commits touching each path ----
churn_by_path = Hash.new(0)
IO.popen(["git", "-C", repo, "log", "--format=%H", "--name-only", "--", "gems/"]) do |io|
  io.each_line do |line|
    line = line.strip
    next if line.empty? || line.match?(/^[0-9a-f]{40}$/)
    churn_by_path[line] += 1
  end
end

# ---- aggregate fan-in/out at two granularities ----
Stats = Struct.new(:fan_out, :fan_in, :fns, :paths, :churn) do
  def initialize = super(Hash.new(0), Hash.new(0), 0, Set.new, 0)
end
require "set"

unit_stats = Hash.new { |h, k| h[k] = Stats.new }
gem_stats = Hash.new { |h, k| h[k] = Stats.new }

nodes.each do |n|
  u = unit_for(n)
  next unless u
  gem, unit = u
  key = [gem, unit]
  unit_stats[key].fns += 1
  unit_stats[key].paths << n["path"]
  gem_stats[gem].fns += 1
  gem_stats[gem].paths << n["path"]
end

unit_stats.each_value { |s| s.churn = s.paths.sum { |p| churn_by_path[p] } }
gem_stats.each_value { |s| s.churn = s.paths.sum { |p| churn_by_path[p] } }

# Index owners by trailing name segment so unresolved constant receivers
# (metadata.receiver like "LanguageProvider") can be name-resolved.
owner_index = Hash.new { |h, k| h[k] = Set.new }
unit_stats.each_key do |(gem, unit)|
  next unless unit.is_a?(String) && unit.match?(/\A[A-Z]/)
  owner_index[unit.split("::").last] << [gem, unit]
  owner_index[unit] << [gem, unit]
end

def resolve_receiver(owner_index, receiver, src_gem)
  candidates = owner_index[receiver]
  return candidates.first if candidates.size == 1
  same_gem = candidates.select { |g, _| g == src_gem }
  same_gem.size == 1 ? same_gem.first : nil
end

resolved_edges = 0
name_resolved_edges = 0
edges.each do |e|
  src = node_by_id[e["source"]]
  next unless src
  su = unit_for(src)
  next unless su

  dst = node_by_id[e["target"]]
  du = dst && unit_for(dst)
  kind = "direct"
  if du.nil?
    receiver = e.dig("metadata", "receiver")
    if receiver && receiver.match?(/\A[A-Z][A-Za-z0-9_:]*\z/)
      du = resolve_receiver(owner_index, receiver, su[0])
      kind = "name"
    end
  end
  next unless du
  next if su == du
  resolved_edges += 1
  name_resolved_edges += 1 if kind == "name"
  unit_stats[su].fan_out[du] += 1
  unit_stats[du].fan_in[su] += 1
  sgem, dgem = su[0], du[0]
  if sgem != dgem
    gem_stats[sgem].fan_out[dgem] += 1
    gem_stats[dgem].fan_in[sgem] += 1
  end
end

def instability(s)
  ce = s.fan_out.size
  ca = s.fan_in.size
  total = ce + ca
  total.zero? ? nil : ce.to_f / total
end

puts "artifact: #{nodes.size} nodes, #{edges.size} edges (#{resolved_edges} cross-unit; #{name_resolved_edges} via receiver-name resolution)"
puts

# ---- gem-level instability + dependency direction ----
puts "== Gem-level (Ca=dependents, Ce=dependencies, I=Ce/(Ca+Ce), lower=stabler) =="
gem_rows = gem_stats.map do |gem, s|
  i = instability(s)
  [gem, s.fan_in.size, s.fan_out.size, i, s.churn, s.fns]
end.sort_by { |r| r[3] || 2.0 }
gem_rows.each do |gem, ca, ce, i, churn, fns|
  printf("  %-14s Ca=%-2d Ce=%-2d I=%-5s churn=%-5d fns=%d\n", gem, ca, ce, i ? i.round(2) : "-", churn, fns)
end
puts

puts "== Stable-Dependencies-Principle violations (stabler gem depends on less-stable gem) =="
gem_i = gem_rows.to_h { |r| [r[0], r[3]] }
violations = []
gem_stats.each do |gem, s|
  s.fan_out.each do |(dgem), weight|
    si, di = gem_i[gem], gem_i[dgem]
    next unless si && di && di > si + 0.25
    violations << [gem, dgem, si, di, weight]
  end
end
violations.sort_by { |v| -v[4] }.first(10).each do |sgem, dgem, si, di, w|
  printf("  %s (I=%.2f) -> %s (I=%.2f)  edges=%d\n", sgem, si, dgem, di, w)
end
puts "  (none)" if violations.empty?
puts

# ---- unit-level hubs: high fan-in AND fan-out, churn-weighted ----
puts "== Hub candidates (unit level: sqrt(Ca*Ce) * log(1+churn), top 15) =="
hub_rows = unit_stats.map do |(gem, unit), s|
  ca = s.fan_in.size
  ce = s.fan_out.size
  hub = Math.sqrt(ca * ce)
  score = hub * Math.log(1 + s.churn)
  [score, gem, unit, ca, ce, s.churn, s.fns]
end.select { |r| r[0] > 0 }.sort_by { |r| -r[0] }
hub_rows.first(15).each do |score, gem, unit, ca, ce, churn, fns|
  printf("  %6.1f  %-12s %-45s Ca=%-3d Ce=%-3d churn=%-4d fns=%d\n", score, gem, unit.to_s[0, 45], ca, ce, churn, fns)
end
puts

# ---- god components: size * centrality, flagging only churn-active ones ----
puts "== God-component candidates (fns>=30 AND Ca+Ce>=20 AND churn>=20) =="
god = unit_stats.map do |(gem, unit), s|
  [gem, unit, s.fns, s.fan_in.size + s.fan_out.size, s.churn]
end.select { |_, _, fns, deg, churn| fns >= 30 && deg >= 20 && churn >= 20 }
   .sort_by { |r| -(r[2] * r[3]) }
god.first(10).each do |gem, unit, fns, deg, churn|
  printf("  %-12s %-45s fns=%-4d degree=%-3d churn=%d\n", gem, unit.to_s[0, 45], fns, deg, churn)
end
puts "  (none)" if god.empty?
