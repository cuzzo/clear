# frozen_string_literal: true

require "json"
require_relative "command"

module Decomplex
  module Native
    module PathCondition
      module_function

      def scan(files, jobs: nil)
        paths = Array(files).map(&:to_s)
        language = Command.language_for(paths.first)
        payload = JSON.parse(Command.run("path-condition", "--language", language, *Command.jobs_args(jobs), *paths))
        { "neglected" => payload.fetch("neglected", []) }
      end

    end
  end
end
