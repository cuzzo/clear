# frozen_string_literal: true

require "json"
require_relative "command"

module Decomplex
  module Native
    module OperationalDiscontinuity
      module_function

      def scan(files, jobs: nil)
        paths = Array(files).map(&:to_s)
        validate_ruby_files!(paths)
        JSON.parse(Command.run("operational-discontinuity", "--language", "ruby", *Command.jobs_args(jobs), *paths))
      end

      private_class_method def self.validate_ruby_files!(paths)
        bad = paths.reject { |path| File.extname(path) == ".rb" }
        return if bad.empty?

        raise ArgumentError, "--engine=rust currently supports Ruby files only: #{bad.join(', ')}"
      end
    end
  end
end
