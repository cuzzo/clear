# typed: false
# frozen_string_literal: true

require "open3"
require "digest"
require "pathname"
require "set"
require "time"

sibling_decomplex = File.expand_path("../../../decomplex/lib/decomplex", __dir__)
if File.file?("#{sibling_decomplex}/source_filter.rb")
  require "#{sibling_decomplex}/source_filter"
else
  require "decomplex/source_filter"
end
require_relative "alias_recommendations"
require_relative "fact_mine_static_facts"
require_relative "languages"
require_relative "static_helpers"
require_relative "tree_sitter"

module Espalier
  # Static, language-neutral evidence for Espalier. This intentionally avoids
  # Nil-Kill's Ruby runtime/Sorbet inference path and consumes the shared
  # Tree-sitter facts mined by FactMine.
  class StaticEvidence
    def self.build(targets = nil, root: Espalier::ROOT, language: nil, vcs: nil, include_annotations: true)
      new(targets, root: root, language: language, vcs: vcs, include_annotations: include_annotations).build
    end

    def initialize(targets = nil, root: Espalier::ROOT, language: nil, vcs: nil, include_annotations: true)
      @targets = Array(targets).compact
      @root = root
      @language = normalize_language(language)
      @vcs = normalize_vcs(vcs)
      @include_annotations = include_annotations
    end

    def build
      methods = []
      fields = []
      state_types = {}
      struct_declarations = []
      state_type_records = []
      state_protocols = Hash.new { |h, k| h[k] = Set.new }
      state_param_origins = Hash.new { |h, k| h[k] = Set.new }
      state_protocol_records = []
      state_param_origin_records = []
      signatures = {}
      type_definitions = []
      hash_shapes = []
      array_shapes = []
      tlet_sites = []
      dead_nil_checks = []
      deterministic_guards = []
      return_origins = []
      noreturn_methods = []
      files = target_files

      files.each do |file|
        doc = TreeSitter.parse(file, parser: "tree_sitter", language: @language)
        facts = static_facts_for(doc)
        methods.concat(facts.fetch(:methods, []))
        fields.concat(facts.fetch(:fields, []))
        struct_declarations.concat(facts.fetch(:struct_declarations, []))
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
        tlet_sites.concat(facts.fetch(:tlet_sites, []))
        dead_nil_checks.concat(facts.fetch(:dead_nil_checks, []))
        deterministic_guards.concat(facts.fetch(:deterministic_guards, []))
        return_origins.concat(facts.fetch(:return_origins, []))
        noreturn_methods.concat(facts.fetch(:noreturn_methods, []))
      end
      type_definitions.concat(ruby_annotation_type_definitions(files))

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
      struct_declarations = struct_declarations.uniq do |decl|
        [decl["path"], decl["class"], Array(decl["fields"])]
      end
      hash_shapes = hash_shapes.uniq do |shape|
        [shape["path"], shape["line"], Array(shape["keys"]), Array(shape["value_types"])]
      end
      array_shapes = array_shapes.uniq do |shape|
        [shape["path"], shape["line"], Array(shape["tuple_types"]), shape["size"]]
      end
      tlet_sites = tlet_sites.uniq do |site|
        [site["path"], site["line"], site["type"]]
      end
      dead_nil_checks = dead_nil_checks.uniq do |finding|
        [finding["path"], finding["line"], finding["kind"], finding["code"]]
      end
      deterministic_guards = deterministic_guards.uniq do |finding|
        [finding["path"], finding["line"], finding["predicate_kind"], finding["code"]]
      end
      return_origins = return_origins.uniq do |origin|
        [origin["path"], origin["line"], origin["class"], origin["method"], origin["kind"]]
      end
      noreturn_methods = noreturn_methods.uniq do |method|
        [method["language"], method["path"], method["owner"], method["name"], method["line"]]
      end
      rbi_field_types = rbi_field_type_records(type_definitions)

      {
        "version" => 2,
        "schema_version" => 2,
        "kind" => "espalier_static_evidence",
        "parser" => "tree_sitter",
        "generated_at" => Time.now.utc.iso8601,
        "root" => @root,
        "vcs" => @vcs&.to_s,
        "target_dirs" => target_dirs.map { |dir| rel(dir) },
        "target_exclude_dirs" => Espalier.target_exclude_dirs(root: @root).map { |dir| rel(dir) },
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
          "struct_declarations" => struct_declarations.sort_by { |decl| [decl["path"].to_s, decl["class"].to_s] },
          "hash_shapes" => hash_shapes.sort_by { |shape| [shape["path"].to_s, shape["line"].to_i, shape["keys"].to_s] },
          "array_shapes" => array_shapes.sort_by { |shape| [shape["path"].to_s, shape["line"].to_i, shape["tuple_types"].to_s] },
          "tlet_sites" => tlet_sites.sort_by { |site| [site["path"].to_s, site["line"].to_i] },
          "dead_nil_checks" => dead_nil_checks.sort_by { |finding| [finding["path"].to_s, finding["line"].to_i, finding["kind"].to_s] },
          "deterministic_guards" => deterministic_guards.sort_by { |finding| [finding["path"].to_s, finding["line"].to_i, finding["code"].to_s] },
          "return_origins" => return_origins.sort_by { |origin| [origin["path"].to_s, origin["line"].to_i, origin["method"].to_s] },
          "noreturn_methods" => noreturn_methods.sort_by { |method| [method["path"].to_s, method["owner"].to_s, method["name"].to_s] },
          "rbi_field_types" => rbi_field_types.sort_by { |record| [record["class"].to_s, record["field"].to_s] },
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
          "struct_declarations" => struct_declarations.size,
          "hash_shapes" => hash_shapes.size,
          "array_shapes" => array_shapes.size,
          "tlet_sites" => tlet_sites.size,
          "dead_nil_checks" => dead_nil_checks.size,
          "deterministic_guards" => deterministic_guards.size,
          "return_origins" => return_origins.size,
          "noreturn_methods" => noreturn_methods.size,
          "rbi_field_types" => rbi_field_types.size,
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
      return Espalier.target_dirs(root: @root) if @targets.empty?

      @targets.map { |target| File.expand_path(target, @root) }
    end

    def target_files
      exts = TreeSitter.supported_exts(parser: "tree_sitter")
      return git_tracked_target_files(exts) if @vcs == :git

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

    def git_tracked_target_files(exts)
      targets = target_dirs
      git_tracked_files.select do |path|
        target_path?(path, targets) && source_file?(path, exts)
      end.uniq.sort
    end

    def git_tracked_files
      top = git_root
      out, status = Open3.capture2e("git", "-C", top, "ls-files", "-z")
      raise ArgumentError, "git ls-files failed under #{top}: #{out.strip}" unless status.success?

      out.split("\0").reject(&:empty?).map { |path| File.expand_path(path, top) }
    end

    def git_root
      out, status = Open3.capture2e("git", "-C", @root, "rev-parse", "--show-toplevel")
      raise ArgumentError, "--vcs=git requires #{@root} to be inside a git worktree" unless status.success?

      File.expand_path(out.strip)
    end

    def target_path?(path, targets)
      expanded = File.expand_path(path)
      targets.any? do |target|
        target = File.expand_path(target, @root)
        if File.directory?(target)
          expanded == target || expanded.start_with?("#{target}#{File::SEPARATOR}")
        else
          expanded == target
        end
      end
    end

    def source_file?(path, exts)
      File.file?(path) &&
        !File.basename(path).start_with?(".") &&
        exts.include?(File.extname(path).downcase) &&
        Decomplex::SourceFilter.source_file?(path, parser: "tree_sitter", root: @root) &&
        !Espalier.target_excluded?(path, root: @root)
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
      @language || TreeSitter.language_for(file)
    end

    def ruby_annotation_type_definitions(files)
      return [] unless @include_annotations
      return [] unless ruby_annotation_index?(files)

      ruby_annotation_files.flat_map do |file|
        static_facts_for(TreeSitter.parse(file, parser: "tree_sitter", language: :ruby))
          .fetch(:type_definitions, [])
      rescue LoadError
        raise
      rescue StandardError
        []
      end
    end

    def ruby_annotation_index?(files)
      return false unless @language.nil? || @language == :ruby
      return false unless ruby_annotation_target_scope?
      return true if files.any? { |file| file_language(file).to_s == "ruby" }

      @targets.empty?
    end

    def ruby_annotation_target_scope?
      return true if @targets.empty?

      target_dirs.any? do |target|
        expanded = File.expand_path(target, @root)
        path = rel(expanded)
        expanded == @root || path == "." || path == "src" || path.start_with?("src#{File::SEPARATOR}") ||
          path == "sorbet" || path.start_with?("sorbet#{File::SEPARATOR}")
      end
    end

    def ruby_annotation_files
      Dir.glob(File.join(@root, "sorbet", "rbi", "**", "*.rbi")).select { |path| File.file?(path) }.sort
    end

    def rbi_field_type_records(type_definitions)
      Array(type_definitions).filter_map do |definition|
        next unless definition["language"].to_s == "ruby"
        next unless definition["kind"].to_s == "method_signature"
        next unless definition["path"].to_s.end_with?(".rbi")

        type = definition["return_type"].to_s
        next if type.empty?

        {
          "class" => definition["owner"].to_s,
          "field" => definition["name"].to_s,
          "type" => type,
          "path" => definition["path"].to_s,
          "line" => definition["line"].to_i,
          "type_system" => definition["type_system"].to_s,
        }
      end.uniq { |record| [record["class"], record["field"], record["type"]] }
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

    def normalize_vcs(vcs)
      text = vcs.to_s.strip.downcase
      return nil if text.empty? || %w[none false off].include?(text)
      return :git if text == "git"

      raise ArgumentError, "unsupported --vcs=#{vcs}; supported values: git"
    end

    def static_facts_for(document)
      FactMineStaticFacts.build(document, structural_facts_for(document), root: @root)
    end

    def structural_facts_for(document)
      facts =
        if document.respond_to?(:adapter) && document.adapter
          document.adapter.structural_facts(document)
        else
          {
            function_defs: document.function_defs,
            owner_defs: document.owner_defs,
            call_sites: document.call_sites,
            state_declarations: document.state_declarations,
            state_writes: document.state_writes,
            state_reads: document.state_reads,
            state_param_origins: document.state_param_origins,
            local_methods: document.local_methods,
          }
        end

      facts[:comparison_sites] = document.comparison_sites if document.respond_to?(:comparison_sites)
      facts[:redundant_nil_guard_findings] = document.redundant_nil_guard_findings if document.respond_to?(:redundant_nil_guard_findings)
      facts[:type_definitions] = document.type_definitions if document.respond_to?(:type_definitions)
      facts
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
