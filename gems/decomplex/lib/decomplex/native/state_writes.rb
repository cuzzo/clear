# frozen_string_literal: true

require "json"
require_relative "../co_update"
require_relative "command"

module Decomplex
  module Native
    # Bridge from the Ruby detector layer to the native Decomplex state-write
    # fact extractor. The full co-update detector now runs in native Rust too;
    # this module remains for focused fact debugging.
    module StateWrites
      module_function

      def extract(files)
        paths = Array(files).map(&:to_s)
        payload = run_native(paths)
        JSON.parse(payload).map do |row|
          CoUpdate::Write.new(
            attr: row.fetch("field"),
            recv: row.fetch("receiver"),
            file: row.fetch("file"),
            defn: row.fetch("function"),
            line: row.fetch("line"),
            span: row.fetch("span"),
          )
        end
      end

      private_class_method def self.run_native(paths)
        language = Command.language_for(paths.first)
        Command.run("state-writes", "--language", language, *paths)
      end

    end
  end
end
