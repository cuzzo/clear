# frozen_string_literal: true

require "json"
require_relative "command"

module Decomplex
  module Native
    module ReportFacts
      module_function

      def collect(files, jobs: nil)
        paths = Array(files).map(&:to_s)
        JSON.parse(Command.run("facts", *Command.jobs_args(jobs), *paths))
      end
    end
  end
end
