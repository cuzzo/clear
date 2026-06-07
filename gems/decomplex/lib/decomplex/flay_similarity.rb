# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # Optional Flay adapter for Type-2 / Type-3 clone pressure.
  #
  # Decomplex does not reimplement clone detection. Flay owns the raw
  # structural-similarity metric; this adapter only converts Flay
  # clusters into decomplex's published finding contract so sibling
  # tools can correlate clone pressure with their own signals.
  class FlaySimilarity
    DEFAULT_MASS = 32
    DEFAULT_FUZZY = 1

    MethodSpan = Struct.new(:name, :first_line, :last_line, keyword_init: true)

    def self.scan(files, mass: DEFAULT_MASS, fuzzy: DEFAULT_FUZZY)
      new(files, mass: mass, fuzzy: fuzzy).scan
    end

    def initialize(files, mass:, fuzzy:)
      @files = files
      @mass = mass
      @fuzzy = fuzzy
      @method_spans = {}
      @source_lines = {}
    end

    def scan
      flay = build_flay
      return [] unless flay

      flay.process(*@files)
      flay.analyze.filter_map { |item| finding_for(item) }
    rescue StandardError
      []
    end

    private

    def build_flay
      require "flay"
      opts = Flay.default_options.merge(mass: @mass, fuzzy: @fuzzy)
      Flay.new(opts)
    rescue LoadError
      nil
    end

    def finding_for(item)
      locs = item.locations
      return nil if locs.size < 2
      return nil if typed_struct_schema_cluster?(locs)

      type = clone_type(item)
      return nil unless type

      sites = locs.map { |loc| site_for(loc) }
      {
        at: sites.first,
        sites: sites,
        spans: spans_for(item),
        clone_type: type,
        node: item.name.to_s,
        mass: item.mass,
        locations: locs.map { |loc| "#{loc.file}:#{loc.line}" }
      }
    end

    # Flay's exact matches are Type-1 clone pressure; keep this detector
    # focused on the Type-2/Type-3 question. Similar structural hashes
    # with renamed identifiers are Type-2-ish; fuzzy sub-node matches
    # are Type-3-ish.
    def clone_type(item)
      return :type3 if item.locations.any?(&:fuzzy?)
      return :type2 unless item.identical?

      nil
    end

    def site_for(loc)
      span = method_span_for(loc.file, loc.line)
      "#{loc.file}:#{span.name}:#{loc.line}"
    end

    def spans_for(item)
      item.locations.each_with_object({}) do |loc, out|
        span = method_span_for(loc.file, loc.line)
        out["#{loc.file}:#{span.name}:#{loc.line}"] =
          if item.name == :defn
            [span.first_line, 0, span.last_line, 1]
          else
            [loc.line, 0, loc.line, 1]
          end
      end
    end

    def typed_struct_schema_cluster?(locs)
      locs.all? { |loc| typed_struct_schema_line?(loc.file, loc.line) }
    end

    def typed_struct_schema_line?(file, line)
      source_line(file, line).match?(/\A\s*(?:const|prop)\s+:[A-Za-z_]\w*\b/)
    end

    def source_line(file, line)
      (@source_lines[file] ||= File.readlines(file))[line - 1].to_s
    rescue StandardError
      ""
    end

    def method_span_for(file, line)
      spans = (@method_spans[file] ||= collect_method_spans(file))
      spans.find { |s| s.first_line <= line && line <= s.last_line } ||
        MethodSpan.new(name: "(top-level)", first_line: line, last_line: line)
    end

    def collect_method_spans(file)
      root, = Ast.parse(file)
      spans = []
      collect_defs(root, spans)
      spans.sort_by { |s| [s.first_line, -s.last_line] }
    rescue StandardError
      []
    end

    def collect_defs(node, spans)
      return unless Ast.node?(node)

      case node.type
      when :DEFN
        spans << MethodSpan.new(name: node.children[0].to_s,
                                first_line: node.first_lineno,
                                last_line: node.last_lineno)
      when :DEFS
        spans << MethodSpan.new(name: node.children[1].to_s,
                                first_line: node.first_lineno,
                                last_line: node.last_lineno)
      end
      node.children.each { |child| collect_defs(child, spans) }
    end
  end
end
