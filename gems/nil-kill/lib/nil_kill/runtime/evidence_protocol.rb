# typed: false
# frozen_string_literal: true

require_relative "protocol/runtime_evidence_pb"

module NilKill
  module Runtime
    # NilKill's mechanical adapter for FactMine's canonical runtime evidence
    # protocol. It contains wire encoding and runtime-value serialization only:
    # source semantics, CFG/DFG propagation, and call inference remain in
    # FactMine.
    module EvidenceProtocol
      VERSION = 1
      PRODUCER = "nil-kill"
      PRODUCER_VERSION = "1"
      AUTHORITY = "MODELED_RUNS"

      module_function

      def plan
        private_plan = JSON.parse(File.read(NilKill::TRACE_PLAN_PATH))
        validate_plan!(private_plan.fetch("runtime_evidence"))
      rescue Errno::ENOENT
        raise ArgumentError, "missing FactMine runtime trace plan; run nil-kill collect"
      end

      def validate_plan!(value)
        value = canonical_message(
          Factmine::Runtime::V1::TracePlan,
          value,
          "FactMine runtime evidence plan"
        )
        unless value["protocol_version"] == VERSION &&
            !value["plan_digest"].to_s.empty? && value["requests"].is_a?(Array)
          raise ArgumentError, "invalid FactMine runtime evidence plan"
        end
        symbols = value.fetch("requests").map { |request| request.dig("anchor", "symbol") }
        raise ArgumentError, "runtime evidence plan contains duplicate/missing anchors" if
          symbols.any? { |symbol| symbol.to_s.empty? } || symbols.uniq.length != symbols.length
        message = Factmine::Runtime::V1::TracePlan.decode_json(
          JSON.generate(value),
          ignore_unknown_fields: false
        )
        supplied_digest = message.plan_digest
        message.plan_digest = ""
        unless Digest::SHA256.digest(
          Factmine::Runtime::V1::TracePlan.encode(message)
        ) == supplied_digest
          raise ArgumentError, "FactMine runtime evidence plan digest does not match its contents"
        end

        value
      end

      def validate_evidence!(value)
        value = canonical_message(
          Factmine::Runtime::V1::RuntimeEvidence,
          value,
          "runtime semantic evidence"
        )
        unless value["protocol_version"] == VERSION &&
            value["authority"] == AUTHORITY &&
            !value["trace_plan_digest"].to_s.empty? &&
            value["anchors"].is_a?(Array)
          raise ArgumentError, "invalid runtime semantic evidence"
        end

        value
      end

      def encode_evidence(value)
        JSON.pretty_generate(validate_evidence!(value)) + "\n"
      end

      def canonical_message(message_class, value, label)
        message = message_class.decode_json(
          JSON.generate(value),
          ignore_unknown_fields: false
        )
        JSON.parse(
          message_class.encode_json(
            message,
            preserve_proto_fieldnames: true,
            emit_defaults: true
          )
        )
      rescue Google::Protobuf::ParseError, Google::Protobuf::TypeError, JSON::ParserError => e
        raise ArgumentError, "invalid #{label}: #{e.message}"
      end

      def value_set(domain, count:, provider:, source_role: "UNKNOWN_SOURCE")
        domain = Hash(domain || {})
        types = Array(domain["types"] || domain[:types]).map(&:to_s).reject(&:empty?).uniq.sort
        return if types.empty?

        roles = Hash(domain["source_roles"] || domain[:source_roles])
        alternatives = types.map do |type|
          {
            "value" => runtime_value(
              type,
              domain: domain,
              provider: provider,
              source_role: roles.fetch(type, source_role)
            ),
            # NilKill's compact raw stores retain support sets rather than
            # per-alternative frequency. One is an exact positive witness;
            # ExecutionBucket.count retains the observed execution count.
            "count" => 1,
          }
        end
        { "alternatives" => alternatives }
      end

      def runtime_value(type, domain:, provider:, source_role:)
        value = {
          "type_symbol" => provider.runtime_evidence_type_symbol(type),
          "source_role" => normalize_source_role(source_role),
        }
        singleton = Array(domain["singletons"] || domain[:singletons]).map(&:to_s)
          .reject(&:empty?).uniq
        value["singleton_symbol"] =
          provider.runtime_evidence_singleton_symbol(singleton.first) if singleton.one?
        shape = runtime_shape(type, domain, provider, source_role)
        value.merge!(shape) if shape
        value
      end

      def runtime_shape(type, domain, provider, source_role)
        shape = Array(domain["shapes"] || domain[:shapes]).find do |candidate|
          candidate = Hash(candidate)
          candidate["name"].to_s == type || candidate[:name].to_s == type
        end
        shape ||= Array(domain["shapes"] || domain[:shapes]).first
        shape = Hash(shape || {})
        shape = shape.merge(
          "elements" => domain["elements"] || domain[:elements]
        ) if !shape.key?("elements") && !shape.key?(:elements)
        shape = shape.merge(
          "keys" => domain["keys"] || domain[:keys]
        ) if !shape.key?("keys") && !shape.key?(:keys)
        shape = shape.merge(
          "values" => domain["values"] || domain[:values]
        ) if !shape.key?("values") && !shape.key?(:values)
        wire_shape(shape, provider, source_role)
      end

      def wire_shape(shape, provider, source_role)
        shape = Hash(shape || {})
        kind = (shape["kind"] || shape[:kind]).to_s
        case kind
        when "array", "set"
          values = child_value_set(
            shape["elements"] || shape[:elements],
            provider,
            source_role
          )
          values && { "sequence" => { "elements" => values } }
        when "hash"
          keys = Array(shape["keys"] || shape[:keys])
          values = Array(shape["values"] || shape[:values])
          entries = keys.product(values).map do |key, child|
            key_value = runtime_value_from_shape(key, provider, source_role)
            child_value = runtime_value_from_shape(child, provider, source_role)
            next unless key_value && child_value

            {
              "key" => key_value,
              "value" => child_value,
              "count" => 1,
            }
          end.compact
          entries.any? ? { "mapping" => { "entries" => entries } } : nil
        when "record"
          members = Hash(shape["members"] || shape[:members]).sort.map do |name, child|
            values = child_value_set([child], provider, source_role)
            { "name" => name.to_s, "values" => values } if values
          end.compact
          { "record" => { "members" => members } }
        when "tuple"
          elements = Array(shape["elements"] || shape[:elements]).filter_map do |child|
            child_value_set([child], provider, source_role)
          end
          { "tuple" => { "elements" => elements } }
        end
      end

      def child_value_set(values, provider, source_role)
        alternatives = Array(values).filter_map do |value|
          runtime_value = runtime_value_from_shape(value, provider, source_role)
          next unless runtime_value

          {
            "value" => runtime_value,
            "count" => 1,
          }
        end
        { "alternatives" => alternatives.uniq } if alternatives.any?
      end

      def runtime_value_from_shape(value, provider, source_role)
        return simple_runtime_value(value, provider, source_role) unless value.is_a?(Hash)

        shape = Hash(value)
        kind = (shape["kind"] || shape[:kind]).to_s
        name = (shape["name"] || shape[:name]).to_s
        type =
          if !name.empty?
            name
          else
            {
              "array" => "Array",
              "set" => "Set",
              "hash" => "Hash",
              "tuple" => "Array",
            }[kind]
          end
        return if type.to_s.empty?

        runtime_value = simple_runtime_value(type, provider, source_role)
        nested = wire_shape(shape, provider, source_role)
        runtime_value.merge!(nested) if nested
        runtime_value
      end

      def simple_runtime_value(type, provider, source_role)
        {
          "type_symbol" => provider.runtime_evidence_type_symbol(type),
          "source_role" => normalize_source_role(source_role),
        }
      end

      def target(row)
        target = row.fetch("target")
        {
          "symbol" => target.fetch("symbol"),
          "source_role" => normalize_source_role(target.fetch("source_role")),
          "package_manager" => target.fetch("package_manager"),
          "package_name" => target.fetch("package_name"),
          "package_version" => target.fetch("package_version"),
        }
      end

      def normalize_source_role(role)
        value = role.to_s.upcase
        {
          "NONPRODUCTION" => "NON_PRODUCTION",
          "STDLIB" => "STANDARD_LIBRARY",
          "UNKNOWN" => "UNKNOWN_SOURCE",
        }.fetch(value, value)
          .then { |normalized|
            %w[
              PRODUCTION NON_PRODUCTION STANDARD_LIBRARY DEPENDENCY RUNTIME UNKNOWN_SOURCE
            ].include?(normalized) ? normalized : "UNKNOWN_SOURCE"
          }
      end

    end
  end
end
