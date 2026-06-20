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
      case engine.to_s
      when "ruby"
        project_files(paths, language: language)
      when "rust"
        rust_project_files(paths, language: language)
      else
        raise ArgumentError, "unsupported syntax oracle engine: #{engine}"
      end
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
        "state_reads" => rows(document.state_reads, %i[field receiver function owner line span]),
        "state_writes" => rows(document.state_writes, %i[field receiver function owner line span]),
        "decisions" => rows(document.decision_sites, %i[kind members function line span predicate enclosing_span]),
        "branch_decisions" => branch_decision_rows(document),
        "dispatch_sites" => rows(document.dispatch_sites, %i[variant_set arm_members outside function line span]),
        "semantic_effects" => rows(document.semantic_effect_sites, %i[kind detail function line span]),
        "predicate_bodies" => rows(document.predicate_defs, %i[name owner body line span]),
        "local_complexity" => local_complexity_rows(document),
        "clone_candidates" => rows(
          document.clone_candidates,
          %i[method_name node_name line span mass fingerprint child_fingerprints child_masses]
        )
      }
    end

    def rust_project_files(files, language:)
      lang = language || Syntax.language_for(files.first).to_s
      JSON.parse(Native::Command.run("syntax-facts", "--language", lang.to_s, *files))
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

    def normalize_value(value)
      case value
      when Symbol
        value.to_s
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
