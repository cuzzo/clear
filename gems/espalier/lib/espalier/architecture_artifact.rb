# frozen_string_literal: true

require "digest"
require "open3"
require "set"
require "time"

module Espalier
  # Projects FactMine's lossless, normalized records into the versioned graph
  # contract consumed by Lineage. Human report formats are deliberately derived
  # from a different compatibility projection and are never parsed here.
  module ArchitectureArtifact
    module_function

    SCHEMA_VERSION = 1

    def build(evidence, root: evidence["root"], commit: nil)
      owners = Array(evidence["owners"])
      methods = Array(evidence["methods"])
      fields = Array(evidence["fields"])
      calls = Array(evidence.dig("facts", "calls"))
      accesses = Array(evidence.dig("facts", "state_accesses"))

      heuristic_owner_ids = owners.reject { |owner| high_confidence_owner?(owner) }
                                   .map { |owner| owner["id"] }.to_set

      nodes = []
      owners.each { |owner| nodes << owner_node(owner, root) if high_confidence_owner?(owner) }
      methods.each { |method| nodes << function_node(method, root, heuristic_owner_ids) }
      fields.each { |field| nodes << state_node(field, root) }

      nodes_by_id = nodes.to_h { |node| [node["id"], node] }
      method_by_id = methods.to_h { |method| [method["id"], method] }
      methods_by_owner_name = methods.group_by { |method| [method["owner"], method["name"]] }
      owners_by_name = owner_name_index(owners)
      fields_by_owner_name = fields.to_h do |field|
        [[field["owner"], normalize_field(field["name"])], field]
      end

      edges = []
      calls.each do |call|
        target = call["target"]
        target ||= resolve_call_target(call, methods_by_owner_name, owners_by_name, fields_by_owner_name)
        resolved = !target.nil?
        unless target
          external_id = external_node_id(call)
          nodes_by_id[external_id] ||= external_node(external_id, call)
          target = external_id
        end
        kind = call["kind"] || "calls"
        kind = "internal_call" if resolved && kind == "unresolved_call"
        kind = "delegation" if resolved && kind == "external_call"
        edges << relationship_edge(call, call["source"], target, kind, root)
      end

      accesses.each do |access|
        source, target = if access["kind"] == "reads"
                           [access["state_id"], access["function_id"]]
                         else
                           [access["function_id"], access["state_id"]]
                         end
        edges << relationship_edge(access, source, target, access["kind"], root)
      end

      # Source-level imports are not part of FactMine's call/state facts, so we
      # scan each analyzed file once for its import/require statements and emit
      # them as `imports` edges (target: an external node named for the module).
      source_files(owners, methods, fields).each do |path, language|
        extract_imports(path, language).each do |mod, line|
          external_id = "external:import:#{Digest::SHA256.hexdigest(mod)[0, 16]}"
          nodes_by_id[external_id] ||= import_target_node(external_id, mod, language)
          edges << import_edge(path, mod, line, external_id, root)
        end
      end

      nodes = nodes_by_id.values
      edges = merge_edges(edges)
      cyclic = cyclic_node_ids(edges)
      cyclic.each do |node_id|
        metadata = nodes_by_id.dig(node_id, "metadata")
        metadata["cycle"] = true if metadata
      end
      pressure = pressure_rows(methods, edges, cyclic)
      pressure.each do |row|
        metadata = nodes_by_id.dig(row["node_id"], "metadata")
        metadata["pressure"] = row if metadata
      end

      {
        "schema_version" => SCHEMA_VERSION,
        "kind" => "espalier.architecture.v1",
        "analyzer" => { "name" => "espalier", "version" => Espalier::VERSION },
        "generated_at" => Time.now.utc.iso8601,
        "corpus" => {
          "commit" => commit || current_commit(root),
          "root" => root.to_s,
          "complete" => evidence.dig("corpus", "complete") == true,
          "completeness_reason" => evidence.dig("corpus", "reason"),
          "languages" => Array(evidence["languages"]).uniq,
          "language_capabilities" => evidence["language_capabilities"] || {}
        },
        "nodes" => nodes.sort_by { |node| [node["kind"], node["path"].to_s, node["start_line"].to_i, node["id"]] },
        "edges" => edges.sort_by { |edge| [edge["source"], edge["target"], edge["kind"], edge["id"]] },
        "pressure" => pressure.sort_by { |row| [-row["score"], row["node_id"]] },
        "hazards" => Array(evidence.dig("facts", "hazards")).map { |h|
          h.merge("path" => relative_path(h["path"], root))
        }.sort_by { |h| [h["path"].to_s, h["line"].to_i, h["hazard_type"].to_s] }
      }
    end

    # FactMine tags an owner "partial" when it could not find a real
    # struct/class/interface declaration and instead guessed one from
    # surrounding context (a typed parameter, a naming convention). That
    # guess is useful as a hint but is not a declared type - rendering it as
    # a first-class owner node makes a heuristic indistinguishable from a
    # real one, and can fabricate an architectural entity (and misattribute
    # unrelated free functions to it) out of nothing but a naming coincidence.
    def high_confidence_owner?(owner)
      (owner["confidence"] || "high") == "high"
    end

    def owner_node(owner, root)
      base_node(owner, "owner", root).merge(
        "metadata" => {
          "owner_kind" => owner["kind"],
          "confidence" => owner["confidence"] || "high"
        }
      )
    end

    def function_node(method, root, heuristic_owner_ids = Set.new)
      owner_id = method["owner_id"]
      owner_id = nil if heuristic_owner_ids.include?(owner_id)
      base_node(method, "function", root).merge(
        "owner_id" => owner_id,
        "metadata" => {
          "visibility" => method["visibility"] || "public",
          "signature" => method["signature"],
          "local_complexity" => method["local_complexity"] || 0.0,
          "complexity_signals" => method["complexity_signals"] || {},
          "confidence" => "high"
        }
      )
    end

    def state_node(field, root)
      base_node(field, "state", root).merge(
        "owner_id" => field["owner_id"],
        "metadata" => {
          "declared_type" => field["declared_type"],
          "type_references" => field["type_references"] || [],
          "confidence" => "high"
        }
      )
    end

    def base_node(record, kind, root)
      span = Array(record["span"])
      {
        "id" => record["id"],
        "kind" => kind,
        "name" => record["name"],
        "owner" => record["owner"] || record["name"],
        "language" => record["language"],
        "path" => relative_path(record["path"], root),
        "start_line" => (span[0] || record["line"] || 1).to_i,
        "start_column" => (span[1] || 0).to_i,
        "end_line" => (span[2] || record["line"] || 1).to_i,
        "end_column" => (span[3] || 0).to_i
      }
    end

    def owner_name_index(owners)
      grouped = owners.group_by { |owner| owner["name"] }
      owners.each do |owner|
        simple = owner["name"].to_s.split(/::|\./).last
        grouped[simple] ||= []
        grouped[simple] << owner unless grouped[simple].include?(owner)
      end
      grouped
    end

    def resolve_call_target(call, methods_by_owner_name, owners_by_name, fields_by_owner_name)
      receiver = call["receiver"].to_s
      owner = call["owner"].to_s
      message = call["message"].to_s
      if receiver.empty? || %w[self this].include?(receiver)
        return unique_method_id(methods_by_owner_name[[owner, message]])
      end

      receiver_owner = Array(owners_by_name[receiver]).one? && owners_by_name[receiver].first["name"]
      unless receiver_owner
        field_name = normalize_field(receiver.sub(/\A(?:self|this)\./, "").split(".").first)
        field = fields_by_owner_name[[owner, field_name]]
        receiver_owner = type_owner(field, owners_by_name) if field
      end
      unique_method_id(methods_by_owner_name[[receiver_owner, message]]) if receiver_owner
    end

    def unique_method_id(rows)
      Array(rows).one? ? rows.first["id"] : nil
    end

    def type_owner(field, owners_by_name)
      candidates = Array(field["type_references"]).flat_map do |reference|
        reference.is_a?(Hash) ? reference.values : reference
      end
      candidates.concat(type_tokens(field["declared_type"]))
      candidates.each do |candidate|
        rows = owners_by_name[candidate.to_s]
        return rows.first["name"] if Array(rows).one?
      end
      nil
    end

    def type_tokens(value)
      case value
      when Hash then value.values.flat_map { |child| type_tokens(child) }
      when Array then value.flat_map { |child| type_tokens(child) }
      else value.to_s.scan(/[A-Z][A-Za-z0-9_:$]*/)
      end
    end

    def normalize_field(name)
      name.to_s.sub(/\A@/, "")
    end

    def external_node_id(call)
      label = call["receiver"].to_s
      label = call["message"].to_s if label.empty? || %w[self this].include?(label)
      "external:#{Digest::SHA256.hexdigest(label)[0, 16]}"
    end

    def external_node(id, call)
      {
        "id" => id,
        "kind" => "external",
        "name" => begin
          receiver = call["receiver"].to_s
          receiver.empty? || %w[self this].include?(receiver) ? call["message"] : receiver
        end,
        "owner" => nil,
        "language" => nil,
        "path" => nil,
        "start_line" => 0,
        "start_column" => 0,
        "end_line" => 0,
        "end_column" => 0,
        "metadata" => {
          "confidence" => call["confidence"] || "partial",
          "unresolved_reason" => call["unresolved_reason"]
        }
      }
    end

    def relationship_edge(record, source, target, kind, root)
      span = Array(record["span"])
      {
        "id" => record["id"] || "edge:#{Digest::SHA256.hexdigest([source, target, kind, span].join("\0"))[0, 16]}",
        "source" => source,
        "target" => target,
        "kind" => kind,
        "conditional" => !!record["conditional"],
        "confidence" => record["confidence"] || "high",
        "weight" => 1,
        "spans" => [{
          "path" => relative_path(record["path"], root),
          "start_line" => (span[0] || record["line"] || 1).to_i,
          "start_column" => (span[1] || 0).to_i,
          "end_line" => (span[2] || record["line"] || 1).to_i,
          "end_column" => (span[3] || 0).to_i
        }],
        "metadata" => {
          "receiver" => record["receiver"],
          "message" => record["message"],
          "unresolved_reason" => record["unresolved_reason"]
        }.compact
      }
    end

    def merge_edges(edges)
      edges.group_by { |edge| [edge["source"], edge["target"], edge["kind"], edge["conditional"], edge.dig("metadata", "message")] }.map do |_key, rows|
        first = rows.first.dup
        first["weight"] = rows.sum { |row| row["weight"].to_i }
        first["spans"] = rows.flat_map { |row| row["spans"] }.uniq
        first
      end
    end

    def cyclic_node_ids(edges)
      call_edges = edges.select { |edge| edge["kind"].include?("call") || edge["kind"] == "delegation" }
      adjacency = call_edges.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |edge, out|
        out[edge["source"]] << edge["target"]
      end
      call_edges.each_with_object([]) do |edge, cyclic|
        source = edge["source"]
        target = edge["target"]
        if source == target || reachable?(adjacency, target, source)
          cyclic << source
          cyclic << target
        end
      end.uniq
    end

    def reachable?(adjacency, start, goal)
      pending = [start]
      seen = {}
      until pending.empty?
        current = pending.pop
        return true if current == goal
        next if seen[current]

        seen[current] = true
        pending.concat(adjacency[current])
      end
      false
    end

    def pressure_rows(methods, edges, cyclic)
      incoming = edges.group_by { |edge| edge["target"] }
      outgoing = edges.group_by { |edge| edge["source"] }
      methods.map do |method|
        ins = Array(incoming[method["id"]])
        outs = Array(outgoing[method["id"]])
        calls = outs.count { |edge| edge["kind"].include?("call") || edge["kind"] == "delegation" }
        reads = ins.count { |edge| edge["kind"] == "reads" }
        writes = outs.count { |edge| edge["kind"] == "writes" }
        collaborators = outs.filter_map { |edge| edge["target"] unless edge["kind"] == "writes" }.uniq.size
        in_cycle = cyclic.include?(method["id"])
        collaboration = [((ins.size + calls + collaborators + (in_cycle ? 2 : 0)) / 12.0), 1.0].min
        state = [((reads + writes * 2) / 8.0), 1.0].min
        implementation = [(method["local_complexity"].to_f / 20.0), 1.0].min
        active_families = [collaboration, state, implementation].count(&:positive?)
        score = ((collaboration * 0.35 + state * 0.35 + implementation * 0.30) * 100).round(1)
        band = score >= 75 && active_families >= 2 ? "red" : score >= 55 ? "orange" : score >= 30 ? "amber" : "ordinary"
        {
          "node_id" => method["id"],
          "score" => score,
          "band" => band,
          "components" => {
            "collaboration" => collaboration.round(3),
            "state" => state.round(3),
            "implementation" => implementation.round(3),
            "operational" => 0.0
          },
          "explanation" => {
            "callers" => ins.count { |edge| edge["kind"].include?("call") },
            "callees" => calls,
            "state_reads" => reads,
            "state_writes" => writes,
            "collaborators" => collaborators,
            "local_complexity" => method["local_complexity"].to_f,
            "cycle" => in_cycle
          }
        }
      end
    end

    def current_commit(root)
      return "" if root.to_s.empty?

      output, status = Open3.capture2("git", "-C", root.to_s, "rev-parse", "HEAD")
      status.success? ? output.strip : ""
    rescue StandardError
      ""
    end

    # Unique {absolute_path => language} over every record that carries a path,
    # so we scan each analyzed source file for imports exactly once.
    def source_files(owners, methods, fields)
      files = {}
      (owners + methods + fields).each do |record|
        path = record["path"]
        next if path.to_s.empty?

        files[path] ||= record["language"]
      end
      files
    end

    def import_target_node(id, mod, language)
      {
        "id" => id, "kind" => "external", "name" => mod, "owner" => nil,
        "language" => language, "path" => nil,
        "start_line" => 0, "start_column" => 0, "end_line" => 0, "end_column" => 0,
        "metadata" => { "confidence" => "high", "import" => true }
      }
    end

    def import_edge(path, mod, line, target, root)
      rel = relative_path(path, root)
      {
        "id" => "import:#{Digest::SHA256.hexdigest([rel, mod].join("\0"))[0, 16]}",
        "source" => "file:#{rel}", "target" => target, "kind" => "imports",
        "conditional" => false, "confidence" => "high", "weight" => 1,
        "spans" => [{ "path" => rel, "start_line" => line, "start_column" => 0,
                      "end_line" => line, "end_column" => 0 }],
        "metadata" => { "module" => mod }
      }
    end

    # Language-specific import/require statements as [module, line] pairs. This
    # is a deliberately small line scanner: the module string as written is what
    # a reviewer wants to see, so no resolution or path normalization is done.
    def extract_imports(path, language)
      source = File.read(path)
      lang = (language || File.extname(path).delete_prefix(".")).to_s.downcase
      case lang
      when "go" then go_imports(source)
      when "ruby", "rb" then scan_imports(source, /^\s*require(?:_relative)?\s+['"]([^'"]+)['"]/)
      when "python", "py" then scan_imports(source, /^\s*(?:from\s+(\S+)\s+import\b|import\s+([^\s,]+))/)
      when "javascript", "js", "jsx", "typescript", "ts", "tsx" then js_imports(source)
      when "rust", "rs" then scan_imports(source, /^\s*use\s+([A-Za-z_][\w:]*)/)
      when "java", "kotlin", "kt" then scan_imports(source, /^\s*import\s+(?:static\s+)?([\w.]+)/)
      when "c", "cpp", "cc", "h", "hpp" then scan_imports(source, /^\s*#\s*include\s+[<"]([^>"]+)[>"]/)
      else []
      end
    rescue StandardError
      []
    end

    # A single capture group per matching line; supports two alternative groups
    # (Python `from X`/`import X`) by taking whichever captured.
    def scan_imports(source, pattern)
      out = []
      source.each_line.with_index(1) do |line, number|
        next unless (match = pattern.match(line))

        mod = match[1] || match[2]
        out << [mod, number] if mod
      end
      out
    end

    # Go supports both `import "x"` and a parenthesized block of quoted paths
    # (optionally aliased). We track the block so the block members are captured.
    def go_imports(source)
      out = []
      in_block = false
      source.each_line.with_index(1) do |line, number|
        if in_block
          break_block = line.include?(")")
          if (match = /["`]([^"`]+)["`]/.match(line))
            out << [match[1], number]
          end
          in_block = false if break_block
        elsif line =~ /^\s*import\s*\(/
          in_block = true
        elsif (match = /^\s*import\s+(?:[\w.]+\s+)?["`]([^"`]+)["`]/.match(line))
          out << [match[1], number]
        end
      end
      out
    end

    def js_imports(source)
      out = []
      source.each_line.with_index(1) do |line, number|
        if (match = /^\s*import\b.*?from\s+['"]([^'"]+)['"]/.match(line)) ||
           (match = /^\s*import\s+['"]([^'"]+)['"]/.match(line)) ||
           (match = /require\(\s*['"]([^'"]+)['"]\s*\)/.match(line))
          out << [match[1], number]
        end
      end
      out
    end

    def relative_path(path, root)
      return path if path.to_s.empty? || root.to_s.empty?

      expanded = File.expand_path(path.to_s)
      prefix = File.expand_path(root.to_s) + File::SEPARATOR
      expanded.start_with?(prefix) ? expanded.delete_prefix(prefix) : path
    end
  end
end
