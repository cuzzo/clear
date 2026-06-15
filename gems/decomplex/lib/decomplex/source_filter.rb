# frozen_string_literal: true

require_relative "syntax"

module Decomplex
  # Shared source discovery/exclusion rules for Tree-sitter consumers.
  # Generated build/cache trees are filtered before parsing so downstream
  # reports do not spend time on noise such as Zig cache output.
  module SourceFilter
    DEFAULT_EXCLUDE_PATTERNS = %w[
      **/.clear-cache/**
      **/.clear-transpile-cache/**
      **/.global-zig-cache/**
      **/.zig-cache/**
      **/zig-cache/**
      **/zig-out/**
      **/node_modules/**
      **/all-tests.zig
    ].freeze

    module_function

    def collect(targets, parser: Syntax.parser, root: Dir.pwd, exclude: [], include_defaults: true)
      Array(targets).flat_map do |target|
        expand_target(target)
      end.select do |path|
        source_file?(path, parser: parser, root: root, exclude: exclude,
                          include_defaults: include_defaults)
      end.uniq.sort
    end

    def source_file?(path, parser: Syntax.parser, root: Dir.pwd, exclude: [], include_defaults: true)
      expanded = expanded_path(path, root)
      file_path = File.file?(path) ? path : expanded
      return false unless File.file?(file_path)
      return false if File.basename(file_path).start_with?(".")
      return false unless Syntax.supported_exts(parser: parser).include?(File.extname(file_path).downcase)

      !excluded_path?(path, root: root, exclude: exclude, include_defaults: include_defaults)
    end

    def excluded_path?(path, root: Dir.pwd, exclude: [], include_defaults: true)
      patterns = exclude_patterns(exclude, include_defaults: include_defaults)
      return false if patterns.empty?

      raw = path.to_s.tr("\\", "/")
      expanded = expanded_path(path, root).tr("\\", "/")
      rel = relative_path(expanded, root).tr("\\", "/")
      base = File.basename(raw)
      variants = [raw, expanded, rel, base].uniq

      patterns.any? do |pattern|
        pat = pattern.to_s.tr("\\", "/")
        variants.any? do |candidate|
          directory_exclude_match?(candidate, pat) ||
            File.fnmatch?(pat, candidate, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
            File.fnmatch?(pat, candidate, File::FNM_EXTGLOB)
        end
      end
    end

    def exclude_patterns(exclude, include_defaults: true)
      patterns = Array(exclude).compact.flat_map { |value| value.to_s.split(File::PATH_SEPARATOR) }
      patterns = DEFAULT_EXCLUDE_PATTERNS + patterns if include_defaults
      patterns.map(&:strip).reject(&:empty?)
    end

    def directory_exclude_match?(path, pattern)
      return false unless pattern.end_with?("/**")

      prefix = pattern.delete_suffix("/**")
      if prefix.start_with?("**/")
        suffix = prefix.delete_prefix("**/")
        path == suffix || path.start_with?("#{suffix}/") || path.include?("/#{suffix}/")
      else
        path == prefix || path.start_with?("#{prefix}/")
      end
    end

    def expand_target(target)
      path = target.to_s
      if File.directory?(path)
        Dir.glob(File.join(path, "**", "*"))
      elsif glob_pattern?(path)
        Dir.glob(path)
      else
        [path]
      end
    end

    def glob_pattern?(path)
      path.match?(/[*?\[\]{]/)
    end

    def expanded_path(path, root)
      raw = path.to_s
      raw.start_with?("/") ? File.expand_path(raw) : File.expand_path(raw, root)
    end

    def relative_path(path, root)
      root = File.expand_path(root).tr("\\", "/").chomp("/")
      expanded = File.expand_path(path).tr("\\", "/")
      prefix = "#{root}/"
      expanded.start_with?(prefix) ? expanded[prefix.length..] : path.to_s
    end
  end
end
