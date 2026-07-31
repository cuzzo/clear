# typed: false
# frozen_string_literal: true

require_relative "../../runtime/environment_claims"
require_relative "ruby/sorbet"
require_relative "ruby/runtime_value_evidence"
require "ripper"
require "open3"
require "tempfile"

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
          NilKill::Runtime::EnvironmentClaims.ruby(root: root)
        end

        def runtime_value_observations(runtime_dir:, root:)
          RuntimeValueEvidence.observations(runtime_dir: runtime_dir, root: root)
        end

        def runtime_scip_call_evidence(event:, root:)
          RuntimeValueEvidence.call(event: event, root: root)
        end

        # The whole file at once, decoded by FactMine. The translation from what
        # a VM saw into what SCIP names is mechanical -- it renames and regroups
        # and infers nothing -- so it belongs with the rest of the join rather
        # than in a Ruby process per shard.
        def runtime_scip_call_evidence_batch(events:, root:)
          return [] if events.empty?

          Tempfile.create(["nil-kill-runtime-calls", ".jsonl"]) do |file|
            events.each { |event| file.puts(JSON.generate(event)) }
            file.flush
            stdout, stderr, status = Open3.capture3(
              NilKill::FactMineStaticFacts::FACT_MINE_RUST_BINARY,
              "nil-kill-decode-calls", "--input", file.path, "--root", root.to_s
            )
            raise "fact-mine nil-kill-decode-calls failed: #{stderr.strip}" unless status.success?

            JSON.parse(stdout)
          end
        end

        def runtime_evidence_type_symbol(type)
          RuntimeValueEvidence.runtime_type_symbol(type)
        end

        def runtime_evidence_singleton_symbol(type)
          RuntimeValueEvidence.runtime_singleton_symbol(type)
        end

        def runtime_evidence_provenance
          NilKill::Runtime::EnvironmentClaims.ruby_provenance
        end

        # Ripper's semantic tree excludes ordinary comments and formatting,
        # so those edits do not trigger an expensive trace. Preserve magic
        # comments because they can alter Ruby execution/allocation semantics.
        # A parse failure falls back to exact bytes: never declare an unknown
        # edit irrelevant.
        def runtime_incremental_fingerprint(path)
          source = File.read(path)
          syntax = Ripper.sexp(source)
          return super unless syntax

          magic_comments = source.lines.first(2).grep(/\A\s*#\s*[A-Za-z_][\w-]*\s*:/)
          Digest::SHA256.hexdigest(
            JSON.generate([magic_comments, runtime_incremental_syntax_without_locations(syntax)])
          )
        rescue StandardError
          super
        end

        def runtime_test_plan(root:, targets:, commands:)
          return unless commands.one?

          command = commands.first
          projects = Array(targets).map do |target|
            absolute = File.expand_path(target, root)
            directory = File.directory?(absolute) ? absolute : File.dirname(absolute)
            %w[lib src app].include?(File.basename(directory)) ? File.dirname(directory) : root
          end.uniq
          minitest = projects.flat_map { |project| Dir.glob(File.join(project, "test/**/*_test.rb")) }
            .select { |path| File.file?(path) }.uniq.sort
          rspec = projects.flat_map { |project| Dir.glob(File.join(project, "spec/**/*_spec.rb")) }
            .select { |path| File.file?(path) }.uniq.sort
          kind =
            if command.any? { |part| File.basename(part.to_s).start_with?("rspec") }
              :rspec
            elsif command.join(" ").match?(/(?:test\/.*_test\.rb|_test\.rb|Dir\[.*test)/)
              :minitest
            end
          return unless kind

          entries = kind == :rspec ? rspec : minitest
          return if entries.empty?

          all_test_ruby = projects.flat_map do |project|
            %w[test spec].flat_map { |name| Dir.glob(File.join(project, "#{name}/**/*.rb")) }
          end.select { |path| File.file?(path) }.uniq.sort
          tests = entries.to_h do |path|
            [relative_runtime_test_path(path, root), runtime_incremental_fingerprint(path)]
          end
          support = (all_test_ruby - entries).to_h do |path|
            [relative_runtime_test_path(path, root), runtime_incremental_fingerprint(path)]
          end
          shards = entries.map do |path|
            relative = relative_runtime_test_path(path, root)
            {
              "id" => "test-#{Digest::SHA256.hexdigest(relative)[0, 16]}",
              "test_path" => relative,
              "command" => runtime_test_command(command, path, kind),
            }
          end
          {
            "mode" => "test_files",
            "tests" => tests,
            "support_files" => support,
            "shards" => shards,
          }
        end

        def runtime_incremental_syntax_without_locations(node)
          return nil if node.is_a?(Array) && node.length == 2 && node.all? { |part| part.is_a?(Integer) }
          return node.map { |child| runtime_incremental_syntax_without_locations(child) } if node.is_a?(Array)

          node
        end

        def runtime_test_command(command, path, kind)
          if kind == :rspec
            executable = command.index { |part| File.basename(part.to_s).start_with?("rspec") }
            return [*command[0..executable], path]
          end

          eval_index = command.index("-e")
          return [*command[0...eval_index], path] if eval_index

          ruby_index = command.index do |part|
            File.basename(part.to_s).match?(/\Aruby(?:\d+(?:\.\d+)*)?\z/)
          end
          return [*command[0..ruby_index], path] if ruby_index

          [RbConfig.ruby, path]
        end

        def relative_runtime_test_path(path, root)
          Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(File.expand_path(root))).to_s
        rescue ArgumentError
          path.to_s
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
