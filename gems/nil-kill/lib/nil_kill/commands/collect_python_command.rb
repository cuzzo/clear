# typed: false
# frozen_string_literal: true

module NilKill
  module Commands
    class CollectPythonCommand
      def initialize(argv)
        @argv = argv.dup
      end

      def run
        Commands::CollectRuntimeCommand.new(["--language", "python", *@argv]).run
      end
    end
  end
end
