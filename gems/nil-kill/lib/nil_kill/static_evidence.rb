# typed: false
# frozen_string_literal: true

begin
  require "decomplex/source_filter"
  require "decomplex/syntax"
rescue LoadError
  require_relative "../../../decomplex/lib/decomplex/source_filter"
  require_relative "../../../decomplex/lib/decomplex/syntax"
end

module NilKill
  # Static, language-neutral evidence for Espalier. This intentionally avoids
  # Nil-Kill's Ruby runtime/Sorbet inference path and consumes the shared
  # Tree-sitter facts exposed by Decomplex.
  class StaticEvidence
    def self.build(targets = nil, root: NilKill::ROOT)
      new(targets, root: root).build
    end

    def initialize(targets = nil, root: NilKill::ROOT)
      @targets = Array(targets).compact
      @root = root
    end

    def build
      methods = []
      fields = []
      state_types = {}
      state_protocols = Hash.new { |h, k| h[k] = Set.new }
      state_param_origins = Hash.new { |h, k| h[k] = Set.new }
      signatures = {}
      type_definitions = []
      files = target_files

      files.each do |file|
        doc = Decomplex::Syntax.parse(file, parser: "tree_sitter")
        provider = Languages.provider_for(doc.language)
        facts = doc.adapter.structural_facts(doc)
        rel_path = rel(file)
        evidence = provider.static_evidence(document: doc, facts: facts, rel_path: rel_path)
        methods.concat(evidence.fetch("methods", []))
        fields.concat(evidence.fetch("fields", []))
        state_types.merge!(evidence.fetch("state_types", {}))
        merge_set_map!(state_protocols, evidence.fetch("state_protocols", {}))
        merge_set_map!(state_param_origins, evidence.fetch("state_param_origins", {}))
        signatures.merge!(evidence.fetch("signatures", {}))
        type_definitions.concat(evidence.fetch("type_definitions", []))
      end

      state_protocols = stringify_set_map(state_protocols)
      state_param_origins = stringify_set_map(state_param_origins)
      type_definitions = type_definitions.uniq do |definition|
        [definition["language"], definition["path"], definition["owner"], definition["kind"],
          definition["name"], definition["line"], definition["type_system"]]
      end
      typed_signature_count = type_definitions.count { |definition| definition["kind"] == "method_signature" }

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
          "state_protocols" => state_protocols,
          "state_param_origins" => state_param_origins,
          "signatures" => Hash[signatures.sort],
          "type_definitions" => type_definitions.sort_by { |definition| [definition["path"].to_s, definition["owner"].to_s, definition["kind"].to_s, definition["name"].to_s] },
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
          "state_protocols" => state_protocols.size,
          "state_param_origins" => state_param_origins.size,
          "type_definitions" => type_definitions.size,
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
        "language" => Decomplex::Syntax.language_for(file).to_s,
        "digest" => "sha256:#{Digest::SHA256.file(file).hexdigest}",
        "parser" => "tree_sitter",
      }
    end

    def languages_for(files)
      files.map { |file| Decomplex::Syntax.language_for(file).to_s }.uniq.sort
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
