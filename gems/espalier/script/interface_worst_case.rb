#!/usr/bin/env ruby
# frozen_string_literal: true

# Interface-dispatch worst-case analysis (design phases 3 + 4).
#
# Consumes phase-2 satisfaction edges (`dispatch_impls`) from a FactMine
# profile and per-function Big-O from an Espalier architecture report, and for
# every abstract type's method computes:
#   phase 3 - the worst-case implementation and its cost (provenance)
#   phase 4 - whether that worst case is asymptotically significant, and how
#             often across the corpus a worst case is non-trivial / varies
#
# Usage: interface_worst_case.rb PROFILE.json ARCHITECTURE.json [--json]

require "json"

profile_path, arch_path = ARGV.reject { |a| a.start_with?("--") }
as_json = ARGV.include?("--json")
abort "usage: interface_worst_case.rb PROFILE.json ARCHITECTURE.json [--json]" unless profile_path && arch_path

profile = JSON.parse(File.read(profile_path))
arch = JSON.parse(File.read(arch_path))

# Per-(owner, method) Big-O from the architecture report.
cost = Hash.new { |h, k| h[k] = {} }
walk = lambda do |node, &blk|
  blk.call(node)
  children = node.is_a?(Hash) ? node.values : node.is_a?(Array) ? node : []
  children.each { |c| walk.call(c, &blk) }
end
walk.call(arch) do |node|
  next unless node.is_a?(Hash) && node.key?("time_complete")
  cost[node["owner"].to_s][node["name"].to_s] = {
    time: node["big_o_time"], complete: node["time_complete"]
  }
end

# Interface -> [implementers]; interface -> [required methods].
impls = Hash.new { |h, k| h[k] = [] }
Array(profile["dispatch_impls"]).each { |e| impls[e["interface"]] << e }
requirements = {}
Array(profile["owners"]).each do |o|
  requirements[o["name"]] = Array(o["requirements"]) unless Array(o["requirements"]).empty?
end

# Coarse worst-case ordering over Big-O classes. A parametric cost (contains an
# unresolved callback C or reflective R) ranks above any concrete class of the
# same N-structure: worst-case, an unbounded parameter can be anything.
parametric = lambda { |c| c.to_s.include?("C") || c.to_s.include?("R") }
rank = lambda do |c|
  s = c.to_s
  base = if s.include?("^") then 5
         elsif s.include?("N log N") || s.include?("N*log") then 4
         elsif s.include?("N") then 3
         elsif s.include?("log") then 1
         else 0
         end
  parametric.call(c) ? base + 10 : base
end

results = []
impls.each do |iface, edges|
  methods = requirements[iface] || []
  # Fall back to the union of methods the implementers define, if no explicit
  # requirement list (nominal languages).
  methods = edges.flat_map { |e| cost[e["implementer"]].keys }.uniq if methods.empty?
  methods.each do |m|
    priced = edges.filter_map do |e|
      c = cost[e["implementer"]][m]
      c && c[:complete] ? [e["implementer"], c[:time]] : nil
    end
    next if priced.empty?
    worst = priced.max_by { |(_, t)| rank.call(t) }
    variance = priced.map { |(_, t)| t }.uniq.size
    # A caller's `O(N * C)` bound for this method resolves to a concrete
    # "complete worst case" only when the worst implementation is itself
    # concrete. If the worst impl is still parametric (its own C/R), the
    # substitution stays parametric and the caller bound cannot be closed.
    status = parametric.call(worst[1]) ? "worst_case_parametric" : "complete_worst_case"
    results << {
      interface: iface, method: m,
      worst_impl: worst[0], worst_cost: worst[1],
      implementers_priced: priced.size, distinct_costs: variance,
      significant: rank.call(worst[1]) > 0,      # non-O(1) -> may dominate a caller
      status: status,
      distribution: priced.sort_by { |(_, t)| -rank.call(t) }.first(4)
    }
  end
end

results.sort_by! { |r| [-rank.call(r[:worst_cost]), r[:interface], r[:method]] }

if as_json
  puts JSON.pretty_generate(results)
else
  significant = results.count { |r| r[:significant] }
  varying = results.count { |r| r[:distinct_costs] > 1 }
  resolvable = results.count { |r| r[:status] == "complete_worst_case" }
  puts "interface methods analyzed: #{results.size}"
  puts "  non-trivial worst case (may dominate a caller): #{significant}"
  puts "  worst case varies across implementations:        #{varying}"
  puts "  complete worst case (C resolves to a concrete bound): #{resolvable}"
  puts "  worst-case parametric (C stays open):                 #{results.size - resolvable}"
  puts
  puts "phase 3 - worst-case implementation per interface method:"
  results.first(25).each do |r|
    flag = r[:distinct_costs] > 1 ? " [varies]" : ""
    puts format("  %-22s %-10s worst=%-9s via %s%s",
                "#{r[:interface]}.#{r[:method]}", r[:worst_cost], r[:worst_cost], r[:worst_impl], flag)
  end
end
