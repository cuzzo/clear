# frozen_string_literal: true

require "json"
require_relative "syntax"
require_relative "native/command"

module Decomplex
  module SyntaxOracle
    FORMAT = "decomplex.syntax-facts.v1"

    module_function

    def project(files, engine: "ruby", language: nil)
      paths = Array(files).map(&:to_s)
      projection =
        case engine.to_s
        when "ruby"
          project_files(paths, language: language)
        when "rust"
          rust_project_files(paths, language: language)
        else
          raise ArgumentError, "unsupported syntax oracle engine: #{engine}"
        end
      canonical_projection(projection)
    end

    def canonical_json(files, engine: "ruby", language: nil)
      JSON.pretty_generate(project(files, engine: engine, language: language)) << "\n"
    end

    def project_files(files, language: nil)
      {
        "format" => FORMAT,
        "documents" => Array(files).map do |file|
          lang = (language || Syntax.language_for(file)).to_sym
          project_document(Syntax.parse(file, language: lang))
        end
      }
    end

    def project_document(document)
      {
        "file" => logical_file(document.file),
        "language" => document.language.to_s,
        "functions" => rows(document.function_defs, %i[name owner line span visibility params]),
        "owners" => rows(document.owner_defs, %i[name kind line span]),
        "calls" => rows(
          document.call_sites,
          %i[receiver message function owner line span conditional arguments control safe_navigation block]
        ),
        "state_declarations" => rows(document.state_declarations, %i[field owner type line span]),
        "state_param_origins" => rows(document.state_param_origins, %i[field receiver owner param function line span]),
        "state_reads" => rows(document.state_reads, %i[field receiver function owner line span]),
        "state_writes" => rows(document.state_writes, %i[field receiver function owner line span]),
        "decisions" => rows(document.decision_sites, %i[kind members function line span predicate enclosing_span]),
        "branch_decisions" => branch_decision_rows(document),
        "branch_arms" => rows(
          document.branch_arms,
          %i[function kind line span decision_line decision_span predicate member body]
        ),
        "dispatch_sites" => rows(document.dispatch_sites, %i[variant_set arm_members outside function line span]),
        "semantic_effects" => rows(document.semantic_effect_sites, %i[kind detail function line span]),
        "predicate_bodies" => rows(document.predicate_defs, %i[name owner body line span]),
        "comparisons" => comparison_rows(document),
        "path_conditions" => rows(document.path_condition_sites, %i[guards action function line span]),
        "protocol_method_effects" => rows(document.protocol_method_effects, %i[owner name line reads writes]),
        "protocol_call_paths" => protocol_call_path_rows(document),
        "immutable_struct_readers" => normalize_value(document.immutable_struct_readers),
        "immutable_struct_reader_types" => normalize_value(document.immutable_struct_reader_types),
        "type_aliases" => normalize_value(document.type_aliases),
        "method_param_types" => normalize_value(document.respond_to?(:method_param_types) ? document.method_param_types : {}),
        "clone_candidates" => clone_candidate_rows(document),
        "redundant_nil_guards" => rows(document.redundant_nil_guard_findings, %i[defn line span local guard proof]),
        "local_methods" => local_method_rows(document),
        "local_complexity_scores" => local_complexity_rows(document)
      }
    end

    def rust_project_files(files, language:)
      lang = language || Syntax.language_for(files.first).to_s
      JSON.parse(Native::Command.run("syntax-facts", "--language", lang.to_s, *files))
    end

    def canonical_projection(projection)
      {
        "format" => projection.fetch("format"),
        "documents" => Array(projection.fetch("documents")).map { |document| canonical_document(document) }
      }
    end

    def canonical_document(document)
      sections = %w[
        functions owners calls state_declarations state_param_origins state_reads
        state_writes decisions branch_decisions branch_arms dispatch_sites
        semantic_effects predicate_bodies comparisons path_conditions
        protocol_method_effects protocol_call_paths clone_candidates redundant_nil_guards
        local_methods local_complexity_scores
      ]
      map_sections = %w[
        immutable_struct_readers immutable_struct_reader_types type_aliases
        method_param_types
      ]
      out = {
        "file" => document.fetch("file"),
        "language" => document.fetch("language")
      }
      sections.each do |section|
        rows = Array(document.fetch(section)).map { |row| normalize_value(row) }
        out[section] = rows.sort_by { |row| JSON.generate(row) }
      end
      map_sections.each do |section|
        out[section] = normalize_value(document.fetch(section, {}))
      end
      out
    end

    def rows(items, keys)
      Array(items).map do |item|
        keys.each_with_object({}) do |key, out|
          out[key.to_s] = normalize_value(item.public_send(key))
        end
      end.sort_by { |row| JSON.generate(row) }
    end

    def branch_decision_rows(document)
      rows = document.branch_decisions(
        immutable_readers: document.immutable_struct_readers,
        immutable_reader_types: document.immutable_struct_reader_types,
        type_aliases: document.type_aliases
      )
      rows(rows, %i[function line span predicate state_refs])
    end

    def local_complexity_rows(document)
      document.local_complexity_scores.map do |id, score|
        {
          "id" => id.to_s,
          "score" => normalize_value(score.fetch(:score)),
          "signals" => normalize_value(score.fetch(:signals))
        }
      end.sort_by { |row| row.fetch("id") }
    end

    def comparison_rows(document)
      rows(document.comparison_sites, %i[source operator function line span]).map do |row|
        row.merge("raw" => row.fetch("source"), "canon_source" => normalize_comparison_source(row.fetch("source")))
      end
    end

    def protocol_call_path_rows(document)
      document.protocol_call_paths.map do |path|
        {
          "owner" => path.owner,
          "name" => path.name,
          "line" => path.line,
          "calls" => Array(path.calls).map { |call| normalize_value(call.to_h.slice(:mid, :line, :span)) }
        }
      end.sort_by { |row| JSON.generate(row) }
    end

    def clone_candidate_rows(document)
      document.clone_candidates.map do |candidate|
        {
          "line" => candidate.line,
          "span" => normalize_value(candidate.span),
          "method_name" => candidate.method_name,
          "node_name" => candidate.node_name,
          "mass" => candidate.mass,
          "fingerprint" => candidate.fingerprint,
          "raw" => candidate.raw,
          "child_fingerprints" => normalize_value(candidate.child_fingerprints),
          "child_masses" => normalize_value(candidate.child_masses)
        }
      end.sort_by { |row| JSON.generate(row) }
    end

    def local_method_rows(document)
      document.local_methods.map do |method|
        {
          "id" => method.id,
          "owner" => method.owner,
          "name" => method.name,
          "line" => method.line,
          "span" => normalize_value(method.span),
          "statements" => Array(method.statements).map do |statement|
            normalize_value(statement.to_h.slice(:index, :line, :end_line, :span, :source,
                                                 :reads, :writes, :dependencies, :co_uses))
          end,
          "boundaries" => Array(method.boundaries).map do |boundary|
            normalize_value(boundary.to_h.slice(:before_index, :after_index, :line, :kind, :text))
          end,
          "local_contract_assignments" => normalize_value(document.local_contract_assignments(method))
        }
      end.sort_by { |row| JSON.generate(row) }
    end

    def normalize_comparison_source(source)
      text = source.to_s.strip
      text = text[1..].to_s.strip if text.start_with?("!")
      text = text.sub(/\Aself\./, "").sub(/\A@/, "")
      if (dot_index = text.index("."))
        receiver = text[0...dot_index]
        rest = text[(dot_index + 1)..]
        text = rest if receiver.match?(/\A[A-Za-z_]\w*\z/) &&
                       (rest.include?(" == ") || rest.include?(" != ") || rest.include?("."))
      end
      text.gsub(/\s+/, " ").strip
    end

    def normalize_value(value)
      case value
      when Symbol
        value.to_s
      when Set
        value.to_a.map { |item| normalize_value(item) }.sort_by { |item| JSON.generate(item) }
      when Array
        value.map { |item| normalize_value(item) }
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, out|
          raw_key = value.key?(key) ? key : key.to_sym
          out[key] = normalize_value(value.fetch(raw_key))
        end
      else
        value
      end
    end

    def logical_file(file)
      path = file.to_s.tr("\\", "/")
      marker = "gems/decomplex/examples/"
      index = path.index(marker)
      return path[index..] if index

      path
    end
  end
end
