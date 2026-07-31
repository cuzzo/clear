# typed: false
# frozen_string_literal: true

require "open3"
require "tempfile"

module NilKill
  module Runtime
    # Stable, language-neutral function identities and semantic fingerprints
    # derived from FactMine's normalized source inventory.
    class FunctionInventory
      attr_reader :root, :functions

      # FactMine derives the identities and fingerprints; the lookups below are
      # what an incremental collect asks of them, per shard.
      def self.build(root:, files:, trace_plan: nil)
        Tempfile.create(["nil-kill-function-inventory", ".json"]) do |file|
          args = [NilKill::FactMineStaticFacts::FACT_MINE_RUST_BINARY,
                  "nil-kill-function-inventory", "--output", file.path, "--root", root.to_s]
          args.concat(["--plan", NilKill::TRACE_PLAN_PATH]) if
            trace_plan && File.file?(NilKill::TRACE_PLAN_PATH)
          Array(files).each { |path| args.concat(["--file", path.to_s]) }
          _out, err, status = Open3.capture3(*args)
          raise "fact-mine nil-kill-function-inventory failed: #{err}" unless status.success?

          new(root: root, functions: JSON.parse(File.read(file.path)))
        end
      end

      def initialize(root:, functions: {})
        @root = File.expand_path(root)
        @functions = functions
      end

      def to_h
        functions.sort.to_h
      end

      def keys_for_coverage(path, lines)
        relative_path = relative(path)
        covered = Array(lines).map(&:to_i).to_set
        functions.values.filter_map do |function|
          next unless function["path"] == relative_path
          first_line, last_line = function.fetch("span", []).values_at(0, 2).map(&:to_i).minmax
          function["key"] if covered.any? { |line| line.between?(first_line, last_line) }
        end
      end

      def key_for_entry(path:, owner:, name:, kind:, line: nil)
        relative_path = relative(path)
        candidates = functions.values.select do |function|
          function["path"] == relative_path &&
            function["owner"] == owner.to_s &&
            function["name"] == name.to_s &&
            function["kind"] == kind.to_s
        end
        return candidates.first&.fetch("key") if candidates.length < 2

        entry_line = line.to_i
        matched = candidates.find { |function| function["line"] == entry_line } ||
          candidates.find do |function|
            first_line, last_line = function.fetch("span").values_at(0, 2).map(&:to_i).minmax
            entry_line.between?(first_line, last_line)
          end
        matched&.fetch("key")
      end

      private

      def relative(path)
        absolute = File.expand_path(path, root)
        Pathname.new(absolute).relative_path_from(Pathname.new(root)).to_s
      rescue ArgumentError
        path.to_s
      end
    end
  end
end
