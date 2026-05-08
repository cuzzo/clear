#!/usr/bin/env ruby
# tools/respond_to_inventory.rb
#
# Phase 0 of the respond_to? purge plan (TODO #9). Produces three
# artifacts in tmp/respond_to_inventory/:
#
#   attrs_by_class.csv  — class, attr, source (member|Locatable|attr_accessor)
#   sites.csv           — file, line, attr, method, params, caller_kind
#   summary.md          — top-N attrs, caller_kind distribution
#
# Caller-kind heuristic:
#   generic_walker    — enclosing method's first param is a generic name
#                       (node, stmt, expr, body, value, n, v, item) AND
#                       the method has no Sorbet sig narrowing it
#   typed             — Sorbet sig on enclosing method names a concrete
#                       AST::X type for the param being queried
#   unknown           — neither pattern matches; needs eyeball review
#
# Run:
#   bundle exec ruby tools/respond_to_inventory.rb

require "prism"
require "csv"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
OUT_DIR = File.join(ROOT, "tmp", "respond_to_inventory")
FileUtils.mkdir_p(OUT_DIR)

# Generic names that signal "this method visits any value", not a typed node.
GENERIC_PARAM_NAMES = %w[
  node stmt expr body value val
  n v stmts items children
  item arg arg_node element child
].freeze

# -------------------------------------------------------------------------
# Pass 1: attrs per AST class
# -------------------------------------------------------------------------
# Walks src/ast/ast.rb and src/ast/scope.rb (for SymbolEntry attrs that
# also flow through generic walkers). Collects:
#   - Struct.new(:a, :b, ...) → members
#   - include Locatable        → adds Locatable's accessors
#   - attr_accessor :x         → adds x
#
# Locatable is loaded by reading the module body and listing its
# attr_accessor / attr_reader names.

class ClassAttrCollector < Prism::Visitor
  attr_reader :classes  # { "AST::Foo" => Set[attrs] }

  def initialize(locatable_attrs)
    super()
    @classes = Hash.new { |h, k| h[k] = [] }
    @locatable_attrs = locatable_attrs
    @class_stack = []
  end

  def visit_module_node(node)
    name = node.constant_path.slice
    @class_stack.push(name)
    super
    @class_stack.pop
  end

  def visit_class_node(node)
    name = qualified(node.constant_path.slice)
    visit_class_or_struct(name) { super }
  end

  # Form: Foo = Struct.new(:a, :b, :c) [do ... end]
  def visit_constant_write_node(node)
    val = node.value
    return super unless val.is_a?(Prism::CallNode) && val.name == :new

    receiver = val.receiver
    return super unless receiver.is_a?(Prism::ConstantReadNode) &&
                        receiver.name == :Struct

    cls = qualified(node.name.to_s)
    members = (val.arguments&.arguments || []).filter_map do |arg|
      arg.is_a?(Prism::SymbolNode) ? arg.unescaped : nil
    end
    @classes[cls].concat(members)

    # The Struct.new block may include Locatable / attr_accessor.
    if val.block
      visit_class_or_struct(cls) { val.block.accept(self) }
    end
  end

  def visit_call_node(node)
    if @class_stack.any?
      cls = qualified_current
      case node.name
      when :include
        node.arguments&.arguments&.each do |arg|
          mod = arg.respond_to?(:slice) ? arg.slice : nil
          if mod == "Locatable" || mod == "AST::Locatable"
            @classes[cls].concat(@locatable_attrs)
          end
        end
      when :attr_accessor, :attr_reader, :attr_writer
        node.arguments&.arguments&.each do |arg|
          @classes[cls] << arg.unescaped if arg.is_a?(Prism::SymbolNode)
        end
      end
    end
    super
  end

  # `def foo` or `def foo=` inside a class/struct/module body counts as a
  # defined attr — Locatable defines `full_type` / `full_type=` this way.
  def visit_def_node(node)
    if @class_stack.any?
      cls = qualified_current
      @classes[cls] << node.name.to_s.sub(/=\z/, "")
    end
    super
  end

  private

  def visit_class_or_struct(name)
    @class_stack.push(name)
    yield
    @class_stack.pop
  end

  def qualified_current
    @class_stack.last
  end

  def qualified(short)
    return short if short.start_with?("AST::") || short.include?("::")
    return "AST::#{short}" if @class_stack.last == "AST"
    short
  end
end

# Locatable's attrs are needed first (for `include Locatable` in other classes).
def collect_locatable_attrs(ast_path)
  src = File.read(ast_path)
  result = Prism.parse(src)
  attrs = []
  result.value.statements.body.each do |top|
    walk = ->(node) {
      if node.is_a?(Prism::ModuleNode) && node.constant_path.slice == "Locatable"
        node.body.body.each do |s|
          if s.is_a?(Prism::CallNode) &&
             [:attr_accessor, :attr_reader, :attr_writer].include?(s.name)
            s.arguments&.arguments&.each do |a|
              attrs << a.unescaped if a.is_a?(Prism::SymbolNode)
            end
          elsif s.is_a?(Prism::DefNode)
            attrs << s.name.to_s.sub(/=\z/, "")
          end
        end
      elsif node.respond_to?(:child_nodes)
        node.child_nodes.compact.each(&walk)
      end
    }
    walk.call(top)
  end
  attrs.uniq
end

ast_path = File.join(ROOT, "src", "ast", "ast.rb")
locatable_attrs = collect_locatable_attrs(ast_path)

attr_collector = ClassAttrCollector.new(locatable_attrs)
[ast_path].each do |path|
  src = File.read(path)
  Prism.parse(src).value.accept(attr_collector)
end

# Write attrs_by_class.csv
attrs_csv_path = File.join(OUT_DIR, "attrs_by_class.csv")
CSV.open(attrs_csv_path, "w") do |csv|
  csv << ["class", "attr"]
  attr_collector.classes.sort_by { |k, _| k }.each do |cls, attrs|
    attrs.uniq.sort.each { |a| csv << [cls, a] }
  end
end

# Build reverse map: attr → [classes]
attr_to_classes = Hash.new { |h, k| h[k] = [] }
attr_collector.classes.each do |cls, attrs|
  attrs.uniq.each { |a| attr_to_classes[a] << cls }
end

# -------------------------------------------------------------------------
# Pass 2: respond_to? sites
# -------------------------------------------------------------------------

class RespondToCollector < Prism::Visitor
  attr_reader :sites

  def initialize(file)
    super()
    @file = file
    @sites = []
    @method_stack = []
  end

  def visit_def_node(node)
    params = (node.parameters&.requireds || []).map { |p| p.name.to_s }
    @method_stack.push({ name: node.name.to_s, params: params, line: node.location.start_line })
    super
    @method_stack.pop
  end

  def visit_call_node(node)
    if node.name == :respond_to? && node.arguments&.arguments&.length == 1
      arg = node.arguments.arguments.first
      if arg.is_a?(Prism::SymbolNode)
        receiver = node.receiver&.slice
        method = @method_stack.last
        @sites << {
          file: @file,
          line: node.location.start_line,
          attr: arg.unescaped,
          receiver: receiver,
          method_name: method&.dig(:name),
          method_params: method&.dig(:params)&.join(",")
        }
      end
    end
    super
  end
end

site_records = []
Dir.glob(File.join(ROOT, "src/**/*.rb")).sort.each do |path|
  rel = path.sub(ROOT + "/", "")
  src = File.read(path)
  collector = RespondToCollector.new(rel)
  Prism.parse(src).value.accept(collector)
  site_records.concat(collector.sites)
end

# -------------------------------------------------------------------------
# Caller-kind classification
# -------------------------------------------------------------------------

def classify_caller(site)
  params = (site[:method_params] || "").split(",")
  receiver = site[:receiver] || ""
  return "unknown" if params.empty?

  # If the receiver is a method param AND that param has a generic name,
  # this is a generic walker.
  return "generic_walker" if GENERIC_PARAM_NAMES.include?(receiver) &&
                              params.include?(receiver)

  # If the receiver is some chained access (e.g. `node.value`, `obj.target`),
  # the immediate receiver isn't the param — but the root probably is one.
  # Treat as walker if any param matches a generic name.
  return "generic_walker" if params.any? { |p| GENERIC_PARAM_NAMES.include?(p) }

  "typed_or_unclear"
end

site_records.each { |s| s[:caller_kind] = classify_caller(s) }

# -------------------------------------------------------------------------
# Output
# -------------------------------------------------------------------------

sites_csv_path = File.join(OUT_DIR, "sites.csv")
CSV.open(sites_csv_path, "w") do |csv|
  csv << %w[file line attr receiver method caller_kind classes_with_attr]
  site_records.each do |s|
    classes = attr_to_classes[s[:attr]] || []
    csv << [
      s[:file], s[:line], s[:attr], s[:receiver],
      s[:method_name], s[:caller_kind], classes.size
    ]
  end
end

# Summary
total = site_records.size
by_attr = site_records.group_by { |s| s[:attr] }.transform_values(&:size)
                     .sort_by { |_, n| -n }
by_kind = site_records.group_by { |s| s[:caller_kind] }.transform_values(&:size)

# Attrs that no AST class defines — those are likely external-input duck-typing
unknown_attrs = by_attr.reject { |a, _| attr_to_classes.key?(a) }

summary = +<<~MD
  # respond_to? Inventory (Phase 0)

  Generated by `tools/respond_to_inventory.rb`. Source for #9 planning.

  ## Totals

  - Total respond_to? sites: **#{total}**
  - Unique attrs queried: **#{by_attr.size}**
  - AST classes inventoried: **#{attr_collector.classes.size}**
  - Locatable attrs: #{locatable_attrs.size} — #{locatable_attrs.first(8).join(", ")}#{locatable_attrs.size > 8 ? ", ..." : ""}

  ## Caller-kind distribution

  | kind | count | %% |
  |---|---:|---:|
MD

by_kind.sort_by { |_, n| -n }.each do |kind, count|
  pct = (100.0 * count / total).round(1)
  summary << "| #{kind} | #{count} | #{pct}%% |\n"
end

summary << "\n## Top 30 attrs by site count\n\n"
summary << "| attr | sites | classes_with_attr | candidate? |\n"
summary << "|---|---:|---:|---|\n"
by_attr.first(30).each do |attr, count|
  classes = attr_to_classes[attr] || []
  candidate = if classes.empty?
                "external (no AST class)"
              elsif classes.size == 1
                "tighten signature → 1 class"
              else
                "shared trait (#{classes.size} classes)"
              end
  summary << "| `#{attr}` | #{count} | #{classes.size} | #{candidate} |\n"
end

summary << "\n## Attrs with no AST class match (external duck-typing)\n\n"
summary << "These query attrs that no class in `src/ast/ast.rb` defines.\n"
summary << "Likely interactions with String, Hash, Symbol, FFI types.\n\n"
unknown_attrs.first(20).each do |attr, count|
  summary << "- `#{attr}` (#{count} sites)\n"
end

summary_path = File.join(OUT_DIR, "summary.md")
File.write(summary_path, summary)

puts "Wrote:"
puts "  #{attrs_csv_path}    (#{attr_collector.classes.size} classes)"
puts "  #{sites_csv_path}    (#{site_records.size} sites)"
puts "  #{summary_path}"
