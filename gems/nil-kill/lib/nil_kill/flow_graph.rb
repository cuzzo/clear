# typed: false
# frozen_string_literal: true

module NilKill
  class FlowGraph
    attr_reader :nodes, :edges

    EDGE_KINDS = Set.new(%w[
      assignment branch_join call_argument return_forward implicit_return explicit_return
      hash_write hash_read array_write array_read set_write set_read block_param runtime_observation
      struct_field call_result
    ]).freeze

    def self.from_evidence(evidence)
      graph = new
      graph.import_evidence(evidence)
      graph
    end

    def initialize
      @nodes = {}
      @edges = []
      @edge_keys = Set.new
      @types = Hash.new { |hash, key| hash[key] = Set.new }
    end

    def add_node(kind, id, data = {})
      id = id.to_s
      current = @nodes[id] || { "id" => id, "kind" => kind.to_s }
      current.merge!(stringify_keys(data))
      @nodes[id] = current
      add_types(id, data["types"] || data[:types])
      add_types(id, [data["type"] || data[:type]])
      id
    end

    def add_edge(kind, from, to, data = {})
      kind = kind.to_s
      edge = stringify_keys(data).merge("kind" => EDGE_KINDS.include?(kind) ? kind : "assignment",
        "from" => from.to_s, "to" => to.to_s)
      key = [edge["kind"], edge["from"], edge["to"], edge["line"], edge["code"], edge["callee"], edge["slot"]]
      return edge unless @edge_keys.add?(key)
      @edges << edge
      add_types(to, types_for(from))
      edge
    end

    def add_types(id, types)
      Array(types).compact.each do |type|
        next if type.to_s.empty?
        @types[id.to_s] << type.to_s
      end
    end

    def types_for(id)
      @types[id.to_s].to_a.sort
    end

    def sorbet_type_for(id)
      NilKill.static_sorbet_type(types_for(id))
    end

    def outgoing(id, kind = nil)
      @edges.select { |edge| edge["from"] == id.to_s && (!kind || edge["kind"] == kind.to_s) }
    end

    def incoming(id, kind = nil)
      @edges.select { |edge| edge["to"] == id.to_s && (!kind || edge["kind"] == kind.to_s) }
    end

    def reachable?(from, to, edge_kinds: nil)
      allowed = edge_kinds && edge_kinds.map(&:to_s).to_set
      seen = Set.new
      queue = [from.to_s]
      until queue.empty?
        current = queue.shift
        return true if current == to.to_s
        next unless seen.add?(current)
        outgoing(current).each do |edge|
          next if allowed && !allowed.include?(edge["kind"])
          queue << edge["to"]
        end
      end
      false
    end

    def hash_record_identity_for_lookup(lookup, include_field: true)
      key = hash_record_key(lookup)
      receiver = lookup["receiver"].to_s
      origin = lookup["origin"] || {}
      base =
        case origin["kind"].to_s
        when "method parameter"
          "param:#{origin["path"]}:#{origin["line"]}:#{origin["name"]}"
        when "hash literal", "array literal"
          "#{origin["kind"].tr(" ", "_")}:#{origin["path"]}:#{origin["line"]}:#{origin["name"]}"
        when "forwarded return"
          "return:#{origin["path"]}:#{origin["line"]}:#{origin["callee"] || origin["code"]}"
        when "instance variable"
          "ivar:#{origin["name"]}"
        else
          scope = lookup["enclosing_scope"].to_s
          path = lookup["path"].to_s
          receiver.empty? ? "unknown:#{path}:#{lookup["line"]}" : "local:#{path}:#{scope}:#{receiver}"
        end
      include_field && key ? "#{base}[:#{key}]" : base
    end

    def hash_record_label_for_lookup(lookup)
      origin = lookup["origin"] || {}
      key = hash_record_key(lookup)
      case origin["kind"].to_s
      when "method parameter"
        if origin["path"]
          "hash record param #{origin["name"]} at #{origin["path"]}:#{origin["line"]}"
        else
          "method parameter hash record #{origin["name"]}"
        end
      when "hash literal", "array literal"
        "hash record #{origin["kind"]} at #{origin["path"]}:#{origin["line"]}"
      when "forwarded return"
        "hash record return #{origin["callee"] || origin["code"]} at #{origin["path"]}:#{origin["line"]}"
      when "instance variable"
        "instance variable hash record #{origin["name"]}"
      else
        receiver = lookup["receiver"].to_s
        path = lookup["path"].to_s
        receiver.empty? ? "unknown hash record" : "local hash record #{receiver} at #{path}"
      end
    end

    def import_evidence(evidence)
      import_methods(evidence)
      import_return_origins(evidence)
      import_param_origins(evidence)
      import_collection_lookups(evidence)
      import_struct_fields(evidence)
      import_runtime(evidence)
      self
    end

    def to_h
      {
        "nodes" => @nodes.values.sort_by { |node| node["id"] },
        "edges" => @edges.sort_by { |edge| [edge["from"], edge["to"], edge["kind"]] },
        "types" => @types.each_with_object({}) { |(id, types), out| out[id] = types.to_a.sort },
      }
    end

    private

    def stringify_keys(hash)
      Hash(hash).each_with_object({}) { |(key, value), out| out[key.to_s] = value }
    end

    def import_methods(evidence)
      methods = Array(evidence.dig("facts", "existing_sigs")) + Array(evidence.dig("facts", "unsigned_methods"))
      methods.each do |method|
        method_id = method_node_id(method)
        add_node("method", method_id, method.slice("path", "line", "class", "method", "kind"))
        Array(method["params"]).each_with_index do |param, idx|
          add_node("param", param_node_id(method, param["name"] || idx), method.merge("slot" => param["name"] || idx, "type" => param["type"]))
        end
        add_node("return", return_node_id(method), method.merge("slot" => "return", "type" => NilKill.extract_return_type(method["sig"].to_s)))
      end
    end

    def import_return_origins(evidence)
      Array(evidence.dig("facts", "return_origins")).each do |origin|
        ret_id = return_node_id(origin)
        add_node("return", ret_id, origin.merge("type" => origin["candidate_type"]))
        Array(origin["sources"]).each_with_index do |source, idx|
          source_id = return_source_node_id(origin, source, idx)
          add_node(source_node_kind(source), source_id, source)
          add_edge(return_edge_kind(origin, source), source_id, ret_id, source.slice("line", "code", "callee"))
          if source["kind"].to_s == "call_untyped" && !source["callee"].to_s.empty?
            callee_id = "return:method_name:#{source["callee"]}"
            add_node("return", callee_id, "method" => source["callee"])
            add_edge("return_forward", callee_id, ret_id, source.slice("line", "code", "callee"))
          end
        end
      end
    end

    def import_param_origins(evidence)
      Array(evidence.dig("facts", "param_origins")).each do |origin|
        param_id = "param:callee:#{origin["callee"]}:#{origin["arg_kind"]}:#{origin["slot"]}"
        add_node("param", param_id, origin.merge("type" => origin["type"]))
        source_id = "call_arg:#{origin["path"]}:#{origin["line"]}:#{origin["callee"]}:#{origin["arg_kind"]}:#{origin["slot"]}"
        add_node(source_node_kind("kind" => origin["origin_kind"]), source_id, origin.merge("type" => origin["type"]))
        add_edge("call_argument", source_id, param_id, origin.slice("path", "line", "callee", "slot", "code"))
        if %w[typed_return untyped_return].include?(origin["origin_kind"].to_s) && !origin["source_method"].to_s.empty?
          ret_id = "return:method_name:#{origin["source_method"]}"
          add_node("return", ret_id, "method" => origin["source_method"], "type" => origin["type"])
          add_edge("call_result", ret_id, source_id, origin.slice("path", "line", "source_method"))
        end
      end
    end

    def import_collection_lookups(evidence)
      Array(evidence.dig("facts", "collection_index_lookups")).each do |lookup|
        receiver_id = hash_record_identity_for_lookup(lookup)
        add_node("hash_field", receiver_id, lookup.merge("type" => lookup["lookup_type"]))
        read_id = "hash_read:#{lookup["path"]}:#{lookup["line"]}:#{lookup["code"]}"
        add_node("call_result", read_id, lookup.merge("type" => lookup["lookup_type"]))
        add_edge("hash_read", receiver_id, read_id, lookup.slice("path", "line", "code", "index"))
      end
    end

    def import_struct_fields(evidence)
      Array(evidence.dig("facts", "struct_field_static")).each do |field|
        field_id = "struct_field:#{field["class"]}:#{field["field"]}"
        add_node("struct_field", field_id, field.merge("type" => field["type"]))
        value_id = "literal:#{field["path"]}:#{field["line"]}:#{field["expression"]}"
        add_node("literal", value_id, field.merge("type" => field["type"]))
        add_edge("struct_field", value_id, field_id, field.slice("path", "line", "expression"))
      end
    end

    def import_runtime(evidence)
      Array(evidence["methods"]).each do |method|
        source = method["source"] || {}
        next unless source["path"]
        ret_id = return_node_id(source)
        add_node("return", ret_id, source)
        add_types(ret_id, method["returns"])
        add_edge("runtime_observation", "runtime:#{source["path"]}:#{source["line"]}:return", ret_id,
          "classes" => Array(method["returns"]), "calls" => method["calls"])
        Hash(method["params_by_name"]).each do |name, classes|
          param_id = param_node_id(source, name)
          add_node("param", param_id, source.merge("slot" => name))
          add_types(param_id, classes)
          add_edge("runtime_observation", "runtime:#{source["path"]}:#{source["line"]}:param:#{name}", param_id,
            "classes" => classes, "calls" => method["calls"])
        end
      end
      Array(evidence.dig("facts", "collection_runtime")).each do |rec|
        id = "runtime_collection:#{rec["owner_kind"]}:#{rec["path"]}:#{rec["line"]}:#{rec["name"]}:#{rec["kind"]}"
        add_node("runtime_observation", id, rec)
      end
    end

    def method_node_id(method)
      "method:#{method["path"]}:#{method["line"]}:#{method["class"]}:#{method["method"]}:#{method["kind"]}"
    end

    def return_node_id(method)
      "return:#{method["path"]}:#{method["line"]}:#{method["class"]}:#{method["method"]}:#{method["kind"]}"
    end

    def param_node_id(method, name)
      "param:#{method["path"]}:#{method["line"]}:#{method["class"]}:#{method["method"]}:#{method["kind"]}:#{name}"
    end

    def return_source_node_id(origin, source, idx)
      "#{source_node_kind(source)}:#{origin["path"]}:#{source["line"] || origin["line"]}:#{source["code"] || source["callee"] || idx}"
    end

    def source_node_kind(source)
      kind = source["kind"].to_s
      return "runtime_observation" if kind == "runtime"
      return "literal" if %w[static nil].include?(kind)
      return "call_result" if kind.include?("return") || kind.include?("call")
      kind.empty? ? "unknown" : kind
    end

    def return_edge_kind(origin, source)
      return "explicit_return" if origin["return_syntax"] == "explicit"
      return "return_forward" if source["kind"].to_s.include?("call")
      "implicit_return"
    end

    def hash_record_key(lookup)
      index = lookup["index"].to_s
      case index
      when /\A:([A-Za-z_]\w*[!?=]?)\z/
        Regexp.last_match(1)
      when /\A["']([^"']+)["']\z/
        Regexp.last_match(1)
      end
    end
  end
end
