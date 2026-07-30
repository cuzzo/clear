# typed: false
# frozen_string_literal: true

require_relative "protocol/runtime_evidence_pb"
require_relative "value_encoding"

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
        # Compact, not pretty: this is a gzipped machine artifact that only
        # FactMine reads. Indenting it inflated the canonical document by an
        # order of magnitude, and every stage downstream paid to write, read and
        # parse the whitespace.
        JSON.generate(validate_evidence!(value)) + "\n"
      end

      def canonical_message(message_class, value, label, emit_defaults: true)
        message = message_class.decode_json(
          JSON.generate(value),
          ignore_unknown_fields: false
        )
        JSON.parse(
          message_class.encode_json(
            message,
            preserve_proto_fieldnames: true,
            emit_defaults: emit_defaults
          )
        )
      rescue Google::Protobuf::ParseError, Google::Protobuf::TypeError, JSON::ParserError => e
        raise ArgumentError, "invalid #{label}: #{e.message}"
      end

      # Encoding lives in ValueEncoding, which loads without the protobuf
      # runtime. These remain callable here because that is how every existing
      # caller reaches them.
      def value_set(domain, count:, provider:, source_role: "UNKNOWN_SOURCE")
        ValueEncoding.value_set(
          domain, count: count, provider: provider, source_role: source_role
        )
      end

      def target(row)
        ValueEncoding.target(row)
      end

      def normalize_source_role(role)
        ValueEncoding.normalize_source_role(role)
      end
    end
  end
end
