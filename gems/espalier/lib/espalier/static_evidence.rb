# typed: false
# frozen_string_literal: true

require "open3"
require "digest"
require "json"
require "pathname"
require "set"
require "tempfile"
require "time"

require_relative "type_profile"
require_relative "alias_recommendations"
require_relative "languages"
require_relative "static_helpers"
require_relative "tree_sitter"

module Espalier
  # Static, language-neutral evidence for Espalier. Uses the Rust FactMine
  # binary exclusively for fact extraction.
  class StaticEvidence
    FACT_MINE_RUST_BINARY = ENV.fetch(
      "FACT_MINE_RUST_BINARY",
      File.join(Espalier::ROOT, "gems", "fact-mine", "rust", "target", "release", "fact-mine-rust")
    ).freeze

    def self.build(targets = nil, root: Espalier::ROOT, language: nil, vcs: nil, include_annotations: true)
      new(targets, root: root, language: language, vcs: vcs, include_annotations: include_annotations).build
    end

    def self.project_modules(evidence)
      return [] unless evidence && evidence["methods"]

      # Group methods by owner
      methods_by_owner = Hash.new { |h, k| h[k] = [] }
      Array(evidence["methods"]).each do |m|
        meth = {
          name: m["name"],
          signature: m["signature"],
          parameters: Array(m["params"]),
          visibility: (m["visibility"] || :public).to_sym,
          line: m["line"]&.to_i,
          span: m["span"],
          file: m["path"],
          language: m["language"]&.to_sym,
          effects: { reads: Set.new, writes: Set.new },
          delegations: []
        }
        methods_by_owner[m["owner"]] << meth
      end

      # Group fields by owner
      fields_by_owner = Hash.new { |h, k| h[k] = [] }
      Array(evidence["fields"]).each do |f|
        fields_by_owner[f["owner"]] << f["name"]
      end

      # Index call graph edges (internal calls)
      internal_calls = Hash.new { |h, k| h[k] = [] }
      Array(evidence.dig("facts", "call_graph_edges")).each do |edge|
        next unless edge["kind"] == "internal_call"
        if edge["source"] =~ /^fn:(.+)#(.+)$/
          owner, func = $1, $2
          if edge["target"] =~ /^fn:.+#(.+)$/
            target_func = $1
            internal_calls["#{owner}##{func}"] << {
              receiver: "self",
              message: target_func,
              type: edge["conditional"] ? :conditional : :always
            }
          end
        end
      end

      # Map state protocols and param origins to reads/writes and delegations
      Array(evidence.dig("facts", "state_protocol_records")).each do |record|
        owner = record["owner"]
        func = record["function"]
        field = record["field"]
        proto = record["protocol"]

        meths = methods_by_owner[owner] || []
        meth = meths.find { |m| m[:name] == func }
        if meth
          meth[:effects][:reads].add(field)
          meth[:delegations] << {
            receiver: field,
            message: proto,
            type: :always
          }
        end
      end

      Array(evidence.dig("facts", "state_param_origin_records")).each do |record|
        owner = record["owner"]
        func = record["function"]
        field = record["field"]

        meths = methods_by_owner[owner] || []
        meth = meths.find { |m| m[:name] == func }
        if meth
          meth[:effects][:writes].add(field)
        end
      end

      # Add internal call delegations
      methods_by_owner.each do |owner, meths|
        meths.each do |meth|
          key = "#{owner}##{meth[:name]}"
          meth[:delegations].concat(internal_calls[key]) if internal_calls[key]
          meth[:delegations].uniq!
        end
      end

      # Construct modules array
      all_owners = (methods_by_owner.keys + fields_by_owner.keys).uniq.reject(&:empty?)
      all_owners.map do |owner|
        first_meth = methods_by_owner[owner]&.first
        first_field = Array(evidence["fields"]).find { |f| f["owner"] == owner }

        file = first_meth ? first_meth[:file] : (first_field ? first_field["path"] : nil)
        language = first_meth ? first_meth[:language] : (first_field ? first_field["language"]&.to_sym : nil)

        {
          type: :class,
          name: owner,
          file: file,
          line: first_meth ? first_meth[:line] : (first_field ? first_field["line"] : 1),
          span: first_meth ? first_meth[:span] : (first_field ? first_field["span"] : nil),
          language: language,
          states: fields_by_owner[owner].to_set,
          ivar_types: {},
          ivar_properties: {},
          methods: methods_by_owner[owner]
        }
      end
    end


    def initialize(targets = nil, root: Espalier::ROOT, language: nil, vcs: nil, include_annotations: true)
      @targets = Array(targets).compact
      @root = root
      @language = normalize_language(language)
      @vcs = normalize_vcs(vcs)
      @include_annotations = include_annotations
    end

    def build
      files = target_files
      return empty_evidence if files.empty?

      profile = @include_annotations ? "nil-kill" : "espalier"
      tmp = Tempfile.new(["espalier-rust-facts", ".json"])
      tmp.close

      args = [FACT_MINE_RUST_BINARY, "profile", profile, "--output", tmp.path, *files]
      ok = system(*args)
      raise "fact-mine-rust failed with exit status #{$?.exitstatus}" unless ok

      facts_by_file = JSON.parse(File.read(tmp.path))
      build_from_rust_facts(facts_by_file, files)
    ensure
      tmp&.unlink
    end

    private

    def build_from_rust_facts(facts_by_file, files)
      methods = Array(facts_by_file["methods"])
      fields = Array(facts_by_file["fields"])
      state_types = facts_by_file["state_types"] || {}
      struct_declarations = Array(facts_by_file["struct_declarations"])
      state_type_records = Array(facts_by_file["state_type_records"])
      state_protocols = facts_by_file["state_protocols"] || {}
      state_param_origins_in = facts_by_file["state_param_origins"] || {}
      state_protocol_records = Array(facts_by_file["state_protocol_records"])
      state_param_origin_records = Array(facts_by_file["state_param_origin_records"])
      signatures = facts_by_file["signatures"] || {}
      type_definitions = Array(facts_by_file["type_definitions"])
      hash_shapes = Array(facts_by_file["hash_shapes"])
      array_shapes = Array(facts_by_file["array_shapes"])
      collection_index_lookups = Array(facts_by_file["collection_index_lookups"])
      hash_record_blockers = Array(facts_by_file["hash_record_blockers"])
      tlet_sites = Array(facts_by_file["tlet_sites"])
      dead_nil_checks = Array(facts_by_file["dead_nil_checks"])
      deterministic_guards = Array(facts_by_file["deterministic_guards"])
      return_origins = Array(facts_by_file["return_origins"])
      noreturn_methods = Array(facts_by_file["noreturn_methods"])

      type_definitions.concat(ruby_annotation_type_definitions(files)) if @include_annotations

      state_protocols_map = Hash.new { |h, k| h[k] = Set.new }
      merge_set_map!(state_protocols_map, state_protocols)
      state_protocols = stringify_set_map(state_protocols_map)

      state_param_origins_map = Hash.new { |h, k| h[k] = Set.new }
      merge_set_map!(state_param_origins_map, state_param_origins_in)
      state_param_origins = stringify_set_map(state_param_origins_map)

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
          "state_type_records" => state_type_records.sort_by { |r| [r["language"].to_s, r["path"].to_s, r["owner"].to_s, r["field"].to_s] },
          "state_protocols" => state_protocols,
          "state_param_origins" => state_param_origins,
          "state_protocol_records" => state_protocol_records.sort_by { |r| [r["language"].to_s, r["path"].to_s, r["owner"].to_s, r["field"].to_s, r["protocol"].to_s] },
          "state_param_origin_records" => state_param_origin_records.sort_by { |r| [r["language"].to_s, r["path"].to_s, r["owner"].to_s, r["field"].to_s, r["param"].to_s] },
          "signatures" => Hash[signatures.sort],
          "type_definitions" => type_definitions.sort_by { |d| [d["path"].to_s, d["owner"].to_s, d["kind"].to_s, d["name"].to_s] },
          "alias_recommendations" => alias_recommendations,
          "struct_declarations" => struct_declarations.sort_by { |decl| [decl["path"].to_s, decl["class"].to_s] },
          "hash_shapes" => hash_shapes.sort_by { |shape| [shape["path"].to_s, shape["line"].to_i, shape["keys"].to_s] },
          "array_shapes" => array_shapes.sort_by { |shape| [shape["path"].to_s, shape["line"].to_i, shape["tuple_types"].to_s] },
          "collection_index_lookups" => collection_index_lookups.sort_by { |l| [l["path"].to_s, l["line"].to_i, l["code"].to_s] },
          "hash_record_blockers" => hash_record_blockers.sort_by { |b| [b["path"].to_s, b["line"].to_i, b["kind"].to_s] },
          "tlet_sites" => tlet_sites.sort_by { |site| [site["path"].to_s, site["line"].to_i] },
          "dead_nil_checks" => dead_nil_checks.sort_by { |f| [f["path"].to_s, f["line"].to_i, f["kind"].to_s] },
          "deterministic_guards" => deterministic_guards.sort_by { |f| [f["path"].to_s, f["line"].to_i, f["code"].to_s] },
          "return_origins" => return_origins.sort_by { |o| [o["path"].to_s, o["line"].to_i, o["method"].to_s] },
          "noreturn_methods" => noreturn_methods.sort_by { |m| [m["path"].to_s, m["owner"].to_s, m["name"].to_s] },
          "rbi_field_types" => rbi_field_types.sort_by { |r| [r["class"].to_s, r["field"].to_s] },
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
          "collection_index_lookups" => collection_index_lookups.size,
          "hash_record_blockers" => hash_record_blockers.size,
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

    def empty_evidence
      {
        "version" => 2,
        "schema_version" => 2,
        "kind" => "espalier_static_evidence",
        "parser" => "tree_sitter",
        "generated_at" => Time.now.utc.iso8601,
        "root" => @root,
        "target_dirs" => target_dirs.map { |dir| rel(dir) },
        "target_exclude_dirs" => Espalier.target_exclude_dirs(root: @root).map { |dir| rel(dir) },
        "runtime_fields" => false,
        "files" => [],
        "fields" => [],
        "methods" => [],
        "facts" => {},
        "summary" => { "files" => 0 },
        "language_capabilities" => {},
      }
    end

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
        profile_for_rbi_file(file)
      end
    end

    def profile_for_rbi_file(file)
      tmp = Tempfile.new(["espalier-rbi-facts", ".json"])
      tmp.close
      ok = system(FACT_MINE_RUST_BINARY, "profile", "nil-kill", "--output", tmp.path, file)
      return [] unless ok

      JSON.parse(File.read(tmp.path)).fetch("type_definitions", [])
    rescue StandardError
      []
    ensure
      tmp&.unlink
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