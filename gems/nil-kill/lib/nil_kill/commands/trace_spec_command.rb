# typed: false
# frozen_string_literal: true

module NilKill
  module Commands
    class TraceSpecCommand
      def initialize(_argv)
      end

      def run
        puts JSON.pretty_generate(spec)
      end

      def spec
        {
          "schema_version" => 1,
          "format" => "jsonl",
          "required_common_fields" => %w[schema_version event language run_id pid thread_id timestamp_ns path line payload],
          "method_locator" => {
            "preferred" => "method_id",
            "fallback" => { "locator" => %w[owner name kind] },
          },
          "required_minimum_events" => %w[process_start process_end method_call param_observed method_return coverage],
          "optional_events" => %w[method_raise return_observed field_observed collection_observed hash_shape_observed call_edge branch_observed type_assertion_observed nil_guard_observed],
          "runtime_type" => {
            "fields" => %w[name kind nullable language display confidence members],
            "kinds" => %w[primitive class struct interface union array map record function null unknown],
          },
          "language_capabilities" => Languages.capabilities,
        }
      end
    end
  end
end
