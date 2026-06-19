# typed: false
# frozen_string_literal: true

sibling_decomplex = File.expand_path("../../../decomplex/lib/decomplex", __dir__)
if File.file?("#{sibling_decomplex}/source_filter.rb") && File.file?("#{sibling_decomplex}/syntax.rb")
  require "#{sibling_decomplex}/ast"
  require "#{sibling_decomplex}/source_filter"
  require "#{sibling_decomplex}/syntax"
else
  require "decomplex/ast"
  require "decomplex/source_filter"
  require "decomplex/syntax"
end
require_relative "alias_recommendations"
require_relative "decomplex_static_facts"

module NilKill
  # Static, language-neutral evidence for Espalier. This intentionally avoids
  # Nil-Kill's Ruby runtime/Sorbet inference path and consumes the shared
  # Tree-sitter facts exposed by Decomplex.
  class StaticEvidence
    def self.build(targets = nil, root: NilKill::ROOT, language: nil)
      new(targets, root: root, language: language).build
    end

    def initialize(targets = nil, root: NilKill::ROOT, language: nil)
      @targets = Array(targets).compact
      @root = root
      @language = normalize_language(language)
    end

    def build
      methods = []
      fields = []
      state_types = {}
      state_type_records = []
      state_protocols = Hash.new { |h, k| h[k] = Set.new }
      state_param_origins = Hash.new { |h, k| h[k] = Set.new }
      state_protocol_records = []
      state_param_origin_records = []
      signatures = {}
      type_definitions = []
      hash_shapes = []
      array_shapes = []
      files = target_files

      files.each do |file|
        doc = Decomplex::Syntax.parse(file, parser: "tree_sitter", language: @language)
        facts = doc.static_facts(root: @root)
        methods.concat(facts.fetch(:methods, []))
        fields.concat(facts.fetch(:fields, []))
        state_types.merge!(facts.fetch(:state_types, {}))
        state_type_records.concat(facts.fetch(:state_type_records, []))
        merge_set_map!(state_protocols, facts.fetch(:state_protocols, {}))
        merge_set_map!(state_param_origins, facts.fetch(:state_param_origins, {}))
        state_protocol_records.concat(facts.fetch(:state_protocol_records, []))
        state_param_origin_records.concat(facts.fetch(:state_param_origin_records, []))
        signatures.merge!(facts.fetch(:signatures, {}))
        type_definitions.concat(facts.fetch(:type_definitions, []))
        hash_shapes.concat(facts.fetch(:hash_shapes, []))
        array_shapes.concat(facts.fetch(:array_shapes, []))
      end

      state_protocols = stringify_set_map(state_protocols)
      state_param_origins = stringify_set_map(state_param_origins)
      state_type_records = state_type_records.uniq do |record|
        [record["language"], record["path"], record["owner"],
          record["field"], record["declared_type"], record["line"]]
      end
      state_protocol_records = state_protocol_records.uniq do |record|
        [record["language"], record["path"], record["owner"], record["function"],
          record["field"], record["protocol"], record["line"]]
      end
      state_param_origin_records = state_param_origin_records.uniq do |record|
        [record["language"], record["path"], record["owner"], record["function"],
          record["field"], record["param"], record["line"]]
      end
      type_definitions = type_definitions.uniq do |definition|
        [definition["language"], definition["path"], definition["owner"], definition["kind"],
          definition["name"], definition["line"], definition["type_system"]]
      end
      alias_recommendations = AliasRecommendations.build(type_definitions: type_definitions)
      typed_signature_count = type_definitions.count { |definition| definition["kind"] == "method_signature" }
      hash_shapes = hash_shapes.uniq do |shape|
        [shape["path"], shape["line"], Array(shape["keys"]), Array(shape["value_types"])]
      end
      array_shapes = array_shapes.uniq do |shape|
        [shape["path"], shape["line"], Array(shape["tuple_types"]), shape["size"]]
      end

      {
        "version" => 2,
        "schema_version" => 2,
        "kind" => "espalier_static_evidence",
        "parser" => "tree_sitter",
        "generated_at" => Time.now.utc.iso8601,
        "root" => @root,
        "target_dirs" => target_dirs.map { |dir| rel(dir) },
        "target_exclude_dirs" => NilKill.target_exclude_dirs.map { |dir| rel(dir) },
        "runtime_fields" => false,
        "files" => files.map { |file| file_record(file) },
        "fields" => fields.uniq { |field| field["id"] }.sort_by { |field| [field["path"], field["owner"], field["name"]] },
        "methods" => methods.sort_by { |method| [method["path"], method["owner"], method["line"].to_i, method["name"]] },
        "facts" => {
          "state_types" => Hash[state_types.sort],
          "state_type_records" => state_type_records.sort_by { |record| [record["language"].to_s, record["path"].to_s, record["owner"].to_s, record["field"].to_s] },
          "state_protocols" => state_protocols,
          "state_param_origins" => state_param_origins,
          "state_protocol_records" => state_protocol_records.sort_by { |record| [record["language"].to_s, record["path"].to_s, record["owner"].to_s, record["field"].to_s, record["protocol"].to_s] },
          "state_param_origin_records" => state_param_origin_records.sort_by { |record| [record["language"].to_s, record["path"].to_s, record["owner"].to_s, record["field"].to_s, record["param"].to_s] },
          "signatures" => Hash[signatures.sort],
          "type_definitions" => type_definitions.sort_by { |definition| [definition["path"].to_s, definition["owner"].to_s, definition["kind"].to_s, definition["name"].to_s] },
          "alias_recommendations" => alias_recommendations,
          "hash_shapes" => hash_shapes.sort_by { |shape| [shape["path"].to_s, shape["line"].to_i, shape["keys"].to_s] },
          "array_shapes" => array_shapes.sort_by { |shape| [shape["path"].to_s, shape["line"].to_i, shape["tuple_types"].to_s] },
          "ivar_runtime" => [],
          "ivar_protocols" => state_protocols,
          "ivar_param_origins" => state_param_origins,
        },
        "summary" => {
          "files" => files.size,
          "methods" => methods.size,
          "fields" => fields.uniq { |field| field["id"] }.size,
          "signatures" => typed_signature_count,
          "state_types" => state_types.size,
          "state_type_records" => state_type_records.size,
          "state_protocols" => state_protocols.size,
          "state_param_origins" => state_param_origins.size,
          "state_protocol_records" => state_protocol_records.size,
          "state_param_origin_records" => state_param_origin_records.size,
          "type_definitions" => type_definitions.size,
          "alias_recommendations" => alias_recommendations.size,
          "hash_shapes" => hash_shapes.size,
          "array_shapes" => array_shapes.size,
          "ivar_protocols" => state_protocols.size,
          "ivar_param_origins" => state_param_origins.size,
        },
        "language_capabilities" => languages_for(files).to_h do |language|
          [language, Languages.capability_for(language)]
        end,
      }
    end

    private

    def target_dirs
      return NilKill.target_dirs if @targets.empty?

      @targets.map { |target| File.expand_path(target, @root) }
    end

    def target_files
      exts = Decomplex::Syntax.supported_exts(parser: "tree_sitter")
      target_dirs.flat_map do |target|
        if File.directory?(target)
          Decomplex::SourceFilter.collect(
            [target],
            parser: "tree_sitter",
            root: @root
          ).select { |path| source_file?(path, exts) }
        elsif source_file?(target, exts)
          [target]
        else
          []
        end
      end.uniq.sort
    end

    def source_file?(path, exts)
      File.file?(path) &&
        !File.basename(path).start_with?(".") &&
        exts.include?(File.extname(path).downcase) &&
        Decomplex::SourceFilter.source_file?(path, parser: "tree_sitter", root: @root) &&
        !NilKill.target_excluded?(path)
    end

    def file_record(file)
      {
        "path" => rel(file),
        "language" => file_language(file).to_s,
        "digest" => "sha256:#{Digest::SHA256.file(file).hexdigest}",
        "parser" => "tree_sitter",
      }
    end

    def languages_for(files)
      files.map { |file| file_language(file).to_s }.uniq.sort
    end

    def file_language(file)
      @language || Decomplex::Syntax.language_for(file)
    end

    def normalize_language(language)
      text = language.to_s.strip
      return nil if text.empty?

      normalized = text.downcase.tr("-", "_")
      case normalized
      when "c++", "cplusplus" then :cpp
      when "c#", "c_sharp", "cs" then :csharp
      when "ts" then :typescript
      when "py" then :python
      when "rs" then :rust
      when "golang" then :go
      when "kt", "kts" then :kotlin
      else normalized.to_sym
      end
    end

    def merge_set_map!(target, source)
      source.each do |key, values|
        Array(values).each { |value| target[key].add(value) }
      end
    end

    def stringify_set_map(map)
      Hash[map.sort.map { |key, values| [key, values.to_a.map(&:to_s).sort.uniq] }]
    end

    def rel(path)
      Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s
    rescue StandardError
      path.to_s
    end
  end
end
