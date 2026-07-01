# frozen_string_literal: true

require "prism"
require_relative "../ruby_to_clear"

module RubyToClear
  # Prism-based Ruby -> CLEAR migration audit.
  #
  # This is intentionally not a full translator. It sizes the source surface
  # that the translator must cover and highlights the CallNode/BlockNode idioms
  # that should drive the migration roadmap.
  class Audit
    CONTROL_NODE_NAMES = %w[
      ReturnNode BreakNode NextNode RescueNode RescueModifierNode EnsureNode
      YieldNode SuperNode ForwardingSuperNode
    ].freeze

    DYNAMIC_CALLS = %w[
      send __send__ public_send const_get const_defined?
      instance_variable_get instance_variable_set define_method
      method_missing eval instance_eval class_eval module_eval
    ].freeze

    DYNAMIC_CALL_GUIDANCE = {
      "send" => ["dynamic dispatch", "replace with a closed case/table over known method names"],
      "__send__" => ["dynamic dispatch", "replace with a closed case/table over known method names"],
      "public_send" => ["dynamic dispatch", "replace with a closed case/table over known method names"],
      "const_get" => ["dynamic constant lookup", "replace with an explicit registry map"],
      "const_defined?" => ["dynamic constant lookup", "replace with an explicit registry map"],
      "instance_variable_get" => ["dynamic instance state", "replace with declared fields or a typed side table"],
      "instance_variable_set" => ["dynamic instance state", "replace with declared fields or a typed side table"],
      "define_method" => ["dynamic definition", "generate explicit methods or a closed dispatcher"],
      "method_missing" => ["dynamic definition", "replace with explicit protocol methods"],
      "eval" => ["dynamic evaluation", "refactor before translation"],
      "instance_eval" => ["dynamic evaluation", "refactor before translation"],
      "class_eval" => ["dynamic evaluation", "refactor before translation"],
      "module_eval" => ["dynamic evaluation", "refactor before translation"],
    }.freeze

    STDLIB_RECEIVERS = %w[
      File Dir Pathname JSON YAML OptionParser Open3 Set StringScanner Regexp
    ].freeze

    SAFE_BLOCK_LOWERINGS = {
      "all?" => "value block predicate",
      "any?" => "value block predicate",
      "collect" => "value pipeline stage",
      "each" => "effect block stage",
      "each_key" => "effect block stage",
      "each_value" => "effect block stage",
      "filter" => "value pipeline stage",
      "filter_map" => "value pipeline stage",
      "find" => "value block search",
      "flat_map" => "value pipeline stage",
      "map" => "value pipeline stage",
      "map!" => "mutable value pipeline stage",
      "reduce" => "accumulator block",
      "reject" => "value pipeline stage",
      "reverse_each" => "multi-stage effect block",
      "select" => "value pipeline stage",
      "sort_by" => "ordering value pipeline stage",
      "sum" => "aggregate value block"
    }.freeze

    HIGH_CONFIDENCE_STDLIB_CALLS = {
      "Dir.children" => "fs.list",
      "Dir.entries" => "fs.list",
      "Dir.exist?" => "fs.dir?",
      "Dir.exists?" => "fs.dir?",
      "Dir.glob" => "fs.glob",
      "Dir.pwd" => "fs.pwd",
      "File.basename" => "path.basename",
      "File.binwrite" => "fs.writeBytes",
      "File.delete" => "fs.remove",
      "File.directory?" => "fs.dir?",
      "File.dirname" => "path.dirname",
      "File.exist?" => "fs.exists?",
      "File.exists?" => "fs.exists?",
      "File.expand_path" => "path.expand",
      "File.file?" => "fs.file?",
      "File.foreach" => "fs.readLines |> EACH",
      "File.join" => "path.join",
      "File.mtime" => "fs.mtime",
      "File.read" => "fs.read",
      "File.readlines" => "fs.readLines",
      "File.readlink" => "fs.readlink",
      "File.size" => "fs.size",
      "File.symlink" => "fs.symlink",
      "File.symlink?" => "fs.symlink?",
      "File.write" => "fs.write"
    }.freeze

    RECEIVER_SHAPE_METHODS = %w[
      delete_prefix empty? include? is_a? keys length lines nil? respond_to?
      size split values
    ].freeze

    SHAPE_TRACKABLE_RECEIVERS = %w[
      array_literal bool_literal call_result hash_literal local nil_literal
      numeric_literal string_literal symbol_literal
    ].freeze

    attr_reader :files, :node_counts, :parse_errors, :transpile_results

    def self.files_for(root:, glob:)
      expanded_root = File.expand_path(root)
      Dir[File.join(expanded_root, glob)].sort
    end

    def initialize(files, top:, root: Dir.pwd, transpile: true)
      @root = File.expand_path(root)
      @files = files
      @top = top
      @transpile = transpile
      @node_counts = Hash.new(0)
      @parse_errors = []
      @total_nodes = 0
      @source_loc = 0
      @unsupported_loc = 0
      @unsupported_nodes = Hash.new(0)
      @transpile_results = Hash.new(0)

      @call_names = Hash.new(0)
      @call_receiver_kinds = Hash.new(0)
      @call_receiver_names = Hash.new(0)
      @call_arg_shapes = Hash.new(0)
      @call_shapes = Hash.new(0)
      @call_with_block = Hash.new(0)
      @call_block_kinds = Hash.new(0)
      @dynamic_calls = Hash.new(0)
      @dynamic_categories = Hash.new(0)
      @stdlib_calls = Hash.new(0)
      @sorbet_calls = Hash.new(0)
      @call_samples = Hash.new { |h, k| h[k] = [] }
      @stdlib_unlocked_calls = Hash.new(0)
      @receiver_shape_candidates = Hash.new(0)

      @block_callees = Hash.new(0)
      @block_receiver_kinds = Hash.new(0)
      @block_param_shapes = Hash.new(0)
      @block_body_buckets = Hash.new(0)
      @block_control_nodes = Hash.new(0)
      @block_shapes = Hash.new(0)
      @block_samples = Hash.new { |h, k| h[k] = [] }
      @safe_block_lowering_candidates = Hash.new(0)
      @block_control_flow_gaps = Hash.new(0)
    end

  def run
    files.each { |path| parse_file(path) }
  end

  def render_markdown
    out = []
    out << "# Ruby to CLEAR Prism Audit"
    out << ""
    out << "- files: #{files.size}"
    out << "- parse errors: #{parse_errors.size}"
    out << "- unique Prism node types: #{node_counts.size}"
    out << "- total Prism nodes: #{@total_nodes}"
    out << ""
    out << "## Node Coverage"
    out << ""
    render_coverage(out)
    if @transpile
      out << ""
      out << "## Translation Coverage"
      out << ""
      render_translation_coverage(out)
    end
    out << ""
    out << "## CallNode Breakdown"
    out << ""
    render_call_breakdown(out)
    out << ""
    out << "## BlockNode Breakdown"
    out << ""
    render_block_breakdown(out)
    out << ""
    out << "## Now-Unlocked Work"
    out << ""
    render_unlocked_work(out)
    out << ""
    out << "## Roadmap Suggestions"
    out << ""
    render_roadmap(out)
    out.join("\n")
  end

  private

  def parse_file(path)
    result = Prism.parse_file(path)
    if result.failure?
      @parse_errors << [path, result.errors.map(&:message)]
      return
    end

    walk(result.value) do |node|
      count_node(node)
      analyze_call(path, node) if node.is_a?(Prism::CallNode)
    end

    analyze_transpile(path) if @transpile
  end

  def analyze_transpile(path)
    source = File.read(path)
    source_loc = source.lines.count { |line| !line.strip.empty? }
    @source_loc += source_loc

    output = RubyToClear.transpile(source, raise_on_error: false)
    unsupported_loc = [count_unsupported_source_lines(output), source_loc].min
    @unsupported_loc += unsupported_loc

    if unsupported_loc.zero?
      @transpile_results[:complete] += 1
    else
      @transpile_results[:partial] += 1
    end
  rescue StandardError => e
    @transpile_results[:failed] += 1
    @unsupported_loc += source_loc || 0
    @unsupported_nodes[e.class.name] += 1
  end

  def count_unsupported_source_lines(output)
    count = 0
    in_unsupported = false

    output.each_line do |line|
      stripped = line.lstrip
      if (node_name = stripped[/\A# \[UNSUPPORTED: ([^\] ]+)/, 1])
        @unsupported_nodes[node_name] += 1
        in_unsupported = true
        next
      end

      if in_unsupported && stripped.start_with?("# ")
        count += 1
      else
        in_unsupported = false
      end
    end

    count
  end

  def walk(node, &block)
    return unless node.is_a?(Prism::Node)

    yield node
    node.child_nodes.each { |child| walk(child, &block) if child }
  end

  def count_node(node)
    name = short_node_name(node)
    @node_counts[name] += 1
    @total_nodes += 1
  end

  def analyze_call(path, node)
    name = node.name.to_s
    receiver_kind = receiver_kind(node.receiver)
    receiver_name = receiver_name(node.receiver)
    arg_shape = argument_shape(node.arguments)
    block_kind = call_block_kind(node.block)
    call_shape = "#{receiver_kind}.#{name}(#{arg_shape})"
    call_shape += " {#{block_kind}}" if node.block

    @call_names[name] += 1
    @call_receiver_kinds[receiver_kind] += 1
    @call_receiver_names[receiver_name] += 1 if receiver_name
    @call_arg_shapes[arg_shape] += 1
    @call_shapes[call_shape] += 1

    if node.block
      @call_with_block[name] += 1
      @call_block_kinds[block_kind] += 1
      analyze_block(path, node, node.block) if node.block.is_a?(Prism::BlockNode)
    end

    if DYNAMIC_CALLS.include?(name)
      @dynamic_calls[name] += 1
      category, = DYNAMIC_CALL_GUIDANCE.fetch(name, ["dynamic/reflection", "refactor before translation"])
      @dynamic_categories[category] += 1
      add_sample(@call_samples[name], path, node)
    end

    if receiver_name == "T"
      @sorbet_calls[name] += 1
    elsif STDLIB_RECEIVERS.include?(receiver_name.to_s)
      key = "#{receiver_name}.#{name}"
      @stdlib_calls[key] += 1
      if (clear_name = HIGH_CONFIDENCE_STDLIB_CALLS[key])
        @stdlib_unlocked_calls["#{key} -> #{clear_name}"] += 1
      end
      add_sample(@call_samples[key], path, node)
    end

    if RECEIVER_SHAPE_METHODS.include?(name) && SHAPE_TRACKABLE_RECEIVERS.include?(receiver_kind)
      @receiver_shape_candidates["#{receiver_kind}.#{name}"] += 1
    end
  end

  def analyze_block(path, call_node, block_node)
    callee = call_node.name.to_s
    receiver = receiver_kind(call_node.receiver)
    params = block_param_shape(block_node.parameters)
    body_bucket = block_body_bucket(block_node.body)
    shape = "#{receiver}.#{callee} |#{params}| #{body_bucket}"

    @block_callees[callee] += 1
    @block_receiver_kinds[receiver] += 1
    @block_param_shapes[params] += 1
    @block_body_buckets[body_bucket] += 1
    @block_shapes[shape] += 1
    add_sample(@block_samples[callee], path, block_node)

    if (lowering = SAFE_BLOCK_LOWERINGS[callee])
      @safe_block_lowering_candidates["#{callee} | #{lowering} | #{params} | #{body_bucket}"] += 1
    end

    control_counts(block_node).each do |control_name, count|
      @block_control_nodes[control_name] += count
      @block_control_flow_gaps["#{callee} block contains #{control_name}"] += count
    end
  end

  def call_block_kind(block)
    case block
    when nil then "none"
    when Prism::BlockNode then "literal_block"
    when Prism::BlockArgumentNode then "block_arg"
    else short_node_name(block)
    end
  end

  def short_node_name(node)
    node.class.name.split("::").last
  end

  def receiver_kind(receiver)
    case receiver
    when nil then "implicit"
    when Prism::SelfNode then "self"
    when Prism::LocalVariableReadNode then "local"
    when Prism::InstanceVariableReadNode then "ivar"
    when Prism::ClassVariableReadNode then "class_var"
    when Prism::GlobalVariableReadNode then "global"
    when Prism::ConstantReadNode then "constant"
    when Prism::ConstantPathNode then "constant_path"
    when Prism::CallNode then "call_result"
    when Prism::ParenthesesNode then "parenthesized"
    when Prism::StringNode, Prism::InterpolatedStringNode then "string_literal"
    when Prism::SymbolNode, Prism::InterpolatedSymbolNode then "symbol_literal"
    when Prism::IntegerNode, Prism::FloatNode then "numeric_literal"
    when Prism::ArrayNode then "array_literal"
    when Prism::HashNode then "hash_literal"
    when Prism::NilNode then "nil_literal"
    when Prism::TrueNode, Prism::FalseNode then "bool_literal"
    else short_node_name(receiver)
    end
  end

  def receiver_name(receiver)
    return nil unless receiver

    if receiver.respond_to?(:full_name)
      receiver.full_name
    elsif receiver.respond_to?(:name)
      receiver.name.to_s
    end
  rescue StandardError
    nil
  end

  def argument_shape(arguments)
    return "args=0" unless arguments

    args = arguments.arguments
    parts = ["args=#{args.size}"]
    parts << "kw" if arguments.contains_keywords?
    parts << "splat" if arguments.contains_splat?
    parts << "kw_splat" if arguments.contains_keyword_splat?
    parts << "multi_splat" if arguments.contains_multiple_splats?
    parts << "forward" if arguments.contains_forwarding?
    parts.join("+")
  end

  def block_param_shape(block_parameters)
    return "none" unless block_parameters

    params = block_parameters.parameters
    return "locals" unless params

    parts = []
    parts << "req=#{params.requireds.size}" if params.requireds.any?
    parts << "opt=#{params.optionals.size}" if params.optionals.any?
    parts << "post=#{params.posts.size}" if params.posts.any?
    parts << "kw=#{params.keywords.size}" if params.keywords.any?
    parts << "kwrest" if params.keyword_rest
    parts << "rest" if params.rest
    parts << "block" if params.block
    parts.empty? ? "empty" : parts.join("+")
  end

  def block_body_bucket(body)
    count = statement_count(body)
    case count
    when 0 then "stmts=0"
    when 1 then "stmts=1"
    when 2..3 then "stmts=2-3"
    when 4..8 then "stmts=4-8"
    else "stmts=9+"
    end
  end

  def statement_count(body)
    return 0 unless body
    return body.body.size if body.respond_to?(:body) && body.body.respond_to?(:size)

    1
  end

  def control_counts(block_node)
    counts = Hash.new(0)
    root = block_node

    root.child_nodes.each do |child|
      walk_without_nested_blocks(child) do |node|
        name = short_node_name(node)
        counts[name] += 1 if CONTROL_NODE_NAMES.include?(name)
      end
    end
    counts
  end

  def walk_without_nested_blocks(node, &block)
    return unless node.is_a?(Prism::Node)
    return if node.is_a?(Prism::BlockNode)

    yield node
    node.child_nodes.each { |child| walk_without_nested_blocks(child, &block) if child }
  end

  def add_sample(samples, path, node)
    return if samples.size >= 5

    line = node.location.start_line
    samples << "#{relative(path)}:#{line}"
  end

  def relative(path)
    path.start_with?(@root) ? path.delete_prefix("#{@root}/") : path
  end

  def render_coverage(out)
    cumulative = 0
    sorted = @node_counts.sort_by { |name, count| [-count, name] }
    [10, 20, 30, 40].each do |limit|
      cumulative = sorted.first(limit).sum { |_name, count| count }
      out << format("- top %d node types: %d / %d, %.2f%%",
                    limit, cumulative, @total_nodes,
                    percent(cumulative, @total_nodes))
    end
    out << ""
    out << table("Top Prism Nodes", ["count", "node"],
                 sorted.first(@top).map { |name, count| [count, name] })
  end

  def render_translation_coverage(out)
    translated_loc = [@source_loc - @unsupported_loc, 0].max
    out << "- complete files: #{@transpile_results[:complete]}"
    out << "- partial files: #{@transpile_results[:partial]}"
    out << "- failed files: #{@transpile_results[:failed]}"
    out << "- source LoC: #{@source_loc}"
    out << "- unsupported/commented LoC: #{@unsupported_loc}"
    out << format("- useful LoC coverage: %.2f%%", percent(translated_loc, @source_loc))
    out << ""
    out << table("Unsupported Nodes In Transpiler Output", ["count", "node"], top(@unsupported_nodes))
  end

  def render_call_breakdown(out)
    total = @call_names.values.sum
    out << "- total CallNode: #{total}"
    out << "- unique call names: #{@call_names.size}"
    out << "- calls with blocks: #{@call_with_block.values.sum}"
    out << ""
    out << table("Top Call Names", ["count", "name"], top(@call_names))
    out << ""
    out << table("Call Receiver Kinds", ["count", "receiver"], top(@call_receiver_kinds))
    out << ""
    out << table("Call Argument Shapes", ["count", "shape"], top(@call_arg_shapes))
    out << ""
    out << table("Top Call Shapes", ["count", "shape"], top(@call_shapes))
    out << ""
    out << table("Top Calls With Blocks", ["count", "name"], top(@call_with_block))
    out << ""
    out << table("Call Block Kinds", ["count", "kind"], top(@call_block_kinds))
    out << ""
    out << table("Sorbet Receiver Calls", ["count", "method"], top(@sorbet_calls))
    out << ""
    out << table("Stdlib Receiver Calls", ["count", "call"], top(@stdlib_calls))
    out << ""
    out << table("Dynamic/Reflection Calls", ["count", "method"], top(@dynamic_calls))
    out << ""
    out << table("Dynamic/Reflection Categories", ["count", "category"], top(@dynamic_categories))
    out << ""
    out << table("Dynamic Blocker Guidance", ["count", "method", "category", "recommended action"], dynamic_guidance_rows)
    render_samples(out, @dynamic_calls.keys.sort + @stdlib_calls.keys.sort)
  end

  def render_block_breakdown(out)
    total = @block_callees.values.sum
    out << "- total BlockNode attached to calls: #{total}"
    out << "- unique block callee names: #{@block_callees.size}"
    out << ""
    out << table("Top Block Callees", ["count", "callee"], top(@block_callees))
    out << ""
    out << table("Block Receiver Kinds", ["count", "receiver"], top(@block_receiver_kinds))
    out << ""
    out << table("Block Parameter Shapes", ["count", "params"], top(@block_param_shapes))
    out << ""
    out << table("Block Body Buckets", ["count", "bucket"], top(@block_body_buckets))
    out << ""
    out << table("Control Nodes Inside Blocks", ["count", "node"], top(@block_control_nodes))
    out << ""
    out << table("Top Block Shapes", ["count", "shape"], top(@block_shapes))
  end

  def render_unlocked_work(out)
    out << "These buckets are high-confidence follow-up work because they fit the current pipeline, fs/path, and receiver-shape translation model."
    out << ""
    out << table("Safe Block Lowering Candidates", ["count", "bucket"], top(@safe_block_lowering_candidates))
    out << ""
    out << table("High-Confidence Stdlib Adapter Calls", ["count", "call -> CLEAR"], top(@stdlib_unlocked_calls))
    out << ""
    out << table("Receiver-Shape Call Candidates", ["count", "receiver.method"], top(@receiver_shape_candidates))
    out << ""
    out << table("Block Control-Flow TODOs", ["count", "bucket"], top(@block_control_flow_gaps))
  end

  def render_roadmap(out)
    rows = []
    top(@unsupported_nodes).each do |count, node|
      rows << [count, "#{node} | transpile or leave localized TODO | unsupported Prism node in current output"]
    end
    top(@stdlib_calls).each do |count, call|
      rows << [count, "#{call} | add thin adapter | recurring Ruby stdlib surface"]
    end
    top(@block_callees).each do |count, callee|
      rows << [count, "#{callee} block | transpile safe subset | recurring block form"]
    end
    top(@dynamic_calls).each do |count, call|
      rows << [count, "#{call} | refactor Ruby source or closed dispatch | dynamic/reflection blocker"]
    end

    rows = rows.sort_by { |count, text| [-count.to_i, text] }.first(@top)
    out << table("Ranked Next Work", ["count", "recommendation"], rows)
  end

  def dynamic_guidance_rows
    top(@dynamic_calls).map do |count, call|
      category, action = DYNAMIC_CALL_GUIDANCE.fetch(call, ["dynamic/reflection", "refactor before translation"])
      [count, call, category, action]
    end
  end

  def render_samples(out, names)
    sample_rows = names.filter_map do |name|
      samples = @call_samples[name]
      next if samples.nil? || samples.empty?

      [samples.join(", "), name]
    end
    return if sample_rows.empty?

    out << ""
    out << table("Sample Sites", ["sites", "call"], sample_rows)
  end

  def top(hash)
    hash.sort_by { |name, count| [-count, name] }
        .first(@top)
        .map { |name, count| [count, name] }
  end

  def table(title, headers, rows)
    lines = []
    lines << "### #{title}"
    lines << ""
    lines << "| #{headers.join(' | ')} |"
    lines << "| #{headers.map { '---' }.join(' | ')} |"
    rows.each do |row|
      cells = Array(row)
      lines << "| #{cells.map { |cell| escape_md(cell) }.join(' | ')} |"
    end
    lines.join("\n")
  end

  def percent(num, den)
    return 100.0 if den.to_i.zero?

    (100.0 * num / den).round(2)
  end

  def escape_md(value)
    value.to_s.gsub("|", "\\|")
  end
  end
end
