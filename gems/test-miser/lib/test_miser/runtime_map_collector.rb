# frozen_string_literal: true

require "digest"
require "mutant"
require "mutant/reporter/null"
require "pathname"
require "set"
require "tmpdir"

module TestMiser
  module SourceFingerprint
    module_function

    def call(roots)
      files = roots.flat_map do |root|
        path = Pathname.new(root).expand_path
        path.file? ? [path] : path.glob("**/*.rb")
      end.uniq.sort_by(&:to_s)
      Digest::SHA256.hexdigest(
        files.map { |path| "#{path}\0#{Digest::SHA256.file(path)}" }.join("\0")
      )
    end
  end

  class RuntimeMapCollector
    def initialize(
      includes:, requires:, timeout: 5.0, progress: nil,
      integration: "minitest", integration_arguments: []
    )
      @includes = includes
      @requires = requires
      @timeout = timeout
      @progress = progress || ->(_message) {}
      @integration = integration
      @integration_arguments = integration_arguments
    end

    def call
      env = bootstrap
      tests = env.integration.all_tests.sort_by(&:id)
      raise CollectionError, "#{@integration} integration discovered no tests" if tests.empty?

      roots = @includes.map { |path| Pathname.new(path).expand_path.to_s }
      return trace_rspec_baseline(env, tests, roots) if @integration == "rspec"

      selections = Hash.new { |hash, key| hash[key] = [] }
      @progress.call("Tracing #{tests.length} passing baseline tests once")
      failures = tests.filter_map do |test|
        result = with_scratch_directory do
          env.config.isolation.call(@timeout) do
            calls = Set.new
            trace = TracePoint.new(:call) do |event|
              path = Pathname.new(event.path).expand_path.to_s
              calls.add([path, event.lineno]) if roots.any? { |root| path == root || path.start_with?("#{root}/") }
            end
            test_result = trace.enable { env.integration.call([test]) }
            { "passed" => test_result.passed, "calls" => calls.to_a }
          end
        end
        unless result.valid_value? && result.value.fetch("passed")
          next test.id
        end

        result.value.fetch("calls").each { |key| selections[key] << test.id }
        nil
      end
      unless failures.empty?
        raise CollectionError, "baseline tests failed or timed out: #{failures.join(', ')}"
      end

      {
        "schemaVersion" => "test-miser-runtime-map/v1",
        "sourceFingerprint" => SourceFingerprint.call(@includes),
        "expectedTests" => tests.length,
        "complete" => true,
        "selections" => selections.sort_by { |key, _tests| key }.map do |(path, line), test_ids|
          { "path" => relative_path(path), "line" => line, "tests" => test_ids.sort }
        end
      }
    end

    private

    def trace_rspec_baseline(env, tests, roots)
      @progress.call("Tracing #{tests.length} passing RSpec examples in one baseline suite run")
      index = env.integration.__send__(:all_tests_index)
      ids = index.to_h do |test, example|
        metadata = example.metadata
        [[metadata.fetch(:location), metadata.fetch(:full_description)], test.id]
      end
      selections = Hash.new { |hash, key| hash[key] = [] }
      executed = []
      ::RSpec.configuration.around do |example|
        metadata = example.metadata
        test_id = ids.fetch([metadata.fetch(:location), metadata.fetch(:full_description)])
        calls = Set.new
        trace = TracePoint.new(:call) do |event|
          path = Pathname.new(event.path).expand_path.to_s
          calls.add([path, event.lineno]) if roots.any? { |root| path == root || path.start_with?("#{root}/") }
        end
        trace.enable { example.run }
        executed << test_id
        calls.each { |key| selections[key] << test_id }
      end
      test_result = env.integration.call(tests)
      raise CollectionError, "RSpec baseline suite failed" unless test_result.passed
      raise CollectionError, "RSpec baseline suite executed no examples" if executed.empty?

      {
        "schemaVersion" => "test-miser-runtime-map/v1",
        "sourceFingerprint" => SourceFingerprint.call(@includes),
        "expectedTests" => executed.uniq.length,
        "testIds" => executed.uniq.sort,
        "complete" => true,
        "selections" => selections.sort_by(&:first).map do |(path, line), test_ids|
          { "path" => relative_path(path), "line" => line, "tests" => test_ids.uniq.sort }
        end
      }
    end

    def with_scratch_directory
      previous = ENV["TMPDIR"]
      Dir.mktmpdir("test-miser-map") do |directory|
        ENV["TMPDIR"] = directory
        yield
      ensure
        previous ? ENV["TMPDIR"] = previous : ENV.delete("TMPDIR")
      end
    end

    def bootstrap
      config = ::Mutant::Config::DEFAULT.with(
        includes: @includes,
        integration: ::Mutant::Integration::Config::DEFAULT.with(
          name: @integration, arguments: @integration_arguments
        ),
        mutation: ::Mutant::Mutation::Config::DEFAULT.with(timeout: @timeout),
        reporter: ::Mutant::Reporter::Null.new,
        requires: @requires,
        usage: ::Mutant::Usage::Opensource.new
      )
      ::Mutant::Bootstrap.call_test(::Mutant::Env.empty(::Mutant::WORLD, config)).from_right do |error|
        raise CollectionError, error
      end
    rescue LoadError => error
      raise CollectionError, error.message
    end

    def relative_path(path)
      Pathname.new(path).expand_path.relative_path_from(Pathname.pwd.expand_path).to_s
    rescue ArgumentError
      path.to_s
    end
  end
end
