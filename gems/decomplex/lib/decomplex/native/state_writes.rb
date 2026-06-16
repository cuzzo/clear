# frozen_string_literal: true

require "json"
require "open3"
require_relative "../co_update"

module Decomplex
  module Native
    # Bridge from the Ruby detector layer to the native Decomplex fact extractor.
    # The native binary emits syntax facts only; Ruby still owns detector scoring
    # and canonical output for the migration proof.
    module StateWrites
      module_function

      def extract(files)
        paths = Array(files).map(&:to_s)
        validate_ruby_files!(paths)
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

      def binary_path
        env = ENV["DECOMPLEX_RUST_BIN"]
        return env if env && !env.empty?

        crate_root = File.expand_path("../../../rust", __dir__)
        exe = Gem.win_platform? ? "decomplex-rust.exe" : "decomplex-rust"
        File.join(crate_root, "target", "release", exe)
      end

      def crate_root
        File.expand_path("../../../rust", __dir__)
      end

      private_class_method def self.validate_ruby_files!(paths)
        bad = paths.reject { |path| File.extname(path) == ".rb" }
        return if bad.empty?

        raise ArgumentError, "--engine=rust currently supports Ruby files only: #{bad.join(', ')}"
      end

      private_class_method def self.run_native(paths)
        command =
          if fresh_binary?(binary_path)
            [binary_path, "state-writes", "--language", "ruby", *paths]
          else
            ["cargo", "run", "--quiet", "--release", "--manifest-path",
             File.join(crate_root, "Cargo.toml"), "--",
             "state-writes", "--language", "ruby", *paths]
          end
        stdout, stderr, status = Open3.capture3(*command)
        return stdout if status.success?

        raise "decomplex rust state-writes failed: #{stderr.empty? ? stdout : stderr}"
      rescue Errno::ENOENT => e
        raise "decomplex rust state-writes requires cargo or DECOMPLEX_RUST_BIN: #{e.message}"
      end

      private_class_method def self.fresh_binary?(path)
        return false unless File.executable?(path)
        return true if ENV["DECOMPLEX_RUST_BIN"] && !ENV["DECOMPLEX_RUST_BIN"].empty?

        binary_mtime = File.mtime(path)
        rust_sources.all? { |source| File.mtime(source) <= binary_mtime }
      end

      private_class_method def self.rust_sources
        Dir[File.join(crate_root, "Cargo.toml"), File.join(crate_root, "src", "**", "*.rs")]
      end
    end
  end
end
