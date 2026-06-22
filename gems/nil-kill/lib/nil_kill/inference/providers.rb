# typed: false
# frozen_string_literal: true

require_relative "static_fact_provider"
require_relative "providers/ruby"
require_relative "providers/python"

module NilKill
  module Inference
    module Providers
      module_function

      def index(store:, static:, root:)
        StaticFactProvider.new(nil, copy_bundle: true, index_methods: false).index(store: store, static: static, root: root)
        languages = Array(static["methods"]).map { |method| method["language"].to_s }.reject(&:empty?).uniq
        languages = Array(static["files"]).map { |file| file["language"].to_s }.reject(&:empty?).uniq if languages.empty?
        languages = ["ruby"] if languages.empty?

        languages.sort.each do |language|
          provider_for(language).index(store: store, static: static, root: root)
        end
      end

      def provider_for(language)
        case language.to_s
        when "ruby" then Ruby.new("ruby", copy_bundle: false)
        when "python" then Python.new("python", copy_bundle: false)
        else StaticFactProvider.new(language, copy_bundle: false)
        end
      end
    end
  end
end
