# frozen_string_literal: true

require "digest"
require "json"
require "set"

module RubyToClear
  module TypedIR
    module CfgFacts
      SCHEMA = "fact-mine.cfg.v1"

      Admission = Struct.new(
        :function, :nodes, :edges, :node_by_prism_id, :complete, :reason,
        keyword_init: true
      ) do
        def cfg_nodes_for(prism_node)
          exact = Array(node_by_prism_id[prism_node.object_id])
          return exact unless exact.empty?

          prism_span = CfgFacts.span(prism_node)
          containing = nodes.select do |node|
            !%w[entry exit exception].include?(node["kind"]) &&
              CfgFacts.span_contains?(Array(node["span"]), prism_span)
          end
          return [] if containing.empty?

          smallest = containing.map { |node| CfgFacts.span_size(Array(node["span"])) }.min
          containing.select { |node| CfgFacts.span_size(Array(node["span"])) == smallest }
        end

        def cfg_node_for(prism_node)
          cfg_nodes_for(prism_node).first
        end

        def live_out_at?(prism_node, place_name)
          cfg_nodes_for(prism_node).any? { |node| live_out?(node["id"], place_name) }
        end

        def live_out?(node_id, place_name)
          places = Array(function["places"]).to_h { |place| [place["id"], place] }
          Array(function["liveness"]).any? do |fact|
            fact["node_id"] == node_id && Array(fact["live_out"]).any? do |place|
              projected = place.is_a?(Hash) ? place : places[place]
              projected && projected["name"] == place_name
            end
          end
        end

        def reaching_definition_ids_at(prism_node, place_name)
          place_id = place_id_for(place_name)
          return [] unless place_id

          cfg_nodes_for(prism_node).flat_map do |node|
            Array(function["reaching_definitions"]).filter_map do |fact|
              fact["definitions"] if fact["node_id"] == node["id"] && fact["place_id"] == place_id
            end
          end.flatten.uniq
        end

        def flow_types_at(prism_node, place_name)
          place_id = place_id_for(place_name)
          return [] unless place_id

          cfg_nodes_for(prism_node).flat_map do |node|
            Array(function["flow_types"]).filter_map do |fact|
              next unless fact["node_id"] == node["id"] && fact["place_id"] == place_id
              next unless fact["complete"]

              fact["types"]
            end
          end.flatten.uniq
        end

        def identity_origin_at(prism_node, place_name)
          place_id = place_id_for(place_name)
          return nil unless place_id

          facts = cfg_nodes_for(prism_node).flat_map do |node|
            Array(function["aliases"]).select do |fact|
              fact["node_id"] == node["id"] && fact["place_id"] == place_id
            end
          end
          return nil if facts.empty?
          return :unknown unless facts.all? do |fact|
            fact["complete"] && fact["relationship"] == "must" && Array(fact["allocation_ids"]).one?
          end

          allocations = Array(function["allocations"]).to_h { |fact| [fact["id"], fact] }
          identities = facts.flat_map { |fact| fact["allocation_ids"] }.uniq
          origins = identities.map { |identity| allocations[identity] && allocations[identity]["fresh"] }
          return :unknown if origins.any?(&:nil?)
          return :fresh if origins.all?(true)
          return :external if origins.all?(false)

          :unknown
        end

        def escape_sinks_at(prism_node, place_name)
          place_id = place_id_for(place_name)
          return [] unless place_id

          node_ids = cfg_nodes_for(prism_node).map { |node| node["id"] }
          Array(function["escapes"]).filter_map do |fact|
            fact["sink"] if node_ids.include?(fact["sink_node_id"]) &&
              fact["via_place_id"] == place_id && fact["complete"]
          end.uniq
        end

        def dominates?(dominator_id, prism_node)
          targets = cfg_nodes_for(prism_node).map { |node| node["id"] }
          targets.any? { |target_id| dominates_node_id?(dominator_id, target_id) }
        end

        private

        def place_id_for(place_name)
          place = Array(function["places"]).find do |candidate|
            candidate["name"] == place_name && candidate["kind"] == "local"
          end
          place && place["id"]
        end

        def dominates_node_id?(dominator_id, target_id)
          parents = Array(function["dominators"]).to_h do |fact|
            [fact["node_id"], fact["immediate_dominator"]]
          end
          current = target_id
          seen = Set.new
          until current.nil? || seen.include?(current)
            return true if current == dominator_id

            seen << current
            current = parents[current]
          end
          false
        end
      end

      class Bundle
        attr_reader :schema, :documents, :reason

        def self.load(source:, source_path: nil, facts_path: nil)
          path = facts_path || ENV["RUBY_TO_CLEAR_CFG_FACTS"]
          return new(reason: "CFG facts were not supplied") if path.to_s.empty?
          return new(reason: "CFG facts file does not exist: #{path}") unless File.file?(path)

          parsed = JSON.parse(File.binread(path))
          new(payload: parsed, source: source, source_path: source_path)
        rescue JSON::ParserError => e
          new(reason: "invalid CFG facts JSON: #{e.message}")
        end

        def initialize(payload: nil, source: nil, source_path: nil, reason: nil)
          @reason = reason
          @schema = payload && payload["cfg_schema"]
          @documents = Array(payload && payload["documents"])
          @source_digest = source && "sha256:#{Digest::SHA256.hexdigest(source)}"
          @source_path = source_path && File.expand_path(source_path)
          @reason ||= "unsupported CFG schema #{@schema.inspect}" unless @schema == SCHEMA
        end

        def available?
          reason.nil?
        end

        def admit_function(prism_function, owner:)
          return unavailable_admission unless available?

          function_span = CfgFacts.span(prism_function)
          document_candidates = matching_documents(prism_function)
          if document_candidates.empty?
            return unavailable_admission("no CFG document matches the current source digest")
          end

          candidates = document_candidates.flat_map do |document|
            Array(document["functions"]).filter_map do |candidate|
              next unless candidate["name"] == prism_function.name.to_s
              next unless Array(candidate["span"]) == function_span

              [document, candidate]
            end
          end
          pair = candidates.find { |_document, candidate| candidate["owner"].to_s == owner.to_s }
          # FactMine gives file-level functions the synthetic file owner while
          # Prism places them on Object. Ruby-to-CLEAR also expands module
          # methods into an including class, so the emitted owner can differ
          # from the source owner. Exact source digest/name/span identity is
          # sufficient when there is only one candidate.
          pair ||= candidates.one? ? candidates.first : nil
          document, function = pair
          return unavailable_admission("no CFG function matches #{owner}##{prism_function.name} at #{function_span.inspect}") unless function

          cfg_owner = cfg_owner_for(document, function, requested_owner: owner)
          cfg_nodes = Array(document["control_flow_nodes"]).select do |node|
            node["function"] == function["name"] && node["owner"].to_s == cfg_owner
          end
          cfg_edges = Array(document["control_flow_edges"]).select do |edge|
            edge["function"] == function["name"] && edge["owner"].to_s == cfg_owner
          end
          prism_by_span = Hash.new { |hash, key| hash[key] = [] }
          CfgFacts.walk(prism_function) { |node| prism_by_span[CfgFacts.span(node)] << node }
          node_by_prism_id = {}
          missing = []

          # Entry, exit, and exception-region nodes are routing identities,
          # not source expressions. FactMine's exception node spans the try
          # body and its handlers, for which Prism intentionally has no single
          # equivalent node; its child statements still require exact maps.
          routing_kinds = %w[entry exit exception]
          cfg_nodes.reject { |node| routing_kinds.include?(node["kind"]) }.each do |cfg_node|
            candidates = prism_by_span[Array(cfg_node["span"])]
            if candidates.empty?
              missing << cfg_node["id"]
            else
              # Prism can give a semantic node and its statement wrapper the
              # same span. FactMine can also duplicate a cleanup statement per
              # incoming control-flow path. Preserve both one-to-many cases.
              candidates.each do |candidate|
                (node_by_prism_id[candidate.object_id] ||= []) << cfg_node
              end
            end
          end

          effects = Array(document["node_effects"]).select do |effect|
            effect["function"] == function["name"] && effect["owner"].to_s == cfg_owner
          end
          liveness = Array(document["liveness"]).select do |fact|
            fact["function"] == function["name"] && fact["owner"].to_s == cfg_owner
          end
          places = Array(document["places"]).select do |place|
            place["function"] == function["name"] && place["owner"].to_s == cfg_owner
          end
          reaching_definitions = Array(document["reaching_definitions"]).select do |fact|
            fact["function"] == function["name"] && fact["owner"].to_s == cfg_owner
          end
          dominators = Array(document["dominators"]).select do |fact|
            fact["function"] == function["name"] && fact["owner"].to_s == cfg_owner
          end
          flow_types = Array(document["flow_types"]).select do |fact|
            fact["function"] == function["name"] && fact["owner"].to_s == cfg_owner
          end
          allocations = Array(document["allocations"]).select do |fact|
            fact["function"] == function["name"] && fact["owner"].to_s == cfg_owner
          end
          aliases = Array(document["aliases"]).select do |fact|
            fact["function"] == function["name"] && fact["owner"].to_s == cfg_owner
          end
          escapes = Array(document["escapes"]).select do |fact|
            fact["function"] == function["name"] && fact["owner"].to_s == cfg_owner
          end
          effect_by_node = effects.to_h { |effect| [effect["node_id"], effect] }
          liveness_by_node = liveness.to_h { |fact| [fact["node_id"], fact] }
          incomplete_dataflow = cfg_nodes.filter_map do |cfg_node|
            effect = effect_by_node[cfg_node["id"]]
            next "#{cfg_node['id']} (missing effect)" unless effect
            next "#{cfg_node['id']} (incomplete effect)" unless effect["complete"]
            next "#{cfg_node['id']} (missing liveness)" unless liveness_by_node.key?(cfg_node["id"])
          end

          function_facts = function.merge(
            "places" => places,
            "liveness" => liveness,
            "reaching_definitions" => reaching_definitions,
            "dominators" => dominators,
            "flow_types" => flow_types,
            "allocations" => allocations,
            "aliases" => aliases,
            "escapes" => escapes
          )
          reasons = []
          reasons << "unmapped CFG nodes: #{missing.join(', ')}" unless missing.empty?
          unless incomplete_dataflow.empty?
            reasons << "incomplete dataflow: #{incomplete_dataflow.join(', ')}"
          end
          Admission.new(
            function: function_facts.freeze,
            nodes: cfg_nodes.freeze,
            edges: cfg_edges.freeze,
            node_by_prism_id: node_by_prism_id.freeze,
            complete: reasons.empty? && !cfg_nodes.empty?,
            reason: reasons.empty? ? nil : reasons.join("; ")
          ).freeze
        end

        private

        def matching_documents(prism_function)
          digest = CfgFacts.source_digest(prism_function) || @source_digest
          matches = documents.select { |document| document["source_digest"] == digest }
          return matches if matches.length <= 1
          return matches if @source_path.nil? || digest != @source_digest

          exact = matches.select do |document|
            file = document["file"].to_s
            File.expand_path(file) == @source_path
          end
          return exact if exact.length == 1

          basename = matches.select do |document|
            File.basename(document["file"].to_s) == File.basename(@source_path)
          end
          basename.length == 1 ? basename : matches
        end

        def cfg_owner_for(document, function, requested_owner:)
          node_owners = Array(document["control_flow_nodes"])
            .select { |node| node["function"] == function["name"] }
            .map { |node| node["owner"].to_s }
            .uniq
          source_owner = function["owner"].to_s
          return source_owner if node_owners.include?(source_owner)
          return "(top-level)" if node_owners.include?("(top-level)")
          return requested_owner.to_s if node_owners.include?(requested_owner.to_s)

          source_owner
        end

        def unavailable_admission(message = reason)
          Admission.new(
            function: {}.freeze, nodes: [].freeze, edges: [].freeze,
            node_by_prism_id: {}.freeze, complete: false, reason: message
          ).freeze
        end
      end

      module_function

      def span(node)
        location = node.location
        [location.start_line, location.start_column, location.end_line, location.end_column]
      end

      def source_digest(node)
        source = node.location.send(:source)
        "sha256:#{Digest::SHA256.hexdigest(source.source)}"
      rescue NoMethodError
        nil
      end

      def span_contains?(outer, inner)
        return false unless outer.length == 4 && inner.length == 4

        ([outer[0], outer[1]] <=> [inner[0], inner[1]]) <= 0 &&
          ([outer[2], outer[3]] <=> [inner[2], inner[3]]) >= 0
      end

      def span_size(span)
        return Float::INFINITY unless span.length == 4

        ((span[2] - span[0]) * 1_000_000) + (span[3] - span[1]).abs
      end

      def walk(node, &block)
        return unless node.is_a?(Prism::Node)

        yield node
        node.child_nodes.each { |child| walk(child, &block) if child }
      end
    end
  end
end
