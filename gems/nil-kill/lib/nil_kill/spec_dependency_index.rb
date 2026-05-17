# typed: false
# frozen_string_literal: true

module NilKill
  # Maps src files <-> spec files via `require_relative` graph traversal,
  # so the verified loop only runs specs that transitively load the files
  # an action touches. Cuts per-verify wall time from ~30s (full `prspec
  # spec/`) to a few seconds for most action batches.
  #
  # Resolves `require_relative "path"` literally against the requiring
  # file's directory. Ignores plain `require "..."` (stdlib + gems) and
  # dynamic requires. This is sufficient for codebases that use
  # `require_relative` for all project-internal links, which is the
  # convention here (184 require_relative vs 85 bare-require in src/).
  class SpecDependencyIndex
    class << self
      def instance
        @instance ||= build
      end

      def reset!
        @instance = nil
      end

      def build
        index = new
        index.scan!
        index
      end
    end

    def initialize
      @requires_by_file = {}
      @required_by = Hash.new { |h, k| h[k] = Set.new }
    end

    def scan!
      NilKill.usage_scan_files.each do |path|
        @requires_by_file[path] = extract_requires(path)
      end
      @requires_by_file.each do |source, targets|
        targets.each { |target| @required_by[target] << source }
      end
      self
    end

    # Given a list of paths (relative or absolute), return all spec files
    # (absolute paths) whose require_relative chain transitively reaches
    # any of the input paths. The input paths themselves are seeded into
    # the visited set so a spec that directly requires `src/X.rb` is
    # included when X is the input.
    def specs_depending_on(paths)
      visited = Set.new
      queue = []
      Array(paths).each do |p|
        abs = File.expand_path(p, ROOT)
        next if visited.include?(abs)
        visited << abs
        queue << abs
      end
      until queue.empty?
        current = queue.shift
        @required_by[current].each do |dependent|
          next if visited.include?(dependent)
          visited << dependent
          queue << dependent
        end
      end
      visited.select { |p| spec_file?(p) }.sort
    end

    private

    def spec_file?(path)
      path.end_with?("_spec.rb") &&
        (path.include?("#{File::SEPARATOR}spec#{File::SEPARATOR}") ||
         path.end_with?("#{File::SEPARATOR}spec.rb"))
    end

    def extract_requires(path)
      parsed = Prism.parse_file(path)
      return [] unless parsed.success?
      targets = []
      walk(parsed.value, File.dirname(path), targets)
      targets
    end

    def walk(node, source_dir, out)
      return unless node
      if node.is_a?(Prism::CallNode) && node.name == :require_relative
        arg = node.arguments&.arguments&.first
        if arg.is_a?(Prism::StringNode)
          raw = arg.unescaped.to_s
          unless raw.empty?
            resolved = File.expand_path(raw, source_dir)
            resolved += ".rb" unless resolved.end_with?(".rb")
            out << resolved if File.file?(resolved)
          end
        end
      end
      return unless node.respond_to?(:child_nodes)
      node.child_nodes.compact.each { |child| walk(child, source_dir, out) }
    end
  end
end
