# frozen_string_literal: true

require "json"
require_relative "command"

module Decomplex
  module Native
    module OversizedPredicate
      module_function

      def scan(files, jobs: nil)
        paths = Array(files).map(&:to_s)
        language = language_for(paths.first)
        JSON.parse(Command.run("oversized-predicate", "--language", language, *Command.jobs_args(jobs), *paths))
      end
      private_class_method def self.language_for(path)
        case File.extname(path)
        when ".rb" then "ruby"
        when ".py" then "python"
        when ".js" then "javascript"
        when ".ts", ".tsx" then "typescript"
        when ".go" then "go"
        when ".rs" then "rust"
        when ".zig" then "zig"
        when ".lua" then "lua"
        when ".c" then "c"
        when ".cpp", ".cc", ".cxx" then "cpp"
        when ".cs" then "csharp"
        else "ruby"
        end
      end

    end
  end
end
