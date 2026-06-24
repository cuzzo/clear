# typed: false
# frozen_string_literal: true

module NilKill
  # Report-only detector for primitive String/Symbol slots that behave like
  # closed domain enums. Static literal decisions are the decisive evidence;
  # runtime class observations are supporting pressure only.
  class HiddenEnumPressure
    MIN_VALUES = 2
    MAX_VALUES = 10
    HIGH_DECISION_PRESSURE = 3
    COMPARISON_METHODS = %i[== != ===].freeze
    MEMBERSHIP_METHODS = %i[include? member? key?].freeze
    OPEN_WORLD_RECEIVERS = %w[ENV ARGV STDIN JSON YAML CSV File IO Socket TCPSocket UDPSocket Net HTTP URI].freeze
    OPEN_WORLD_METHODS = %i[gets read readlines readline parse load load_file fetch input].freeze
    DYNAMIC_PRIMITIVE_METHODS = %i[to_s to_sym intern concat +].freeze
    PREFILTER_TOKENS = [
      "when :", "when \"", "when '",
      "== :", "!= :", "=== :",
      "== \"", "!= \"", "=== \"",
      "== '", "!= '", "=== '",
      ".include?(", ".member?(", ".key?(",
    ].freeze

    def self.scan(files = NilKill.target_files, evidence: nil)
      new(files, evidence: evidence).scan
    end

    def initialize(files, evidence: nil)
      @files = Array(files).compact
      @evidence = evidence || {}
      @slots = {}
      @runtime_index = runtime_index(@evidence)
    end

    def scan
      obs = @evidence.dig("facts", "hidden_enum_observations")
      if obs && !obs.empty?
        load_observations(obs)
      else
        @files.each { |path| scan_file(path) if File.file?(path) }
      end
      rows.sort_by { |row| [-row["score"].to_i, row["path"].to_s, row["line"].to_i, row["slot"].to_s] }
    end

    def load_observations(observations)
      observations.each do |obs|
        slot = {
          "key" => obs["key"],
          "kind" => obs["kind"],
          "path" => obs["path"],
          "line" => obs["line"].to_i,
          "owner" => obs["owner"],
          "method" => obs["method"],
          "method_kind" => obs["method_kind"],
          "slot" => obs["slot"],
          "type" => obs["type"]
        }
        entry = slot_entry(slot)

        event = obs["event"]
        values = obs["values"] || []
        site = obs["site"] || {}

        case event
        when "decision"
          merge_values(entry, values)
          entry["decisions"] << site.merge("values" => values)
        when "producer"
          merge_values(entry, values)
          entry["producers"] << site.merge("values" => values)
        when "blocker"
          entry["blockers"] << site
        end
      end
    end

    private

    MethodContext = Struct.new(:path, :rel_path, :lines, :owner, :method, :kind, :line, :sig, :params, :aliases, keyword_init: true)

    def scan_file(path)
      return unless candidate_source?(path)

      parsed = NilKill.cached_parse_file(path)
      return unless parsed.success?

      lines = File.readlines(path)
      walk_file(parsed.value, [], path, NilKill.rel(path), lines)
    end

    def candidate_source?(path)
      source = File.read(path)
      PREFILTER_TOKENS.any? { |token| source.include?(token) } || literal_left_comparison_source?(source)
    rescue StandardError
      false
    end

    def literal_left_comparison_source?(source)
      source.each_line.any? do |line|
        COMPARISON_METHODS.any? do |op|
          left = line.split(op.to_s, 2).first
          left && (left.include?(":") || left.include?("\"") || left.include?("'"))
        end
      end
    end

    def walk_file(node, scope, path, rel_path, lines)
      case node
      when Syntax::ClassNode, Syntax::ModuleNode
        walk_file(node.body, scope + [node.constant_path.slice], path, rel_path, lines) if node.body
      when Syntax::DefNode
        scan_method(node, scope, path, rel_path, lines)
      else
        node.compact_child_nodes.each { |child| walk_file(child, scope, path, rel_path, lines) } if node.respond_to?(:compact_child_nodes)
      end
    end

    def scan_method(node, scope, path, rel_path, lines)
      owner = scope.join("::")
      sig = sig_above(lines, node.location.start_line)
      ctx = MethodContext.new(
        path: path,
        rel_path: rel_path,
        lines: lines,
        owner: owner,
        method: node.name.to_s,
        kind: node.receiver.is_a?(Syntax::SelfNode) ? "class" : "instance",
        line: node.location.start_line,
        sig: sig,
        params: method_params(node, sig),
        aliases: {}
      )
      record_param_defaults(node, ctx)
      scan_body(node.body, ctx) if node.body
    end

    def scan_body(node, ctx)
      return unless node
      scan_raw_body(node.raw, node.context, ctx)
    end

    def scan_raw_body(raw, syntax_context, ctx)
      return unless raw
      return if nested_scope_raw?(raw, syntax_context)

      node = interesting_node(raw, syntax_context)
      case node
      when Syntax::CaseNode
        inspect_case(node, ctx)
      when Syntax::CallNode
        inspect_call(node, ctx)
      when Syntax::LocalVariableWriteNode
        inspect_local_write(node, ctx)
      when Syntax::InstanceVariableWriteNode, Syntax::ClassVariableWriteNode
        inspect_state_write(node, ctx)
      end

      raw_named_children(syntax_context, raw).each { |child| scan_raw_body(child, syntax_context, ctx) }
    end

    def interesting_node(raw, syntax_context)
      case raw.kind
      when "case"
        syntax_context.wrap(raw, force: Syntax::CaseNode)
      when "call", "binary", "assignment", "operator_assignment", "element_reference"
        syntax_context.wrap(raw)
      end
    end

    def nested_scope_raw?(raw, syntax_context)
      return true if %w[method singleton_method class module singleton_class lambda].include?(raw.kind)
      return true if raw.kind == "body_statement" && %w[def class module].include?(raw_children(syntax_context, raw).first&.kind)

      false
    end

    def raw_children(syntax_context, raw)
      syntax_context.children(raw)
    end

    def raw_named_children(syntax_context, raw)
      syntax_context.named_children(raw)
    end

    def inspect_case(node, ctx)
      slot = slot_for(node.predicate, ctx)
      return unless slot

      values = node.conditions.flat_map { |condition| literal_values(condition.conditions) }
      record_decision(slot, values, node, "case") unless values.empty?
    end

    def inspect_call(node, ctx)
      if COMPARISON_METHODS.include?(node.name)
        inspect_comparison(node, ctx)
      elsif MEMBERSHIP_METHODS.include?(node.name)
        inspect_membership(node, ctx)
      end
    end

    def inspect_comparison(node, ctx)
      args = node.arguments&.arguments || []
      return unless args.size == 1

      left_slot = slot_for(node.receiver, ctx)
      right_slot = slot_for(args.first, ctx)
      right_values = literal_values([args.first])
      left_values = literal_values([node.receiver])
      record_decision(left_slot, right_values, node, node.name.to_s) if left_slot && !right_values.empty?
      record_decision(right_slot, left_values, node, node.name.to_s) if right_slot && !left_values.empty?
    end

    def inspect_membership(node, ctx)
      args = node.arguments&.arguments || []
      return unless args.size == 1

      slot = slot_for(args.first, ctx)
      return unless slot

      values = literal_values([node.receiver])
      record_decision(slot, values, node, node.name.to_s) unless values.empty?
    end

    def inspect_local_write(node, ctx)
      name = node.name.to_s
      value_slot = slot_for(node.value, ctx)
      if value_slot
        ctx.aliases[name] = value_slot
      else
        ctx.aliases.delete(name)
      end

      slot = param_slot(ctx, name)
      return unless slot

      inspect_assignment_to_slot(slot, node.value, node)
    end

    def inspect_state_write(node, ctx)
      slot = state_slot(ctx, node.name.to_s, node)
      inspect_assignment_to_slot(slot, node.value, node)
    end

    def inspect_assignment_to_slot(slot, value, site)
      values = literal_values([value])
      if values.empty?
        blocker = producer_blocker(value)
        record_blocker(slot, blocker, site) if blocker
      else
        record_producer(slot, values, site)
      end
    end

    def record_param_defaults(node, ctx)
      p = node.parameters
      return unless p

      (p.optionals + p.keywords).each do |param|
        next unless param.respond_to?(:name) && param.name
        values = literal_values([param.value])
        next if values.empty?

        record_producer(param_slot(ctx, param.name.to_s), values, param)
      end
    end

    def slot_for(node, ctx)
      node = unwrap_slot_node(node)
      case node
      when Syntax::LocalVariableReadNode
        ctx.aliases[node.name.to_s] || param_slot(ctx, node.name.to_s)
      when Syntax::InstanceVariableReadNode, Syntax::ClassVariableReadNode
        state_slot(ctx, node.name.to_s, node)
      end
    end

    def unwrap_slot_node(node)
      current = node
      loop do
        if current.is_a?(Syntax::ParenthesesNode)
          current = current.body
        elsif current.is_a?(Syntax::CallNode) && current.receiver&.slice == "T" && %i[must cast let].include?(current.name)
          current = current.arguments&.arguments&.first
        else
          return current
        end
      end
    end

    def param_slot(ctx, name)
      param = ctx.params[name]
      return nil unless param

      {
        "key" => ["param", ctx.rel_path, ctx.owner, ctx.kind, ctx.method, ctx.line, name].join("\0"),
        "kind" => "param",
        "path" => ctx.rel_path,
        "line" => ctx.line,
        "owner" => ctx.owner,
        "method" => ctx.method,
        "method_kind" => ctx.kind,
        "slot" => name,
        "type" => param["type"].to_s,
      }
    end

    def state_slot(ctx, name, node)
      {
        "key" => ["state", ctx.rel_path, ctx.owner, name].join("\0"),
        "kind" => "state",
        "path" => ctx.rel_path,
        "line" => node.location.start_line,
        "owner" => ctx.owner,
        "method" => nil,
        "method_kind" => nil,
        "slot" => name,
        "type" => "",
      }
    end

    def record_decision(slot, values, site, kind)
      return unless slot
      useful_values = values.select { |value| candidate_value?(value) }
      return if useful_values.empty?

      entry = slot_entry(slot)
      merge_values(entry, useful_values)
      entry["decisions"] << site_record(site, kind).merge("values" => useful_values)
    end

    def record_producer(slot, values, site)
      return unless slot
      useful_values = values.select { |value| candidate_value?(value) }
      return if useful_values.empty?

      entry = slot_entry(slot)
      merge_values(entry, useful_values)
      entry["producers"] << site_record(site, "producer").merge("values" => useful_values)
    end

    def record_blocker(slot, blocker, site)
      return unless slot && blocker

      entry = slot_entry(slot)
      entry["blockers"] << site_record(site, blocker)
    end

    def slot_entry(slot)
      key = slot.fetch("key")
      @slots[key] ||= {
        "kind" => slot["kind"],
        "path" => slot["path"],
        "line" => slot["line"],
        "owner" => slot["owner"],
        "method" => slot["method"],
        "method_kind" => slot["method_kind"],
        "slot" => slot["slot"],
        "type" => slot["type"],
        "values" => [],
        "primitive_kinds" => [],
        "decisions" => [],
        "producers" => [],
        "blockers" => [],
      }
    end

    def merge_values(entry, values)
      entry["values"] = (entry["values"] + values.map { |value| value["value"] }).uniq.sort
      entry["primitive_kinds"] = (entry["primitive_kinds"] + values.map { |value| value["kind"] }).uniq.sort
    end

    def rows
      @slots.values.filter_map do |entry|
        values = entry["values"]
        next if values.size < MIN_VALUES || values.size > MAX_VALUES
        next if entry["decisions"].empty?
        next unless eligible_slot_type?(entry)

        row_for(entry)
      end
    end

    def row_for(entry)
      runtime = runtime_for(entry)
      decision_pressure = entry["decisions"].sum { |site| Array(site["values"]).size }
      score = decision_pressure * 3 + entry["values"].size * 2 + entry["producers"].size + runtime["support_score"].to_i
      confidence = if entry["blockers"].empty? && decision_pressure >= HIGH_DECISION_PRESSURE
        "high"
      else
        "review"
      end
      entry.merge(
        "confidence" => confidence,
        "decision_pressure" => decision_pressure,
        "score" => score,
        "runtime" => runtime.reject { |key, _| key == "support_score" },
        "suggestion" => suggestion_for(entry)
      )
    end

    def suggestion_for(entry)
      base = entry["slot"].to_s.delete_prefix("@").split(/[^A-Za-z0-9]+/).reject(&:empty?).map(&:capitalize).join
      base = "State" if base.empty?
      "review for a named #{base} enum or literal-union contract"
    end

    def eligible_slot_type?(entry)
      type = entry["type"].to_s.strip
      return true if type.empty? || type == "T.untyped"

      stripped = NilKill.strip_nilable_type(type)
      return true if %w[String Symbol].include?(stripped)
      return true if stripped.start_with?("T.any(") && stripped.include?("String") && stripped.include?("Symbol")

      false
    end

    def runtime_for(entry)
      return {} unless entry["kind"] == "param"

      rec = @runtime_index[[entry["path"], entry["line"].to_i, entry["owner"], entry["method"], entry["method_kind"]]]
      return {} unless rec

      classes = Array(rec.dig("params_by_name", entry["slot"]))
      support = classes.any? { |klass| entry["primitive_kinds"].include?(klass) } ? 2 : 0
      {
        "calls" => rec["calls"].to_i,
        "classes" => classes,
        "support_score" => support,
      }
    end

    def runtime_index(evidence)
      Array(evidence && evidence["methods"]).each_with_object({}) do |rec, index|
        source = rec["source"] || {}
        path = source["path"].to_s
        next if path.empty?
        index[[path, source["line"].to_i, source["class"].to_s, source["method"].to_s, source["kind"].to_s]] = rec
      end
    end

    def literal_values(nodes)
      Array(nodes).flat_map do |node|
        case node
        when Syntax::SymbolNode
          [{ "kind" => "Symbol", "value" => ":#{node.value}" }]
        when Syntax::StringNode
          node.is_a?(Syntax::InterpolatedStringNode) ? [] : [{ "kind" => "String", "value" => node.unescaped.inspect }]
        when Syntax::ArrayNode
          literal_values(node.elements)
        when Syntax::ParenthesesNode
          literal_values([node.body])
        when Syntax::Node
          pattern_literal_value(node)
        else
          []
        end
      end
    end

    def pattern_literal_value(node)
      return [] unless node.raw.kind == "pattern"

      text = node.slice.to_s
      if text.start_with?(":")
        [{ "kind" => "Symbol", "value" => text }]
      elsif text.start_with?("\"", "'") && text.end_with?("\"", "'")
        [{ "kind" => "String", "value" => text[1...-1].inspect }]
      else
        []
      end
    end

    def candidate_value?(value)
      raw = value["value"].to_s
      raw.size <= 80 && !raw.empty?
    end

    def producer_blocker(node)
      return nil unless node
      return "open-world producer" if open_world_source?(node)
      return "dynamic primitive producer" if dynamic_primitive?(node)

      nil
    end

    def open_world_source?(node)
      return false unless node

      if node.is_a?(Syntax::ConstantReadNode)
        return OPEN_WORLD_RECEIVERS.include?(node.full_name.to_s.split("::").first)
      end
      if node.is_a?(Syntax::CallNode)
        receiver = node.receiver
        receiver_name = receiver&.slice.to_s
        return true if OPEN_WORLD_RECEIVERS.include?(receiver_name.split("::").first)
        return true if OPEN_WORLD_METHODS.include?(node.name) && receiver_name.empty?
      end
      node.respond_to?(:compact_child_nodes) && node.compact_child_nodes.any? { |child| open_world_source?(child) }
    end

    def dynamic_primitive?(node)
      return true if node.is_a?(Syntax::InterpolatedStringNode)
      return false unless node.is_a?(Syntax::CallNode)

      DYNAMIC_PRIMITIVE_METHODS.include?(node.name) ||
        (node.respond_to?(:compact_child_nodes) && node.compact_child_nodes.any? { |child| dynamic_primitive?(child) })
    end

    def site_record(site, kind)
      loc = site.location
      source_line = site.context.source.lines[loc.start_line - 1].to_s.strip[0, 160]
      {
        "path" => NilKill.rel(site.context.path || ""),
        "line" => loc.start_line,
        "kind" => kind,
        "code" => source_line,
      }
    end

    def method_params(node, sig)
      p = node.parameters
      return {} unless p

      sig_types = NilKill.extract_param_entries(sig).to_h
      (p.requireds + p.optionals + p.keywords).each_with_object({}) do |param, params|
        next unless param.respond_to?(:name) && param.name
        name = param.name.to_s
        params[name] = { "name" => name, "type" => sig_types[name].to_s }
      end
    end

    def sig_above(lines, line)
      idx = line - 2
      idx -= 1 while idx >= 0 && lines[idx].to_s.strip.empty?
      return nil if idx.negative?

      stripped = lines[idx].to_s.strip
      return stripped if stripped.match?(/\bsig\s*\{/)

      if stripped == "end"
        floor = [idx - 40, 0].max
        idx.downto(floor) do |start_idx|
          current = lines[start_idx].to_s
          return lines[start_idx..idx].join if current.match?(/\bsig\s+do\b/)
          break if current.match?(/^\s*(def|class|module)\b/)
        end
      end

      nil
    end
  end
end
