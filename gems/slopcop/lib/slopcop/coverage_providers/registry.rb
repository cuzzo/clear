# frozen_string_literal: true

module SlopCop
  module CoverageProviders
    Capability = Struct.new(:language, :line_coverage, :branch_coverage,
                            :native_branch_coverage, :notes,
                            keyword_init: true)

    module_function

    def register(provider)
      format_providers << provider
    end

    def register_language(provider)
      language_providers << provider
    end

    def format_providers
      @format_providers ||= []
    end

    def language_providers
      @language_providers ||= []
    end

    def load(path, root:)
      resolved, provider = resolve(path, root: root)
      return SlopCop::CoverageData.empty_dataset(path) unless resolved && provider

      provider.load(resolved, root: root)
    rescue JSON::ParserError, REXML::ParseException, Errno::ENOENT
      SlopCop::CoverageData.empty_dataset(path)
    end

    def resolve(path, root:)
      return [nil, nil] if path.nil? || path.to_s.empty?

      expanded = ::File.expand_path(path)
      return resolve_directory(expanded, root: root) if ::File.directory?(expanded)
      return [nil, nil] unless ::File.file?(expanded)

      [expanded, provider_for_file(expanded)]
    end

    def resolve_directory(path, root:)
      format_providers.each do |provider|
        next unless provider.respond_to?(:resolve_directory)

        resolved = provider.resolve_directory(path, root: root)
        return [resolved, provider] if resolved && ::File.file?(resolved)
      end
      [nil, nil]
    end

    def provider_for_file(path)
      format_providers.find do |provider|
        provider.respond_to?(:handles_file?) && provider.handles_file?(path)
      end
    end

    def capability_for(language)
      provider = language_provider_for(language)
      provider&.capability || Capability.new(
        language: language.to_s,
        line_coverage: false,
        branch_coverage: false,
        native_branch_coverage: false,
        notes: "no coverage provider registered"
      )
    end

    def language_provider_for(language)
      language_providers.find { |provider| provider.language.to_s == language.to_s }
    end

    def path_candidates(file, root:, source_roots:, summary: {})
      language_providers.flat_map do |provider|
        next [] unless provider.respond_to?(:path_candidates)

        provider.path_candidates(
          file,
          root: root,
          source_roots: source_roots,
          summary: summary
        )
      end
    end
  end
end
