# frozen_string_literal: true

require "pathname"
require "yaml"

module Espalier
  # Builds a compact architecture-review report from the full Espalier manifest.
  class Reporter
    DEFAULT_LIMIT = 20

    def self.from_yaml_file(path, root: Dir.pwd, limit: DEFAULT_LIMIT)
      new(YAML.load_file(path), root: root, limit: limit)
    end

    def initialize(manifest, root: Dir.pwd, limit: DEFAULT_LIMIT, link_base: nil)
      @manifest = manifest || []
      @root = File.expand_path(root)
      @limit = limit
      @link_base = link_base && File.expand_path(link_base)
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
      sections << encapsulation_pressure_section
      sections << owner_state_cohesion_section
      sections << collaboration_meshes_section
      sections << mediator_candidates_section
      sections << coordinator_mutator_collisions
      sections << conditional_delegation_hubs
      sections << state_lifecycle_pressure
      sections << privatization_candidates_section
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
        - [Encapsulation Pressure](#encapsulation-pressure)
        - [Owner State Cohesion](#owner-state-cohesion)
        - [Collaboration Meshes](#collaboration-meshes)
        - [Mediator/Reification Candidates](#mediatorreification-candidates)
        - [Coordinator/Mutator Collisions](#coordinatormutator-collisions)
        - [Conditional Delegation Hubs](#conditional-delegation-hubs)
        - [State Lifecycle Pressure](#state-lifecycle-pressure)
        - [Privatization Candidates](#privatization-candidates)
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
      if (top_private = privatization_candidates.first)
        lines << "- Strongest visibility-tightening candidate: #{method_ref(top_private)} " \
                 "(score=#{fmt(top_private[:score])}, internal callers=#{top_private[:callers].size})."
      end
      if (top_encapsulation = encapsulation_rows.first)
        lines << "- Highest encapsulation pressure: #{owner_ref(top_encapsulation[:owner], top_encapsulation[:file])} " \
                 "(score=#{fmt(top_encapsulation[:score])}, public=#{top_encapsulation[:public_methods]}, " \
                 "state=#{top_encapsulation[:state_count]}, public mutators=#{top_encapsulation[:public_mutators]})."
      end
      if (top_cohesion = owner_state_cohesion_rows.first)
        lines << "- Lowest owner state cohesion: #{owner_ref(top_cohesion[:owner], top_cohesion[:file])} " \
                 "(score=#{fmt(top_cohesion[:score])}, components=#{top_cohesion[:component_count]}, " \
                 "fragmentation=#{fmt(top_cohesion[:fragmentation])})."
      end
      if (top_mesh = collaboration_mesh_rows.first)
        lines << "- Broadest collaboration mesh: #{mesh_label(top_mesh)} " \
                 "(score=#{fmt(top_mesh[:score])}, owners=#{top_mesh[:node_count]}, edges=#{top_mesh[:edge_count]})."
      end
      if (top_mediator = mediator_candidate_rows.first)
        lines << "- Strongest mediator/reification candidate: #{mesh_owner_list(top_mediator[:owners])} " \
                 "(score=#{fmt(top_mediator[:score])}, terms=#{top_mediator[:common_terms].join(', ')})."
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
      source_bytes = source_bytes
      manifest_bytes = File.exist?(manifest_path) ? File.size(manifest_path) : nil
      source_words = source_words
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

    def owner_state_cohesion_section
      rows = owner_state_cohesion_rows.first(@limit)
      lines = ["## Owner State Cohesion", "_Class-level LCOM-style state clusters: methods connected through shared instance state._", ""]
      if rows.empty?
        lines << "None."
        lines << ""
        return lines.join("\n")
      end

      lines << "| # | owner | score | flags | state | stateful methods | components | bridges | largest | fragmentation | isolated | sample components | suggested refactor |"
      lines << "|---|-------|-------|-------|-------|------------------|------------|---------|---------|---------------|----------|-------------------|--------------------|"
      rows.each_with_index do |row, idx|
        lines << "| #{idx + 1} | #{owner_ref(row[:owner], row[:file])} | #{fmt(row[:score])} | #{escape(flag_list(row[:flags]))} | " \
                 "#{row[:state_count]} | #{row[:stateful_methods]} | #{row[:component_count]} | " \
                 "#{escape(bridge_list(row[:bridge_methods], row[:bridge_method_count]))} | " \
                 "#{row[:largest_component_methods]} (#{fmt(row[:largest_component_ratio])}) | #{fmt(row[:fragmentation])} | " \
                 "#{row[:isolated_components]} | #{escape(component_list(row[:component_samples]))} | " \
                 "#{escape(cohesion_refactor(row))} |"
      end
      lines << ""
      lines.join("\n")
    end

    def encapsulation_pressure_section
      rows = encapsulation_rows.first(@limit)
      lines = ["## Encapsulation Pressure", "_Owners where public API, mutable state, and internal-helper evidence suggest implementation detail is leaking._", ""]
      if rows.empty?
        lines << "None."
        lines << ""
        return lines.join("\n")
      end

      lines << "| # | owner | score | flags | public/private | state | public state | public mutators | internal helpers | fan-out | suggested refactor |"
      lines << "|---|-------|-------|-------|----------------|-------|--------------|-----------------|------------------|---------|--------------------|"
      rows.each_with_index do |row, idx|
        lines << "| #{idx + 1} | #{owner_ref(row[:owner], row[:file])} | #{fmt(row[:score])} | #{escape(flag_list(row[:flags]))} | " \
                 "#{row[:public_methods]}/#{row[:private_methods]} | #{row[:state_count]} | #{row[:public_state_methods]} | " \
                 "#{row[:public_mutators]} | #{helper_list(row[:privacy_candidates])} | #{row[:fan_out]} | " \
                 "#{escape(encapsulation_refactor(row))} |"
      end
      lines << ""
      lines.join("\n")
    end

    def collaboration_meshes_section
      rows = collaboration_mesh_rows.first(@limit)
      lines = ["## Collaboration Meshes", "_Owner-to-owner webs from manifest-visible delegation targets._", ""]
      if rows.empty?
        lines << "None."
        lines << ""
        return lines.join("\n")
      end

      lines << "| # | kind | score | owners | edges/calls | density | bidirectional | shared terms | top edges | suggested review |"
      lines << "|---|------|-------|--------|-------------|---------|---------------|--------------|-----------|------------------|"
      rows.each_with_index do |row, idx|
        lines << "| #{idx + 1} | #{row[:kind]} | #{fmt(row[:score])} | #{mesh_owner_list(row[:owners])} | " \
                 "#{row[:edge_count]}/#{row[:total_calls]} | #{fmt(row[:density])} | #{row[:bidirectional_pairs]} | " \
                 "#{escape(term_list(row[:common_terms]))} | #{escape(edge_list(row[:top_edges]))} | " \
                 "#{escape(collaboration_refactor(row))} |"
      end
      lines << ""
      lines.join("\n")
    end

    def mediator_candidates_section
      rows = mediator_candidate_rows.first(@limit)
      lines = ["## Mediator/Reification Candidates", "_Dense or broad collaboration clusters where a missing or overloaded role object may exist._", ""]
      if rows.empty?
        lines << "None."
        lines << ""
        return lines.join("\n")
      end

      lines << "| # | owners | score | shared terms | driver | evidence | suggested refactor |"
      lines << "|---|--------|-------|--------------|--------|----------|--------------------|"
      rows.each_with_index do |row, idx|
        lines << "| #{idx + 1} | #{mesh_owner_list(row[:owners])} | #{fmt(row[:score])} | " \
                 "#{escape(term_list(row[:common_terms]))} | `#{row[:driver]}` | " \
                 "#{escape(row[:evidence].join('; '))} | #{escape(row[:suggestion])} |"
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

    def privatization_candidates_section
      rows = privatization_candidates.first(@limit)
      lines = ["## Privatization Candidates", "_Public methods that likely should be private: same-owner callers, no manifest-visible external receiver calls, and helper/protocol evidence._", ""]
      if rows.empty?
        lines << "None."
        lines << ""
        return lines.join("\n")
      end

      lines << "| # | method | score | confidence | internal callers | state touches | reason |"
      lines << "|---|--------|-------|------------|------------------|---------------|--------|"
      rows.each_with_index do |row, idx|
        lines << "| #{idx + 1} | #{method_ref(row)} | #{fmt(row[:score])} | " \
                 "#{row[:confidence]} | #{escape(row[:callers].join(', '))} | " \
                 "#{row[:state_touches]} | #{escape(row[:reason])} |"
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
      @module_scores ||= @manifest.filter_map do |mod|
        method_rows = functions(mod).map { |fn| method_row(mod, fn) }
        state_count = states(mod).size
        method_count = method_rows.size
        next if method_count.zero?

        state_touches = method_rows.sum { |row| row[:reads] + row[:writes] }
        delegations = method_rows.sum { |row| row[:always_calls] + row[:conditional_calls] }
        facade = cohesive_value_facade_profiles[mod[:module].to_s]
        effective_delegations = facade ? [delegations - facade[:delegation_discount], 0].max : delegations
        write_methods = method_rows.count { |row| row[:writes].positive? }
        score = state_count * 3.0 + method_count * 0.6 + state_touches * 1.2 + effective_delegations * 0.35 + write_methods
        {
          module: mod[:module],
          file: mod[:file],
          state_count: state_count,
          method_count: method_count,
          state_touches: state_touches,
          delegations: delegations,
          effective_delegations: effective_delegations,
          write_methods: write_methods,
          cohesive_value_facade: facade,
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

    def privatization_candidates
      @privatization_candidates ||= PrivacyAnalyzer.candidates(@manifest).map do |row|
        row.merge(line: row[:line])
      end
    end

    def architecture_analyzer
      @architecture_analyzer ||= ArchitectureAnalyzer.new(@manifest)
    end

    def encapsulation_rows
      @encapsulation_rows ||= architecture_analyzer.encapsulation_pressure
    end

    def collaboration_mesh_rows
      @collaboration_mesh_rows ||= architecture_analyzer.collaboration_meshes
    end

    def mediator_candidate_rows
      @mediator_candidate_rows ||= architecture_analyzer.mediator_candidates
    end

    def owner_state_cohesion_rows
      @owner_state_cohesion_rows ||= architecture_analyzer.owner_state_cohesion
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
        line: fn[:line],
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

    def owner_ref(owner, file = nil)
      mod = @manifest.find { |row| row[:module].to_s == owner.to_s }
      file ||= mod && mod[:file]
      file ? "`#{owner}` (#{file_link(file)})" : "`#{owner}`"
    end

    def method_ref(row)
      line = row[:line]
      suffix = line ? ":#{line}" : ""
      "`#{row[:module]}##{row[:name]}` (#{file_link(row[:file], line)}#{suffix.empty? ? "" : ""})"
    end

    def file_link(file, line = nil)
      return "`-`" unless file

      suffix = line ? "#L#{line}" : ""
      "[`#{file}`](#{link_target(file)}#{suffix})"
    end

    def link_target(file)
      return absolute_or_legacy_target(file) unless @link_base

      source = source_path(file)
      Pathname.new(source).relative_path_from(Pathname.new(@link_base)).to_s
    rescue ArgumentError
      source
    end

    def absolute_or_legacy_target(file)
      path = file.to_s
      return path if Pathname.new(path).absolute?

      "../../#{path}"
    end

    def source_path(file)
      path = file.to_s
      Pathname.new(path).absolute? ? path : File.expand_path(path, @root)
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
        next unless line =~ /`(?<file>[^`]+\.[A-Za-z0-9]+):\d+`\s+\((?<method>[^)]+)\).*?\*\*(?<detectors>\d+) detectors\*\* \[score (?<score>\d+)/

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
        next unless line =~ /^\|\s*(?<rank>\d+)\s*\|\s*\[`(?<file>[^`]+\.[A-Za-z0-9]+):\d+`\][^|]*\|\s*`(?<method>[^`]+)`/

        index[[Regexp.last_match[:file], Regexp.last_match[:method]]] ||= {
          rank: Regexp.last_match[:rank]
        }
      end
    end

    def parse_boobytrap_report
      path = File.join(@root, "gems/boobytrap/report.md")
      return {} unless File.file?(path)

      File.readlines(path).each_with_object({}) do |line, index|
        next unless line =~ /^\|\s*(?<rank>\d+)\s*\|\s*`(?<file>[^`]+\.[A-Za-z0-9]+)`\s*\|\s*(?<hotspot>[\d.]+)\s*\|/

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
      if row[:cohesive_value_facade]
        return "review remaining public API breadth; delegation is mostly value facade"
      end

      if row[:state_count] >= 20
        "extract phase-state records and split lifecycle ownership"
      elsif row[:delegations] >= 100
        "separate coordinator from mechanism helpers"
      else
        "audit cohesion before local cleanup"
      end
    end

    def encapsulation_refactor(row)
      if row[:cohesive_value_facade]
        return "review public behavior breadth; composed value delegation is cohesive"
      end

      if row[:public_mutators] >= 5 && row[:state_count] >= 5
        "split mutable lifecycle state from the public facade"
      elsif row[:state_count] >= 8 && row[:public_state_methods] >= 5
        "extract a smaller state/context owner behind this public surface"
      elsif row[:public_state_methods] >= 8
        "narrow public state access through a smaller query/session object"
      elsif row[:privacy_candidates].any?
        "hide internal helpers behind the public entrypoint"
      elsif row[:fan_out] >= 8
        "check whether public orchestration should move to a coordinator"
      else
        "verify the broad public surface is intentional"
      end
    end

    def collaboration_refactor(row)
      if row[:cohesive_value_facade]
        return "facade fan-out is mostly value/stateless collaboration; review remaining breadth"
      end

      if row[:kind] == :dense_cycle
        "review bidirectional responsibilities and extract a boundary protocol"
      elsif row[:stateful_calls].positive?
        "check whether stateful collaboration belongs behind a mediator"
      else
        "verify this fan-out is an intentional facade/coordinator"
      end
    end

    def cohesion_refactor(row)
      if row[:fragmentation].to_f >= 0.5 && row[:component_count].to_i >= 3
        "split state clusters into smaller owner/context objects"
      elsif row[:isolated_components].to_i >= 2
        "review isolated state concerns before adding more API"
      else
        "verify these state clusters belong on one owner"
      end
    end

    def mesh_label(row)
      "`#{row[:driver]}` #{row[:kind]}"
    end

    def mesh_owner_list(owners)
      visible = owners.first(6).map { |owner| "`#{owner}`" }
      suffix = owners.size > visible.size ? " +#{owners.size - visible.size}" : nil
      ([visible.join(", "), suffix].compact.join(" "))
    end

    def flag_list(flags)
      flags.empty? ? "-" : flags.join(", ")
    end

    def helper_list(names)
      return "-" if names.empty?

      visible = names.first(3).map { |name| "`#{name}`" }
      suffix = names.size > visible.size ? " +#{names.size - visible.size}" : nil
      ([visible.join(", "), suffix].compact.join(" "))
    end

    def term_list(terms)
      terms.empty? ? "-" : terms.join(", ")
    end

    def edge_list(edges)
      edges.empty? ? "-" : edges.join("; ")
    end

    def component_list(components)
      return "-" if components.empty?

      components.first(3).map do |component|
        states = Array(component[:states]).first(2).join(", ")
        methods = Array(component[:methods]).first(2).join(", ")
        "#{component[:method_count]}m/#{component[:state_count]}s #{states}: #{methods}"
      end.join("; ")
    end

    def bridge_list(names, count)
      return "-" if count.to_i.zero?

      visible = Array(names).first(3).map { |name| "`#{name}`" }
      suffix = count.to_i > visible.size ? " +#{count.to_i - visible.size}" : nil
      ([visible.join(", "), suffix].compact.join(" "))
    end

    def owner_flags(row)
      flags = []
      flags << "state-heavy" if row[:state_count] >= 5
      flags << "many-mutators" if row[:write_methods] >= 5
      flags << "broad-delegator" if row[:delegations] >= 100
      flags << "low-cohesion-candidate" if row[:state_count] >= 5 && row[:state_touches] < row[:state_count] * 2
      flags << "cohesive-value-facade" if row[:cohesive_value_facade]
      flags.empty? ? "-" : flags.join(", ")
    end

    def cohesive_value_facade_profiles
      @cohesive_value_facade_profiles ||= architecture_analyzer.cohesive_value_facade_profiles
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

    def source_bytes
      source_files.sum { |path| File.size(path) }
    end

    def source_words
      source_files.sum { |path| File.read(path).split(/\s+/).size }
    end

    def source_files
      @source_files ||= @manifest.filter_map { |mod| mod[:file] }
                                 .uniq
                                 .map { |file| File.expand_path(file, @root) }
                                 .select { |path| File.file?(path) }
    end

    def fmt(value)
      format("%.2f", value)
    end

    def escape(value)
      value.to_s.gsub("|", "\\|")
    end
  end
end
