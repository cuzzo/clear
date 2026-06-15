#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "set"
require "English"

module CIChangeScopes
  MARKDOWN_EXTENSIONS = Set[".md", ".markdown"].freeze

  Scope = Struct.new(:run_gems, :run_src, :run_zig, keyword_init: true) do
    def self.none
      new(run_gems: false, run_src: false, run_zig: false)
    end

    def self.full
      new(run_gems: true, run_src: true, run_zig: true)
    end

    def to_h
      {
        "run_gems" => run_gems,
        "run_src" => run_src,
        "run_zig" => run_zig,
      }
    end
  end

  module_function

  def classify(paths)
    scope = Scope.none
    paths.each do |path|
      apply_path(scope, path.to_s)
    end
    scope.run_src ||= scope.run_zig
    scope
  end

  def apply_path(scope, path)
    return if markdown?(path)

    case path
    when %r{\Agems/}
      scope.run_gems = true
    when %r{\Azig/}
      scope.run_zig = true
    when %r{\A(?:src|spec|transpile-tests|examples|benchmarks|tools)/}
      scope.run_src = true
    when "Gemfile", "Gemfile.lock", ".ruby-version", ".rubocop.yml", "sorbet/config", "clear"
      scope.run_gems = true
      scope.run_src = true
    when %r{\Asorbet/}
      scope.run_gems = true
      scope.run_src = true
    when %r{\A\.github/workflows/}
      scope.run_gems = true
      scope.run_src = true
      scope.run_zig = true
    else
      scope.run_gems = true
      scope.run_src = true
      scope.run_zig = true
    end
  end

  def markdown?(path)
    MARKDOWN_EXTENSIONS.include?(File.extname(path).downcase)
  end

  def changed_paths(base:, head: "HEAD")
    command = ["git", "diff", "--name-only", "--diff-filter=ACMRT", "#{base}...#{head}"]
    output = IO.popen(command, err: [:child, :out], &:read)
    raise "failed to run #{command.join(" ")}" unless $CHILD_STATUS&.success?

    output.lines.map(&:strip).reject(&:empty?)
  end

  def write_github_outputs(scope, path)
    File.open(path, "a") do |file|
      scope.to_h.each do |key, value|
        file.puts("#{key}=#{value ? "true" : "false"}")
      end
    end
  end

  def print_summary(paths, scope)
    warn "Changed files considered for CI scope:"
    paths.each { |path| warn "  #{path}" }
    warn "CI scopes: #{scope.to_h.map { |key, value| "#{key}=#{value}" }.join(", ")}"
  end
end

if $PROGRAM_NAME == __FILE__
  options = { head: "HEAD", github_output: ENV["GITHUB_OUTPUT"] }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby tools/ci_change_scopes.rb --base REF [--head REF] [--full]"
    opts.on("--base REF", "Base ref for git diff") { |value| options[:base] = value }
    opts.on("--head REF", "Head ref for git diff (default: HEAD)") { |value| options[:head] = value }
    opts.on("--full", "Force every scope on") { options[:full] = true }
    opts.on("--github-output PATH", "Write GitHub Actions outputs") { |value| options[:github_output] = value }
  end
  parser.parse!(ARGV)

  if options[:full]
    paths = []
    scope = CIChangeScopes::Scope.full
  else
    abort parser.to_s unless options[:base]

    paths = CIChangeScopes.changed_paths(base: options.fetch(:base), head: options.fetch(:head))
    scope = CIChangeScopes.classify(paths)
  end

  CIChangeScopes.print_summary(paths, scope)
  CIChangeScopes.write_github_outputs(scope, options[:github_output]) if options[:github_output].to_s != ""
end
