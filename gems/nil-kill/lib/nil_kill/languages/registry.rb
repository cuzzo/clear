# typed: false
# frozen_string_literal: true

module NilKill
  module Languages
    module Registry
      module_function

      def providers
        @providers ||= {}
      end

      def register(provider)
        names = [provider.language, *provider.aliases].map { |name| normalize(name) }
        names.each { |name| providers[name] = provider }
        provider
      end

      def provider_for(language)
        providers.fetch(normalize(language)) { GenericTreeSitterProvider.new(language) }
      end

      def registered_providers
        providers.values.uniq.sort_by(&:language)
      end

      def capabilities
        registered_providers.map(&:capability)
      end

      def capability_for(language)
        provider_for(language).capability
      end

      def normalize(language)
        language.to_s.tr("-", "_")
      end
    end

    def self.register(provider)
      Registry.register(provider)
    end

    def self.provider_for(language)
      Registry.provider_for(language)
    end

    def self.capabilities
      Registry.capabilities
    end

    def self.capability_for(language)
      Registry.capability_for(language)
    end
  end
end
