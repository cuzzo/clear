# frozen_string_literal: true

require "json"
require "open3"
require "shellwords"

module Boobytrap
  # Optional method/unit history provider backed by the Rust Lineage
  # crate. Boobytrap intentionally does not depend on a Ruby sqlite3
  # binding; the Lineage CLI owns SQLite access and emits normalized
  # JSON.
  module LineageRisk
    Unit = Struct.new(:id, :name, :kind, :file, :total_events, :changes,
                      :moves, :fixes, :risk_score, keyword_init: true)

    module_function

    def load(path, repo:, only: [], top: 200, command: nil, current_only: false)
      return empty unless path && !path.to_s.empty?
      return empty unless File.file?(path)

      last_err = nil
      summary_commands(path, repo: repo, only: only, top: top, command: command).each do |cmd|
        out, err, status = Open3.capture3(*cmd)
        if status.success?
          rows = JSON.parse(out)
          units = rows.map { |row| unit_from_json(row) }
          units.select! { |unit| current_file?(repo, unit.file) } if current_only
          index = units.each_with_object({}) do |unit, out|
            out[[unit.file, unit.name]] ||= unit
          end
          return {
            status: :ok,
            units: units,
            index: index,
            label: File.basename(path.to_s)
          }
        end
        last_err = err.strip
      end

      warn "boobytrap: lineage unavailable: #{last_err}" if ENV["BOOBYTRAP_DEBUG"]
      empty
    rescue JSON::ParserError, SystemCallError, StandardError => e
      warn "boobytrap: lineage unavailable: #{e.message}" if ENV["BOOBYTRAP_DEBUG"]
      empty
    end

    def empty
      { status: :absent, units: [], index: {}, label: nil }
    end

    def unit_from_json(row)
      Unit.new(
        id: row.fetch("id", ""),
        name: row.fetch("name", ""),
        kind: row.fetch("kind", ""),
        file: row.fetch("current_path", row.fetch("original_path", "")),
        total_events: row.fetch("total_events", 0).to_i,
        changes: row.fetch("changes", 0).to_i,
        moves: row.fetch("moves", 0).to_i,
        fixes: row.fetch("fixes", 0).to_i,
        risk_score: row.fetch("risk_score", 0).to_f
      )
    end

    def summary_commands(path, repo:, only:, top:, command: nil)
      args = summary_args(path, only: only, top: top)
      return [Shellwords.split(command) + args] if command

      commands = []
      binary = default_binary(repo)
      commands << [binary] + args if File.executable?(binary)
      commands << cargo_summary_command(repo) + args
      commands
    end

    def summary_args(path, only:, top:)
      ["summary", "--db", path.to_s, "--top", top.to_i.to_s, "--format", "json"] +
        Array(only).flat_map { |prefix| ["--only", prefix.to_s] }
    end

    def cargo_summary_command(repo)
      ["cargo", "run", "--quiet", "--manifest-path", default_manifest(repo), "--"]
    end

    def current_file?(repo, rel)
      return false if rel.to_s.empty?

      File.file?(File.join(repo, rel))
    end

    def default_binary(repo)
      File.join(repo, "gems", "lineage", "target", "release", "lineage")
    end

    def default_manifest(repo)
      File.join(repo, "gems", "lineage", "Cargo.toml")
    end
  end
end
