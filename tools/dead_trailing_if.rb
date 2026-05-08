#!/usr/bin/env ruby
# Detect `expr&.method ... if expr` patterns where the &. receiver
# is textually identical to the trailing-if guard expression.
require 'prism'

# Prism parses `foo&.bar if foo` as IfNode { predicate: foo, statements: [CallNode(safe_nav: true, recv: foo)] }
# We extract source text for the receiver and guard, compare strings.

findings = []
Dir.glob("src/**/*.rb").each do |path|
  src = File.read(path)
  parsed = Prism.parse(src)
  next if parsed.failure?

  walk = ->(node) {
    if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
      pred = node.predicate
      stmts = node.statements&.body || []
      # Look for a single safe-nav call as the body
      stmts.each do |stmt|
        # Walk inside stmt looking for safe-nav whose receiver source == predicate source
        walk_inner = ->(n) {
          if n.is_a?(Prism::CallNode) && n.safe_navigation? && n.receiver
            recv_src = n.receiver.location.slice
            pred_src = pred&.location&.slice
            if pred_src && recv_src == pred_src
              # IfNode body: dead because pred is truthy
              # UnlessNode body: skip — pred is falsy so &. would CORRECTLY return nil
              if node.is_a?(Prism::IfNode)
                findings << [path, n.location.start_line, src.lines[n.location.start_line - 1].chomp]
              end
            end
          end
          n.compact_child_nodes.each(&walk_inner) if n.respond_to?(:compact_child_nodes)
        }
        walk_inner.call(stmt)
      end
    end
    node.compact_child_nodes.each(&walk) if node.respond_to?(:compact_child_nodes)
  }
  walk.call(parsed.value)
end

findings.uniq!
findings.each { |f, l, c| puts "#{f}:#{l}  #{c.strip}" }
puts
puts "Total: #{findings.size}"
