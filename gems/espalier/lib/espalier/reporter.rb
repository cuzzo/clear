# frozen_string_literal: true

require "yaml"

module Espalier
  # Builds a compact architecture-review report from the full Espalier manifest.
  class Reporter
    DEFAULT_LIMIT = 20

    def self.from_yaml_file(path, root: Dir.pwd, limit: DEFAULT_LIMIT)
      new(YAML.load_file(path), root: root, limit: limit)
    end

    def initialize(manifest, root: Dir.pwd, limit: DEFAULT_LIMIT)
      @manifest = manifest || []
      @root = root
      @limit = limit
    end

    def to_markdown
      sections = []
      sections << "# Espalier Architecture Report"
      sections << ""
      sections << "> Architecture-level state, effect, and delegation synthesis."
      sections << "> Findings are review candidates, not verdicts."
      sections << ""
      sections << table_of_contents
      sections << project_prioritization
      sections << run_summary
      sections << state_owner_pressure
      sections << coordinator_mutator_collisions
      sections << conditional_delegation_hubs
      sections << state_lifecycle_pressure
      sections << cross_tool_overlap
      sections.compact.join("\n")
    end

    private

    def table_of_contents
      <<~MD
        ## Table of Contents
        - [Project Prioritization](#project-prioritization)
        - [Run Summary](#run-summary)
        - [State Owner Pressure](#state-owner-pressure)
        - [Coordinator/Mutator Collisions](#coordinatormutator-collisions)
        - [Conditional Delegation Hubs](#conditional-delegation-hubs)
        - [State Lifecycle Pressure](#state-lifecycle-pressure)
        - [Cross-Tool Overlap](#cross-tool-overlap)
      MD
    end

    def project_prioritization
      top_owner = module_scores.first
      top_collision = method_scores.first
      top_lifecycle = state_scores.first

      lines = ["## Project Prioritization"]
      if top_owner
        lines << "- Highest architecture-pressure owner: #{module_ref(top_owner)} " \
                 "(score=#{fmt(top_owner[:score])}, state=#{top_owner[:state_count]}, methods=#{top_owner[:method_count]})."
      end
      if top_collision
        lines << "- Highest coordinator/mutator collision: #{method_ref(top_collision)} " \
                 "(score=#{fmt(top_collision[:score])}, writes=#{top_collision[:writes]}, conditional calls=#{top_collision[:conditional_calls]})."
      end
      if top_lifecycle
        lines << "- Highest state lifecycle pressure: `#{top_lifecycle[:state]}` in #{module_ref(top_lifecycle)} " \
                 "(score=#{fmt(top_lifecycle[:score])}, readers=#{top_lifecycle[:readers]}, writers=#{top_lifecycle[:writers]})."
      end
      lines << "- Start where architecture pressure overlaps Decomplex/Boobytrap/SlopCop/NilKill evidence; those are more likely root-cause work than local cleanup."
      lines << ""
      lines.join("\n")
    end

    def run_summary
      function_count = @manifest.sum { |mod| functions(mod).size }
      state_count = @manifest.sum { |mod| states(mod).size }
      delegation_count = all_methods.sum { |row| row[:always_calls] + row[:conditional_calls] }
      read_count = all_methods.sum { |row| row[:reads] }
      write_count = all_methods.sum { |row| row[:writes] }
      source_bytes = ruby_source_bytes
      manifest_bytes = File.exist?(manifest_path) ? File.size(manifest_path) : nil
      source_words = ruby_source_words
      manifest_words = File.exist?(manifest_path) ? File.read(manifest_path).split(/\s+/).size : nil

      lines = ["## Run Summary"]
      lines << "- Modules/classes indexed: #{@manifest.size}"
      lines << "- Functions indexed: #{function_count}"
      lines << "- State slots indexed: #{state_count}"
      lines << "- Effect reads/writes: #{read_count}/#{write_count}"
      lines << "- Delegation edges: #{delegation_count}"
      if source_bytes && manifest_bytes && source_bytes.positive?
        lines << "- Manifest/source byte ratio: #{fmt(manifest_bytes.to_f / source_bytes * 100)}% " \
                 "(#{manifest_bytes} / #{source_bytes})"
      end
      if source_words && manifest_words && source_words.positive?
        lines << "- Manifest/source word ratio: #{fmt(manifest_words.to_f / source_words * 100)}% " \
                 "(#{manifest_words} / #{source_words})"
      end
      lines << ""
      lines.join("\n")
    end

    def state_owner_pressure
      lines = ["## State Owner Pressure", "_State-heavy owners with broad method/delegation surfaces._", ""]
      lines << "| # | owner | score | flags | state | methods | state touches | delegations | suggested refactor |"
      lines << "|---|-------|-------|-------|-------|---------|---------------|-------------|--------------------|"
      module_scores.first(@limit).each_with_index do |row, idx|
        lines << "| #{idx + 1} | #{module_ref(row)} | #{fmt(row[:score])} | #{owner_flags(row)} | #{row[:state_count]} | " \
                 "#{row[:method_count]} | #{row[:state_touches]} | #{row[:delegations]} | #{owner_refactor(row)} |"
      end
      lines << ""
      lines.join("\n")
    end

    def coordinator_mutator_collisions
      lines = ["## Coordinator/Mutator Collisions", "_Methods that both mutate phase state and coordinate many calls._", ""]
      lines << "| # | method | score | reads | writes | always | conditional | overlap | suggested refactor |"
      lines << "|---|--------|-------|-------|--------|--------|-------------|---------|--------------------|"
      method_scores.first(@limit).each_with_index do |row, idx|
        lines << "| #{idx + 1} | #{method_ref(row)} | #{fmt(row[:score])} | #{row[:reads]} | #{row[:writes]} | " \
                 "#{row[:always_calls]} | #{row[:conditional_calls]} | #{quality_summary(row)} | #{method_refactor(row)} |"
      end
      lines << ""
      lines.join("\n")
    end

    def conditional_delegation_hubs
      lines = ["## Conditional Delegation Hubs", "_Branchy orchestration boundaries, independent of direct state writes._", ""]
      lines << "| # | method | conditional calls | always calls | state touches | suggested refactor |"
      lines << "|---|--------|-------------------|--------------|---------------|--------------------|"
      all_methods
        .select { |row| row[:conditional_calls].positive? }
        .sort_by { |row| [-row[:conditional_calls], -row[:always_calls], -row[:writes], row[:file], row[:name].to_s] }
        .first(@limit)
        .each_with_index do |row, idx|
          lines << "| #{idx + 1} | #{method_ref(row)} | #{row[:conditional_calls]} | #{row[:always_calls]} | " \
                   "#{row[:reads] + row[:writes]} | #{hub_refactor(row)} |"
        end
      lines << ""
      lines.join("\n")
    end

    def state_lifecycle_pressure
      lines = ["## State Lifecycle Pressure", "_State slots with many readers/writers or protocol-shaped behavior._", ""]
      lines << "| # | state | owner | score | readers | writers | type | protocol evidence | suggested refactor |"
      lines << "|---|-------|-------|-------|---------|---------|------|-------------------|--------------------|"
      state_scores.first(@limit).each_with_index do |row, idx|
        lines << "| #{idx + 1} | `#{row[:state]}` | #{module_ref(row)} | #{fmt(row[:score])} | " \
                 "#{row[:readers]} | #{row[:writers]} | #{escape(row[:type] || '-') } | #{escape(protocol_summary(row))} | #{state_refactor(row)} |"
      end
      lines << ""
      lines.join("\n")
    end

    def cross_tool_overlap
      rows = all_methods
        .reject { |row| row[:name].to_s == "initialize" }
        .select { |row| !quality_hash(row).empty? }
      return nil if rows.empty?

      lines = ["## Cross-Tool Overlap", "_Architectural pressure with sibling-tool metadata already attached._", ""]
      lines << "| # | method | architecture score | overlap |"
      lines << "|---|--------|--------------------|---------|"
      rows = rows.map { |row| row.merge(score: method_architecture_score(row)) }
      rows.sort_by { |row| [-row[:score], row[:file], row[:name].to_s] }.first(@limit).each_with_index do |row, idx|
        lines << "| #{idx + 1} | #{method_ref(row)} | #{fmt(row[:score])} | #{quality_summary(row)} |"
      end
      lines << ""
      lines.join("\n")
    end

    def module_scores
      @module_scores ||= @manifest.map do |mod|
        method_rows = functions(mod).map { |fn| method_row(mod, fn) }
        state_count = states(mod).size
        method_count = method_rows.size
        state_touches = method_rows.sum { |row| row[:reads] + row[:writes] }
        delegations = method_rows.sum { |row| row[:always_calls] + row[:conditional_calls] }
        write_methods = method_rows.count { |row| row[:writes].positive? }
        score = state_count * 3.0 + method_count * 0.6 + state_touches * 1.2 + delegations * 0.35 + write_methods
        {
          module: mod[:module],
          file: mod[:file],
          state_count: state_count,
          method_count: method_count,
          state_touches: state_touches,
          delegations: delegations,
          write_methods: write_methods,
          score: score
        }
      end.sort_by { |row| [-row[:score], row[:file].to_s, row[:module].to_s] }
    end

    def method_scores
      @method_scores ||= all_methods
        .select { |row| row[:writes].positive? || row[:conditional_calls] >= 8 || row[:always_calls] >= 12 }
        .reject { |row| row[:name].to_s == "initialize" && (row[:always_calls] + row[:conditional_calls]) < 10 }
        .map do |row|
          row.merge(score: method_architecture_score(row))
        end
        .sort_by { |row| [-row[:score], row[:file].to_s, row[:name].to_s] }
    end

    def state_scores
      @state_scores ||= @manifest.flat_map do |mod|
        state_rows = states(mod).map do |state|
          name = state[:name]
          reader_count = functions(mod).count { |fn| effect_list(fn, :reads).include?(name) }
          writer_count = functions(mod).count { |fn| effect_list(fn, :writes).include?(name) }
          protocol_props = Array(state[:properties]).select { |prop| actionable_protocol_property?(prop) }
          protocol_weight = protocol_props.empty? ? 0 : 8
          score = reader_count * 1.5 + writer_count * 3.0 + protocol_weight
          {
            module: mod[:module],
            file: mod[:file],
            state: name,
            type: state[:type],
            properties: Array(state[:properties]),
            readers: reader_count,
            writers: writer_count,
            score: score
          }
        end
        state_rows
      end.sort_by { |row| [-row[:score], row[:file].to_s, row[:state].to_s] }
    end

    def all_methods
      @all_methods ||= @manifest.flat_map do |mod|
        functions(mod).map { |fn| method_row(mod, fn) }
      end
    end

    def method_row(mod, fn)
      delegations = fn[:DELEGATIONS] || {}
      always = Array(delegations[:always_calls])
      conditional = Array(delegations[:conditionally_calls])
      reads = effect_list(fn, :reads)
      writes = effect_list(fn, :writes)
      {
        module: mod[:module],
        file: mod[:file],
        name: fn[:name],
        line: method_line(mod[:file], fn[:name]),
        reads: reads.size,
        writes: writes.size,
        always_calls: always.size,
        conditional_calls: conditional.size,
        quality: fn[:quality_metrics] || {},
        score: 0
      }
    end

    def functions(mod)
      Array(mod[:functions])
    end

    def states(mod)
      Array(mod[:state])
    end

    def effect_list(fn, key)
      Array((fn[:EFFECTS] || {})[key])
    end

    def module_ref(row)
      "`#{row[:module]}` (#{file_link(row[:file])})"
    end

    def method_ref(row)
      line = row[:line]
      suffix = line ? ":#{line}" : ""
      "`#{row[:module]}##{row[:name]}` (#{file_link(row[:file], line)}#{suffix.empty? ? "" : ""})"
    end

    def file_link(file, line = nil)
      return "`-`" unless file

      target = line ? "../../#{file}#L#{line}" : "../../#{file}"
      "[`#{file}`](#{target})"
    end

    def method_line(file, method_name)
      return nil unless file && method_name

      @method_line_cache ||= {}
      key = [file, method_name]
      return @method_line_cache[key] if @method_line_cache.key?(key)

      path = File.join(@root, file)
      return @method_line_cache[key] = nil unless File.file?(path)

      escaped = Regexp.escape(method_name.to_s.sub(/\Aself\./, ""))
      receiver = method_name.to_s.start_with?("self.") ? /self\./ : /(?:self\.)?/
      regex = /^\s*def\s+#{receiver}#{escaped}(?:\s|\(|$)/
      File.readlines(path).each_with_index do |line, idx|
        return @method_line_cache[key] = idx + 1 if line.match?(regex)
      end
      @method_line_cache[key] = nil
    end

    def quality_summary(row)
      quality = quality_hash(row)
      return "-" if quality.empty?

      quality.map { |key, value| "#{key}=#{value}" }.join(", ")
    end

    def quality_hash(row)
      (row[:quality] || {}).merge(external_overlap_for(row))
    end

    def external_overlap_for(row)
      method_key = [row[:file], row[:name].to_s]
      file_key = row[:file]
      data = {}

      if (decomplex = external_overlap[:decomplex][method_key])
        data[:decomplex] = "#{decomplex[:detectors]} detectors/score #{decomplex[:score]}"
      end
      if (slopcop = external_overlap[:slopcop][method_key])
        data[:slopcop] = "rank #{slopcop[:rank]}"
      end
      if (boobytrap = external_overlap[:boobytrap][file_key])
        data[:boobytrap] = "rank #{boobytrap[:rank]}/hotspot #{boobytrap[:hotspot]}"
      end

      data
    end

    def external_overlap
      @external_overlap ||= {
        decomplex: parse_decomplex_report,
        slopcop: parse_slopcop_report,
        boobytrap: parse_boobytrap_report
      }
    end

    def parse_decomplex_report
      path = File.join(@root, "gems/decomplex/report.md")
      return {} unless File.file?(path)

      File.readlines(path).each_with_object({}) do |line, index|
        next unless line =~ /`(?<file>src\/[^`]+\.rb):\d+`\s+\((?<method>[^)]+)\).*?\*\*(?<detectors>\d+) detectors\*\* \[score (?<score>\d+)/

        index[[Regexp.last_match[:file], Regexp.last_match[:method]]] = {
          detectors: Regexp.last_match[:detectors],
          score: Regexp.last_match[:score]
        }
      end
    end

    def parse_slopcop_report
      path = File.join(@root, "gems/slopcop/report.md")
      return {} unless File.file?(path)

      File.readlines(path).each_with_object({}) do |line, index|
        next unless line =~ /^\|\s*(?<rank>\d+)\s*\|\s*\[`(?<file>src\/[^`]+\.rb):\d+`\][^|]*\|\s*`(?<method>[^`]+)`/

        index[[Regexp.last_match[:file], Regexp.last_match[:method]]] ||= {
          rank: Regexp.last_match[:rank]
        }
      end
    end

    def parse_boobytrap_report
      path = File.join(@root, "gems/boobytrap/report.md")
      return {} unless File.file?(path)

      File.readlines(path).each_with_object({}) do |line, index|
        next unless line =~ /^\|\s*(?<rank>\d+)\s*\|\s*`(?<file>src\/[^`]+\.rb)`\s*\|\s*(?<hotspot>[\d.]+)\s*\|/

        index[Regexp.last_match[:file]] = {
          rank: Regexp.last_match[:rank],
          hotspot: Regexp.last_match[:hotspot]
        }
      end
    end

    def protocol_summary(row)
      props = row[:properties].select { |prop| actionable_protocol_property?(prop) }
      return "-" if props.empty?

      props.join("; ")
    end

    def actionable_protocol_property?(prop)
      return false unless prop.include?("protocol interfaces:")

      methods = prop.split("protocol interfaces:", 2).last.to_s.split(",").map(&:strip)
      structural = %w[[] []= << push pop clear concat delete each each_value each_key keys values dig fetch]
      dynamic = %w[send instance_variable_get instance_variable_set]
      (methods & (structural + dynamic)).any?
    end

    def owner_refactor(row)
      if row[:state_count] >= 20
        "extract phase-state records and split lifecycle ownership"
      elsif row[:delegations] >= 100
        "separate coordinator from mechanism helpers"
      else
        "audit cohesion before local cleanup"
      end
    end

    def owner_flags(row)
      flags = []
      flags << "state-heavy" if row[:state_count] >= 5
      flags << "many-mutators" if row[:write_methods] >= 5
      flags << "broad-delegator" if row[:delegations] >= 100
      flags << "low-cohesion-candidate" if row[:state_count] >= 5 && row[:state_touches] < row[:state_count] * 2
      flags.empty? ? "-" : flags.join(", ")
    end

    def method_refactor(row)
      if row[:writes] >= 5
        "move writes behind a smaller state object or transaction helper"
      elsif row[:conditional_calls] >= 10
        "reify operation variants or split branch coordinator"
      else
        "extract decision table or named policy helper"
      end
    end

    def hub_refactor(row)
      if row[:conditional_calls] >= 10
        "replace branch hub with reified operation dispatch"
      else
        "split conditional responsibilities by case family"
      end
    end

    def state_refactor(row)
      if protocol_summary(row) != "-"
        "wrap protocol in a small lifecycle object"
      elsif row[:writers] >= 4
        "centralize writes behind one owner"
      else
        "verify this state belongs on the owner"
      end
    end

    def manifest_path
      File.join(@root, "gems/espalier/architecture.yml")
    end

    def method_architecture_score(row)
      score = row[:writes] * 5.0 + row[:reads] * 1.5 + row[:conditional_calls] * 1.7 + row[:always_calls] * 0.8
      score += 10 if row[:writes].positive? && (row[:conditional_calls] + row[:always_calls]) >= 10
      score
    end

    def ruby_source_bytes
      source_files.sum { |path| File.size(path) }
    end

    def ruby_source_words
      source_files.sum { |path| File.read(path).split(/\s+/).size }
    end

    def source_files
      @source_files ||= Dir.glob(File.join(@root, "src/**/*.rb"))
    end

    def fmt(value)
      format("%.2f", value)
    end

    def escape(value)
      value.to_s.gsub("|", "\\|")
    end
  end
end
