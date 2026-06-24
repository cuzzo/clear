# typed: false
# frozen_string_literal: true

module NilKill
  module Commands
    class SourceIndexCommand
      def initialize(argv)
        @argv = argv.dup
      end

      def run
        return help if @argv.delete("--help") || @argv.delete("-h")

        engine = option("--engine") || "ruby"
        output = option("--output")
        targets = @argv.reject { |arg| arg.start_with?("--") }
        with_targets(targets) do
          bundle = case engine
          when "ruby"
            ruby_bundle
          when "rust"
            rust_bundle
          else
            abort "source-index: unsupported engine #{engine.inspect}; expected ruby or rust"
          end
          json = canonical_json(bundle)
          output ? File.write(output, json) : puts(json)
        end
      end

      private

      def help
        puts <<~HELP
          Usage: bundle exec tools/nil-kill source-index [--engine ruby|rust] [--output source-index.json] [targets...]

          Emits the normalized static SourceIndex bundle used by nil-kill infer.
        HELP
      end

      def option(name)
        idx = @argv.index(name)
        return @argv.slice!(idx, 2).last if idx

        prefix = "#{name}="
        arg = @argv.find { |candidate| candidate.start_with?(prefix) }
        arg && @argv.delete(arg)&.delete_prefix(prefix)
      end

      def with_targets(targets)
        return yield if targets.empty?

        old = ENV["NIL_KILL_TARGETS"]
        ENV["NIL_KILL_TARGETS"] = targets.join(File::PATH_SEPARATOR)
        yield
      ensure
        old.nil? ? ENV.delete("NIL_KILL_TARGETS") : ENV["NIL_KILL_TARGETS"] = old
      end

      def ruby_bundle
        infer = Infer.new(["--no-sorbet"])
        infer.index_sources
        store_bundle(infer.store)
      end

      def rust_bundle
        bin = native_binary
        unless File.executable?(bin)
          abort "source-index: missing native indexer #{NilKill.rel(bin)}; build with `cargo build --manifest-path gems/nil-kill/rust/Cargo.toml`"
        end

        args = ["source-index", "--root", ROOT]
        NilKill.target_dirs.each { |dir| args.concat(["--target-dir", NilKill.rel(dir)]) }
        NilKill.target_exclude_dirs.each { |dir| args.concat(["--exclude-dir", NilKill.rel(dir)]) }
        target_files = NilKill.source_index_target_files
        (NilKill.usage_scan_files - target_files).each { |path| args.concat(["--usage-file", path]) }
        args.concat(target_files)

        out, err, status = Open3.capture3(bin, *args)
        abort "source-index rust failed: #{err}" unless status.success?

        JSON.parse(out)
      end

      def native_binary
        release = File.join(ROOT, "gems", "nil-kill", "rust", "target", "release", "nil-kill-rust")
        return release if File.executable?(release)

        File.join(ROOT, "gems", "nil-kill", "rust", "target", "debug", "nil-kill-rust")
      end

      def store_bundle(store)
        {
          "schema_version" => 1,
          "target_dirs" => NilKill.target_dirs.map { |dir| NilKill.rel(dir) },
          "target_exclude_dirs" => NilKill.target_exclude_dirs.map { |dir| NilKill.rel(dir) },
          "methods" => store.methods.values,
          "facts" => store.facts,
        }
      end

      def canonical_json(value)
        JSON.generate(canonicalize(value)) << "\n"
      end

      def canonicalize(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.each_with_object({}) do |key, out|
            original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
            out[key] = canonicalize(value.fetch(original))
          end
        when Array
          value.map { |entry| canonicalize(entry) }
        when Set
          value.to_a.map { |entry| canonicalize(entry) }.sort_by(&:to_s)
        when Symbol
          value.to_s
        else
          value
        end
      end
    end
  end
end
