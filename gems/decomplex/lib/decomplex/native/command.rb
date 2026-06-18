# frozen_string_literal: true

require "open3"

module Decomplex
  module Native
    # Shared launcher for the native Decomplex migration slices.
    module Command
      module_function

      def run(*args)
        stdout, stderr, status = Open3.capture3(*native_command(args))
        return stdout if status.success?

        raise "decomplex rust #{args.first} failed: #{stderr.empty? ? stdout : stderr}"
      rescue Errno::ENOENT => e
        raise "decomplex rust #{args.first} requires cargo or DECOMPLEX_RUST_BIN: #{e.message}"
      end

      def binary_path
        env = ENV["DECOMPLEX_RUST_BIN"]
        return env if env && !env.empty?

        exe = Gem.win_platform? ? "decomplex-rust.exe" : "decomplex-rust"
        File.join(crate_root, "target", "release", exe)
      end

      def crate_root
        File.expand_path("../../../rust", __dir__)
      end

      def jobs_args(jobs)
        return [] if jobs.nil?

        count = Integer(jobs)
        raise ArgumentError, "jobs must be greater than zero" if count <= 0

        ["--jobs", count.to_s]
      end

      def language_for(path)
        case File.extname(path)
        when ".rb" then "ruby"
        when ".py" then "python"
        when ".js", ".jsx", ".mjs", ".cjs" then "javascript"
        when ".ts", ".tsx" then "typescript"
        when ".java" then "java"
        when ".swift" then "swift"
        when ".kt", ".kts" then "kotlin"
        when ".go" then "go"
        when ".rs" then "rust"
        when ".zig" then "zig"
        when ".lua" then "lua"
        when ".c", ".h" then "c"
        when ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx" then "cpp"
        when ".cs" then "csharp"
        else "ruby"
        end
      end

      private_class_method def self.native_command(args)
        if fresh_binary?(binary_path)
          [binary_path, *args]
        else
          ["cargo", "run", "--quiet", "--release", "--manifest-path",
           File.join(crate_root, "Cargo.toml"), "--", *args]
        end
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
