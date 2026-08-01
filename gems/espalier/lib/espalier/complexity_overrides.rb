# frozen_string_literal: true

require "yaml"

module Espalier
  # Targeted manual-override registry (see config/complexity_overrides.yml).
  #
  # An override is consulted ONLY for a function whose derived bound is
  # incomplete, and returns a complexity only when an explicit entry exists.
  # It is the escape hatch for the ~0.4-2% of functions whose true bound is an
  # algorithmic guarantee structural analysis provably cannot derive.
  module ComplexityOverrides
    DEFAULT_PATH = File.expand_path("../../config/complexity_overrides.yml", __dir__)

    class << self
      def table(path = DEFAULT_PATH)
        @tables ||= {}
        @tables[path] ||= load_table(path)
      end

      # Returns the override entry for (language, owner, name), or nil.
      # Entry: { "time" => ..., "space" => ..., "note" => ... }.
      def lookup(language, owner, name, path: DEFAULT_PATH)
        return nil unless language && name

        lang = table(path)[language.to_s]
        return nil unless lang

        lang["#{owner}.#{name}"] || lang[name.to_s]
      end

      private

      def load_table(path)
        return {} unless File.exist?(path)

        YAML.safe_load(File.read(path)) || {}
      end
    end
  end
end
