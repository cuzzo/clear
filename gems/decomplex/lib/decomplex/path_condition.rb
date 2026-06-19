# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # Path-condition normal form. `if x; if y; act` and
  # `act if x && y` reduce to the same guarded action with path
  # condition {x, y}.
  class PathCondition
    Site = Struct.new(:guards, :action, :file, :defn, :line, :span,
                      keyword_init: true)

    def self.scan(files)
      sites = files.flat_map do |file|
        Syntax.parse(file, parser: "tree_sitter").path_condition_sites.map do |site|
          Site.new(
            guards: site.guards,
            action: site.action,
            file: site.file,
            defn: site.function,
            line: site.line,
            span: site.span
          )
        end
      end
      Report.new(sites)
    end

    class Report
      def initialize(sites)
        @sites = sites
        @groups = sites.group_by(&:guards)
      end

      def scattered(min_scatter: 2)
        @groups.filter_map do |gs, sts|
          scatter = sts.map { |s| [s.file, s.defn] }.uniq.size
          next if scatter < min_scatter

          { guards: gs, support: sts.size, scatter: scatter,
            rank: sts.size * scatter,
            sites: sts.map { |s| "#{s.file}:#{s.defn}:#{s.line}" },
            spans: sts.to_h { |s| ["#{s.file}:#{s.defn}:#{s.line}", s.span] } }
        end.sort_by { |h| -h[:rank] }
      end

      def neglected(min_support: 3)
        popular = @groups.select { |_g, s| s.size >= min_support }
                         .map { |g, s| [g, s.size] }
        out = []
        @sites.each do |s|
          popular.each do |gs, sup|
            next unless (gs - s.guards).size == 1 && (s.guards - gs).empty?
            next if s.guards == gs

            out << { pattern: gs, support: sup,
                     missing: (gs - s.guards).first,
                     at: "#{s.file}:#{s.defn}:#{s.line}",
                     spans: { "#{s.file}:#{s.defn}:#{s.line}" => s.span },
                     action: s.action }
          end
        end
        out.uniq.sort_by { |h| -h[:support] }
      end
    end
  end
end
