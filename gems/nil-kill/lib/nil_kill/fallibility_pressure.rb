# typed: false
# frozen_string_literal: true

module NilKill
  # Runtime-aware static fallibility pressure.
  #
  # The scanner keeps two related signals separate:
  # - unhandled propagation: direct raise roots that leak through callers
  # - handler pressure: rescue/fallback sites that protect calls reaching roots
  #
  # A handler can have several roots. Each root participates in the handler;
  # the report preserves sharedness instead of claiming one root uniquely
  # deletes the rescue.
  class FallibilityPressure
    MethodInfo = Struct.new(:id, :owner, :kind, :name, :path, :line, :label, keyword_init: true)
    DirectSource = Struct.new(:method_id, :kind, :path, :line, :code, keyword_init: true)
    Handler = Struct.new(:id, :method_id, :path, :line, :kind, :rescues, :calls, :direct_roots, :unknown_calls, keyword_init: true)

    STATIC_SOURCE_MIDS = %i[raise fail error!].freeze
    METHOD_BOUNDARY_CLASSES = [
      Syntax::DefNode,
      Syntax::ClassNode,
      Syntax::ModuleNode,
      Syntax::SingletonClassNode,
      Syntax::LambdaNode,
    ].freeze

    def self.scan(files, runtime_methods: [], runtime_edges: [])
      new(files, runtime_methods: runtime_methods, runtime_edges: runtime_edges).scan
    end

    def initialize(files, runtime_methods:, runtime_edges:)
      @files = files
      @runtime_methods = runtime_methods
      @runtime_edges = runtime_edges
      @methods = {}
      @methods_by_signature = Hash.new { |hash, key| hash[key] = [] }
      @methods_by_name = Hash.new { |hash, key| hash[key] = [] }
      @mixins_by_owner_kind = Hash.new { |hash, key| hash[key] = [] }
      @unhandled_edges = Hash.new { |hash, key| hash[key] = Set.new }
      @all_edges = Hash.new { |hash, key| hash[key] = Set.new }
      @direct_sources = Hash.new { |hash, key| hash[key] = [] }
      @handlers = []
      @handlers_by_id = {}
      @runtime_by_method = {}
      @runtime_lifecycle_by_method = {}
      @runtime_edges_by_pair = {}
    end

    def scan
      collect_methods
      collect_runtime_methods
      collect_method_bodies
      collect_runtime_edges
      build_rows
    end

    private

    def collect_methods
      @files.each do |path|
        parsed = NilKill.cached_parse_file(path)
        next unless parsed.success?

        collect_method_defs(parsed.value, [], NilKill.rel(path))
      end
    end

    def collect_method_defs(node, scope, rel_path, default_owner: nil, default_kind: "instance")
      return unless syntax_node?(node)

      case node
      when Syntax::ClassNode, Syntax::ModuleNode
        new_scope = [qualify_const(scope, const_name(node.constant_path))]
        node.compact_child_nodes.each { |child| collect_method_defs(child, new_scope, rel_path) }
      when Syntax::SingletonClassNode
        owner = singleton_owner(node.expression, scope)
        node.compact_child_nodes.each do |child|
          collect_method_defs(child, scope, rel_path, default_owner: owner, default_kind: "class")
        end
      when Syntax::ConstantWriteNode, Syntax::ConstantPathWriteNode
        if (block = constant_assignment_block(node))
          collect_method_defs(block, [constant_assignment_owner(node, scope)], rel_path)
        else
          node.compact_child_nodes.each do |child|
            collect_method_defs(child, scope, rel_path, default_owner: default_owner, default_kind: default_kind)
          end
        end
      when Syntax::DefNode
        register_method(node, scope, rel_path, default_owner: default_owner, default_kind: default_kind)
      when Syntax::CallNode
        register_mixin_call(node, scope, default_owner: default_owner, default_kind: default_kind)
        node.compact_child_nodes.each do |child|
          collect_method_defs(child, scope, rel_path, default_owner: default_owner, default_kind: default_kind)
        end
      else
        node.compact_child_nodes.each do |child|
          collect_method_defs(child, scope, rel_path, default_owner: default_owner, default_kind: default_kind)
        end
      end
    end

    def register_method(node, scope, rel_path, default_owner:, default_kind:)
      owner = method_owner(node, scope, default_owner)
      kind = method_kind(node, default_kind)
      name = node.name.to_s
      id = method_id(rel_path, node.location.start_line, owner, kind, name)
      info = MethodInfo.new(
        id: id,
        owner: owner,
        kind: kind,
        name: name,
        path: rel_path,
        line: node.location.start_line,
        label: method_label(owner, kind, name)
      )
      @methods[id] = info
      @methods_by_signature[[owner, kind, name]] << id
      @methods_by_name[name] << id
    end

    def register_mixin_call(node, scope, default_owner:, default_kind:)
      return unless %i[include prepend extend].include?(node.name)
      return unless node.receiver.nil? || node.receiver.is_a?(Syntax::SelfNode)

      owner = default_owner || scope_owner(scope)
      return if owner.empty?

      target_kind = node.name == :extend ? "class" : default_kind
      lexical_owner = scope_owner(scope)
      Array(node.arguments&.arguments).each do |arg|
        next unless constant_receiver?(arg)

        @mixins_by_owner_kind[[owner, target_kind]] << {
          "raw" => const_name(arg),
          "lexical_owner" => lexical_owner,
        }
      end
    end

    def collect_runtime_methods
      @runtime_methods.each do |rec|
        rel_path = NilKill.rel(rec["path"].to_s)
        owner = rec["class"].to_s
        kind = rec["kind"].to_s
        name = rec["method"].to_s
        line = rec["line"].to_i
        id = ensure_runtime_method(rel_path, line, owner, kind, name)
        @runtime_lifecycle_by_method[id] = merge_runtime_record(@runtime_lifecycle_by_method[id], rec)
        @runtime_by_method[id] = merge_runtime_record(@runtime_by_method[id], rec) if rec["raised_calls"].to_i.positive?
      end
    end

    def collect_method_bodies
      @files.each do |path|
        parsed = NilKill.cached_parse_file(path)
        next unless parsed.success?

        collect_bodies(parsed.value, [], NilKill.rel(path))
      end
    end

    def collect_bodies(node, scope, rel_path, default_owner: nil, default_kind: "instance")
      return unless syntax_node?(node)

      case node
      when Syntax::ClassNode, Syntax::ModuleNode
        new_scope = [qualify_const(scope, const_name(node.constant_path))]
        node.compact_child_nodes.each { |child| collect_bodies(child, new_scope, rel_path) }
      when Syntax::SingletonClassNode
        owner = singleton_owner(node.expression, scope)
        node.compact_child_nodes.each do |child|
          collect_bodies(child, scope, rel_path, default_owner: owner, default_kind: "class")
        end
      when Syntax::ConstantWriteNode, Syntax::ConstantPathWriteNode
        if (block = constant_assignment_block(node))
          collect_bodies(block, [constant_assignment_owner(node, scope)], rel_path)
        else
          node.compact_child_nodes.each do |child|
            collect_bodies(child, scope, rel_path, default_owner: default_owner, default_kind: default_kind)
          end
        end
      when Syntax::DefNode
        id = method_id(
          rel_path,
          node.location.start_line,
          method_owner(node, scope, default_owner),
          method_kind(node, default_kind),
          node.name.to_s
        )
        collect_in_method(node.body, id, nil)
      else
        node.compact_child_nodes.each do |child|
          collect_bodies(child, scope, rel_path, default_owner: default_owner, default_kind: default_kind)
        end
      end
    end

    def collect_in_method(node, current_method_id, current_handler_id)
      return unless syntax_node?(node)
      return if nested_method_boundary?(node)

      case node
      when Syntax::BeginNode
        collect_begin_node(node, current_method_id, current_handler_id)
      when Syntax::RescueModifierNode
        collect_rescue_modifier(node, current_method_id, current_handler_id)
      when Syntax::CallNode
        inspect_call_node(node, current_method_id, current_handler_id)
        node.compact_child_nodes.each { |child| collect_in_method(child, current_method_id, current_handler_id) }
      else
        node.compact_child_nodes.each { |child| collect_in_method(child, current_method_id, current_handler_id) }
      end
    end

    def collect_begin_node(node, current_method_id, current_handler_id)
      if node.rescue_clause
        handler = new_handler(node, current_method_id, "rescue")
        register_handler(handler)
        collect_in_method(node.statements, current_method_id, handler.id)
        collect_rescue_chain(node.rescue_clause, current_method_id, current_handler_id)
        collect_in_method(node.else_clause, current_method_id, current_handler_id)
        collect_in_method(node.ensure_clause, current_method_id, current_handler_id)
      else
        node.compact_child_nodes.each { |child| collect_in_method(child, current_method_id, current_handler_id) }
      end
    end

    def collect_rescue_modifier(node, current_method_id, current_handler_id)
      handler = Handler.new(
        id: handler_id(current_method_id, node.location.start_line, "rescue_modifier"),
        method_id: current_method_id,
        path: @methods.fetch(current_method_id).path,
        line: node.location.start_line,
        kind: "rescue_modifier",
        rescues: ["StandardError"],
        calls: Set.new,
        direct_roots: Set.new,
        unknown_calls: 0
      )
      register_handler(handler)
      collect_in_method(node.expression, current_method_id, handler.id)
      collect_in_method(node.rescue_expression, current_method_id, current_handler_id)
    end

    def collect_rescue_chain(node, current_method_id, current_handler_id)
      while node
        collect_in_method(node.statements, current_method_id, current_handler_id)
        node = node.subsequent
      end
    end

    def inspect_call_node(node, current_method_id, current_handler_id)
      source_kind = direct_source_kind(node)
      if source_kind
        @direct_sources[current_method_id] << DirectSource.new(
          method_id: current_method_id,
          kind: source_kind,
          path: @methods.fetch(current_method_id).path,
          line: node.location.start_line,
          code: first_line(node.slice)
        )
        if current_handler_id
          handler = @handlers_by_id[current_handler_id]
          handler&.direct_roots&.add(current_method_id)
        end
      end

      callee_id = resolve_call(node, current_method_id)
      if callee_id
        @all_edges[current_method_id] << callee_id
        if current_handler_id
          handler = @handlers_by_id[current_handler_id]
          handler&.calls&.add(callee_id)
        else
          @unhandled_edges[current_method_id] << callee_id
        end
      elsif current_handler_id && projectish_call?(node) && !source_kind
        handler = @handlers_by_id[current_handler_id]
        handler.unknown_calls += 1 if handler
      end
    end

    def direct_source_kind(node)
      return nil unless node.is_a?(Syntax::CallNode)
      return "fixable_error" if fixable_error_call?(node)
      return node.name.to_s if STATIC_SOURCE_MIDS.include?(node.name)
      nil
    end

    def fixable_error_call?(node)
      return false unless node.name == :fixable!
      (node.arguments&.arguments || []).grep(Syntax::KeywordHashNode).any? do |kw|
        kw.elements.any? do |assoc|
          assoc.respond_to?(:key) && assoc.respond_to?(:value) &&
            hash_key_name(assoc.key) == "level" &&
            assoc.value.is_a?(Syntax::SymbolNode) &&
            assoc.value.unescaped == "error"
        end
      end
    end

    def resolve_call(node, current_method_id)
      return nil unless node.is_a?(Syntax::CallNode)
      return nil if direct_source_kind(node)

      current = @methods.fetch(current_method_id)
      name = node.name.to_s
      receiver = node.receiver
      if receiver.nil? || receiver.is_a?(Syntax::SelfNode)
        same_owner = @methods_by_signature[[current.owner, current.kind, name]]
        return same_owner.first if same_owner.size == 1

        mixed_in = mixin_method_candidates(current.owner, current.kind, name)
        return mixed_in.first if mixed_in.size == 1
      elsif constant_receiver?(receiver)
        ids = class_method_candidates(current.owner, receiver, name)
        return ids.first if ids.size == 1
      end

      unique = @methods_by_name[name]
      unique.first if unique.size == 1
    end

    def build_rows
      root_ids = (@direct_sources.keys + @runtime_by_method.keys).uniq
      return [] if root_ids.empty?

      all_roots_cache = {}
      unhandled_roots_cache = {}
      handler_attributions = handler_attributions(all_roots_cache)
      fallible_callers = fallible_callers_by_root(root_ids, unhandled_roots_cache)

      root_ids.map do |root_id|
        method = @methods.fetch(root_id)
        runtime = @runtime_by_method[root_id] || {}
        handlers = handler_attributions[root_id] || []
        direct = @direct_sources[root_id] || []
        shared_handlers = handlers.count { |handler| Array(handler["roots"]).size > 1 }
        exclusive_handlers = handlers.size - shared_handlers
        callers = Array(fallible_callers[root_id]).sort
        raised_calls = runtime["raised_calls"].to_i
        calls = runtime["calls"].to_i
        score = (handlers.size * 4) + (callers.size * 2) + direct.size + raised_calls
        {
          "method_id" => root_id,
          "label" => method.label,
          "path" => method.path,
          "line" => method.line,
          "score" => score,
          "direct_sources" => direct.map { |source| direct_source_hash(source) },
          "runtime" => runtime_summary(runtime),
          "fallible_callers" => callers,
          "handler_pressure" => handlers.size,
          "exclusive_handlers" => exclusive_handlers,
          "shared_handlers" => shared_handlers,
          "handlers" => handlers.sort_by { |handler| [handler["path"], handler["line"].to_i, handler["method"]] },
        }
      end.sort_by { |row| [-row["score"].to_i, -row["handler_pressure"].to_i, -row["fallible_callers"].size, row["path"], row["line"].to_i] }
    end

    def handler_attributions(all_roots_cache)
      out = Hash.new { |hash, key| hash[key] = [] }
      @handlers.each do |handler|
        roots = (
          handler.direct_roots.to_a +
          handler.calls.flat_map { |callee_id| roots_reachable(callee_id, @all_edges, all_roots_cache) }
        ).uniq.sort
        next if roots.empty?

        root_labels = roots.map { |id| @methods.fetch(id).label }.sort
        protected = (handler.calls.to_a + handler.direct_roots.to_a).uniq
        roots.each do |root_id|
          out[root_id] << {
            "path" => handler.path,
            "line" => handler.line,
            "method" => @methods.fetch(handler.method_id).label,
            "kind" => handler.kind,
            "roots" => root_labels,
            "protected_calls" => protected.map { |id| @methods.fetch(id).label }.sort,
            "unknown_calls" => handler.unknown_calls,
          }
        end
      end
      out
    end

    def fallible_callers_by_root(root_ids, unhandled_roots_cache)
      out = Hash.new { |hash, key| hash[key] = Set.new }
      @methods.each_key do |method_id|
        roots_reachable(method_id, @unhandled_edges, unhandled_roots_cache).each do |root_id|
          next unless root_ids.include?(root_id)
          next if root_id == method_id

          out[root_id] << @methods.fetch(method_id).label
        end
      end
      out
    end

    def roots_reachable(method_id, edges, cache, visiting = Set.new)
      return cache[method_id] if cache.key?(method_id)
      return [] if visiting.include?(method_id)

      roots = []
      roots << method_id if @direct_sources[method_id]&.any? || @runtime_by_method[method_id]
      visiting.add(method_id)
      Array(edges[method_id]).each do |callee_id|
        roots.concat(roots_reachable(callee_id, edges, cache, visiting))
      end
      visiting.delete(method_id)
      cache[method_id] = roots.uniq.sort
    end

    def new_handler(node, current_method_id, kind)
      Handler.new(
        id: handler_id(current_method_id, node.location.start_line, kind),
        method_id: current_method_id,
        path: @methods.fetch(current_method_id).path,
        line: node.location.start_line,
        kind: kind,
        rescues: rescue_classes(node.rescue_clause),
        calls: Set.new,
        direct_roots: Set.new,
        unknown_calls: 0
      )
    end

    def rescue_classes(rescue_node)
      classes = []
      node = rescue_node
      while node
        exceptions = Array(node.exceptions)
        classes.concat(exceptions.map { |exception| const_name(exception) })
        node = node.subsequent
      end
      classes.empty? ? ["StandardError"] : classes.uniq.sort
    end

    def runtime_summary(runtime)
      calls = runtime["calls"].to_i
      raised_calls = runtime["raised_calls"].to_i
      {
        "calls" => calls,
        "ok_calls" => runtime["ok_calls"].to_i,
        "raised_calls" => raised_calls,
        "raised_rate" => calls.positive? ? ((raised_calls.to_f / calls) * 100).round(1) : 0.0,
        "raised_classes" => Array(runtime["raised"]).uniq.sort,
      }
    end

    def direct_source_hash(source)
      {
        "kind" => source.kind,
        "path" => source.path,
        "line" => source.line,
        "code" => source.code,
      }
    end

    def merge_runtime_record(existing, rec)
      merged = existing || {
        "calls" => 0,
        "ok_calls" => 0,
        "raised_calls" => 0,
        "raised" => [],
      }
      merged["calls"] += rec["calls"].to_i
      merged["ok_calls"] += rec["ok_calls"].to_i
      merged["raised_calls"] += rec["raised_calls"].to_i
      merged["raised"] = (Array(merged["raised"]) + Array(rec["raised"])).uniq.sort
      merged
    end

    def collect_runtime_edges
      @runtime_edges.each do |edge|
        caller_id = runtime_edge_endpoint_id(edge["caller"])
        callee_id = runtime_edge_endpoint_id(edge["callee"])
        next unless caller_id && callee_id
        next if caller_id == callee_id

        @all_edges[caller_id] << callee_id
        @unhandled_edges[caller_id] << callee_id unless observed_handled_runtime_edge?(edge, caller_id)
        @runtime_edges_by_pair[[caller_id, callee_id]] = merge_runtime_edge(@runtime_edges_by_pair[[caller_id, callee_id]], edge)
      end
    end

    def runtime_edge_endpoint_id(endpoint)
      return nil unless endpoint.is_a?(Hash)

      rel_path = NilKill.rel(endpoint["path"].to_s)
      owner = endpoint["class"].to_s
      kind = endpoint["kind"].to_s
      name = endpoint["method"].to_s
      line = endpoint["line"].to_i
      ensure_runtime_method(rel_path, line, owner, kind, name)
    end

    def ensure_runtime_method(rel_path, line, owner, kind, name)
      id = resolve_runtime_method_id(rel_path, line, owner, kind, name)
      return id if id

      id = method_id(rel_path, line, owner, kind, name)
      @methods[id] = MethodInfo.new(
        id: id,
        owner: owner,
        kind: kind,
        name: name,
        path: rel_path,
        line: line,
        label: method_label(owner, kind, name)
      )
      @methods_by_signature[[owner, kind, name]] << id
      @methods_by_name[name] << id
      id
    end

    def observed_handled_runtime_edge?(edge, caller_id)
      return false unless edge["raised_calls"].to_i.positive?

      caller_runtime = @runtime_lifecycle_by_method[caller_id]
      caller_runtime && caller_runtime["raised_calls"].to_i.zero?
    end

    def merge_runtime_edge(existing, edge)
      merged = existing || {
        "calls" => 0,
        "ok_calls" => 0,
        "raised_calls" => 0,
      }
      merged["calls"] += edge["calls"].to_i
      merged["ok_calls"] += edge["ok_calls"].to_i
      merged["raised_calls"] += edge["raised_calls"].to_i
      merged
    end

    def resolve_runtime_method_id(rel_path, line, owner, kind, name)
      exact = method_id(rel_path, line, owner, kind, name)
      return exact if @methods.key?(exact)

      candidates = @methods_by_signature[[owner, kind, name]]
      return candidates.first if candidates.size == 1
      nil
    end

    def method_owner(node, scope, default_owner)
      receiver = node.receiver
      case receiver
      when nil
        default_owner || scope_owner(scope)
      when Syntax::SelfNode
        default_owner || scope_owner(scope)
      else
        constant_receiver?(receiver) ? qualify_const(scope, const_name(receiver)) : first_line(receiver.slice)
      end
    end

    def method_kind(node, default_kind = "instance")
      node.receiver ? "class" : default_kind
    end

    def singleton_owner(expression, scope)
      case expression
      when Syntax::SelfNode
        scope_owner(scope)
      else
        return qualify_const(scope, const_name(expression)) if constant_receiver?(expression)

        owner = scope_owner(scope)
        suffix = first_line(expression&.slice)
        [owner, "<singleton:#{suffix}>"].reject(&:empty?).join("::")
      end
    end

    def constant_assignment_block(node)
      value = node.respond_to?(:value) ? node.value : nil
      value.is_a?(Syntax::CallNode) && class_factory_call?(value) ? value.block : nil
    end

    def class_factory_call?(node)
      receiver_name = const_name(node.receiver)
      (receiver_name == "Struct" && node.name == :new) ||
        (receiver_name == "Class" && node.name == :new) ||
        (receiver_name == "Data" && node.name == :define)
    end

    def constant_assignment_owner(node, scope)
      case node
      when Syntax::ConstantWriteNode
        qualify_const(scope, node.name.to_s)
      when Syntax::ConstantPathWriteNode
        qualify_const(scope, const_name(node.target))
      else
        scope_owner(scope)
      end
    end

    def register_handler(handler)
      @handlers << handler
      @handlers_by_id[handler.id] = handler
    end

    def class_method_candidates(current_owner, receiver, name)
      const_candidates(current_owner, const_name(receiver)).each do |owner|
        ids = @methods_by_signature[[owner, "class", name]]
        return ids unless ids.empty?
      end
      []
    end

    def mixin_method_candidates(owner, kind, name, visited = Set.new)
      key = [owner, kind]
      return [] if visited.include?(key)

      visited.add(key)
      @mixins_by_owner_kind[key].reverse_each do |entry|
        const_candidates(entry["lexical_owner"], entry["raw"]).each do |mixin_owner|
          ids = @methods_by_signature[[mixin_owner, "instance", name]] +
            mixin_method_candidates(mixin_owner, "instance", name, visited.dup)
          return ids.uniq unless ids.empty?
        end
      end
      []
    end

    def const_candidates(current_owner, raw_name)
      raw = raw_name.to_s
      return [] if raw.empty?
      return [raw.delete_prefix("::")] if raw.start_with?("::")

      parts = current_owner.to_s.split("::").reject(&:empty?)
      candidates = []
      parts.length.downto(0) do |idx|
        prefix = parts.first(idx).join("::")
        candidates << [prefix, raw].reject(&:empty?).join("::")
      end
      candidates.uniq
    end

    def qualify_const(scope, raw_name)
      raw = raw_name.to_s
      return "" if raw.empty?
      return raw.delete_prefix("::") if raw.start_with?("::")

      current = scope_owner(scope)
      return raw if current.empty?

      first = raw.split("::").first
      return raw if current.split("::").first == first

      "#{current}::#{raw}"
    end

    def scope_owner(scope)
      scope.reject(&:empty?).join("::")
    end

    def method_id(path, line, owner, kind, name)
      [path, line.to_i, owner, kind, name].join("\0")
    end

    def handler_id(method_id, line, kind)
      "#{method_id}\0handler\0#{kind}\0#{line}"
    end

    def method_label(owner, kind, name)
      prefix = owner.to_s.empty? ? "(top-level)" : owner
      sep = kind == "class" ? "." : "#"
      "#{prefix}#{sep}#{name}"
    end

    def nested_method_boundary?(node)
      METHOD_BOUNDARY_CLASSES.any? { |klass| node.is_a?(klass) }
    end

    def constant_receiver?(node)
      node.is_a?(Syntax::ConstantReadNode) || node.is_a?(Syntax::ConstantPathNode)
    end

    def const_name(node)
      return "" unless node
      node.respond_to?(:full_name) ? (node.full_name rescue node.slice.to_s) : node.slice.to_s
    end

    def hash_key_name(node)
      case node
      when Syntax::SymbolNode
        node.unescaped.to_s
      when Syntax::StringNode
        node.unescaped.to_s
      end
    end

    def projectish_call?(node)
      node.is_a?(Syntax::CallNode) &&
        !STATIC_SOURCE_MIDS.include?(node.name) &&
        !%i[is_a? kind_of? instance_of? respond_to? nil? class object_id].include?(node.name)
    end

    def first_line(code)
      code.to_s.lines.first.to_s.strip[0, 160]
    end

    def syntax_node?(node)
      node.is_a?(Syntax::Node)
    end
  end
end
