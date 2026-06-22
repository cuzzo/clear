# frozen_string_literal: true

require "json"
require_relative "command"

module Decomplex
  module Native
    module SequenceMine
      module_function

      def scan(files, jobs: nil)
        paths = Array(files).map(&:to_s)
        language = Command.language_for(paths.first)
        JSON.parse(Command.run("sequence-mine", "--language", language, *Command.jobs_args(jobs), *paths))
      end

    end
  end
end
