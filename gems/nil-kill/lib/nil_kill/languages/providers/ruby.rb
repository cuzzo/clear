# typed: false
# frozen_string_literal: true

require_relative "ruby/sorbet"
require_relative "ruby/runtime_value_evidence"

module NilKill
  module Languages
    module Providers
      class Ruby < Provider
        def language
          "ruby"
        end

        def extensions
          [".rb"]
        end

        def annotation_systems
          %w[sorbet]
        end

        def type_systems
          sorbet.type_systems
        end

        def runtime_tracing?
          true
        end

        def type_next_annotation_advice?
          true
        end

        def runtime_trace_events
          %w[
            method_call
            method_return
            method_raise
            param_observed
            field_observed
            collection_observed
            hash_shape_observed
            call_edge
            runtime_call
            coverage
          ]
        end

        def runtime_capabilities
          super.merge(
            "method_calls" => true,
            "params" => true,
            "returns" => true,
            "exceptions" => true,
            "fields" => true,
            "collections" => true,
            "hash_shapes" => true,
            "call_edges" => true,
            "line_coverage" => true,
            "runtime_scip_calls" => true
          )
        end

        def notes
          [
            "runtime collection uses the existing nil-kill collect command and Ruby source instrumentation",
            "FactMine overlays runtime values on its normalized CFG/DFG and emits inferred SCIP",
          ]
        end

        def runtime_scip_environment(root:)
          claims = {
            "runtime.language" => "ruby",
            "runtime.version" => RUBY_VERSION,
            "runtime.engine" => RUBY_ENGINE,
            "runtime.engine_version" => RUBY_ENGINE_VERSION,
          }
          lockfile = File.join(root, "Gemfile.lock")
          if File.file?(lockfile)
            claims["runtime.lockfile.Gemfile.lock.sha256"] =
              "sha256:#{Digest::SHA256.file(lockfile).hexdigest}"
          end
          claims
        end

        def runtime_scip_event_eligible?(event:, root:)
          package = event.dig("callee", "package").to_s
          return false if %w[minitest mocha rspec-mocks rr].include?(package)

          callee_path = event.dig("callee", "path").to_s
          return true if callee_path.empty?

          absolute = File.expand_path(callee_path, root)
          root = File.expand_path(root)
          return true unless absolute.start_with?("#{root}#{File::SEPARATOR}")

          relative = absolute.delete_prefix("#{root}#{File::SEPARATOR}")
          components = Pathname.new(relative).each_filename.to_a
          basename = components.last.to_s
          !components.any? { |component| %w[test tests spec specs].include?(component) } &&
            !basename.match?(/(?:_test|_spec)\.rb\z/)
        end

        def runtime_value_observations(runtime_dir:, root:)
          RuntimeValueEvidence.observations(runtime_dir: runtime_dir, root: root)
        end

        def runtime_scip_call_evidence(event:, root:)
          RuntimeValueEvidence.call(event: event, root: root)
        end

        def return_type_index(root:)
          sorbet.return_type_index(root: root)
        end

        def field_type_index(root:)
          sorbet.field_type_index(root: root)
        end

        def static_diff_findings(root:, added_lines:, context_paths:, finding_class:)
          NilKill::RubyStaticDiffAudit.new(
            root: root,
            added_lines: added_lines,
            context_paths: context_paths,
            finding_class: finding_class
          ).findings
        end

        def sorbet
          @sorbet ||= Sorbet.new
        end
      end
    end
  end
end

NilKill::Languages.register(NilKill::Languages::Providers::Ruby.new)
