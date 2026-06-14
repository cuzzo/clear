# typed: false
# frozen_string_literal: true

module AutoType
  module Providers
    class Registry
      def initialize
        @provider_classes = {}
      end

      def register(provider_class)
        provider = provider_class.new
        @provider_classes[provider.language] = provider_class
      end

      def provider_for(language, dry_run: false)
        key = language.to_s
        key = "ruby" if key.empty?
        klass = @provider_classes.fetch(key, NullProvider)
        build_provider(klass, dry_run: dry_run)
      end

      def languages
        @provider_classes.keys.sort
      end

      private

      def build_provider(klass, dry_run:)
        klass.new(dry_run: dry_run)
      rescue ArgumentError
        klass.new
      end
    end

    def self.registry
      @registry ||= Registry.new
    end

    def self.register(provider_class)
      registry.register(provider_class)
    end

    def self.provider_for(language, dry_run: false)
      registry.provider_for(language, dry_run: dry_run)
    end
  end
end
