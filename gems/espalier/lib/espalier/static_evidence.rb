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
      File.join(Espalier::ROOT, "gems", "fact-mine", "target", "release", "fact-mine-rust")
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
      first_field_by_owner = {}
      Array(evidence["fields"]).each do |f|
        fields_by_owner[f["owner"]] << f["name"]
        first_field_by_owner[f["owner"]] ||= f
      end

      # Index call graph edges (internal calls)
      internal_calls = Hash.new { |h, k| h[k] = [] }
      Array(evidence.dig("facts", "call_graph_edges")).each do |edge|
        next unless edge["kind"] == "internal_call"
        if edge["source"] =~ /^fn:(.+)#(.+)$/
          edge_owner, func = $1, $2
          if edge["target"] =~ /^fn:.+#(.+)$/
            target_func = $1
            internal_calls["#{edge_owner}##{func}"] << {
              receiver: "self",
              message: target_func,
              type: edge["conditional"] ? :conditional : :always
            }
          end
        end
      end

      # Map state protocols and param origins to reads/writes and delegations
      Array(evidence.dig("facts", "state_protocol_records")).each do |record|
        p_owner = record["owner"]
        func = record["function"]
        field = record["field"]
        proto = record["protocol"]

        meths = methods_by_owner[p_owner] || []
        meth = meths.find { |m_item| m_item[:name] == func }
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
        o_owner = record["owner"]
        func = record["function"]
        field = record["field"]

        meths = methods_by_owner[o_owner] || []
        meth = meths.find { |m_item| m_item[:name] == func }
        if meth
          meth[:effects][:writes].add(field)
        end
      end

      # Add internal call delegations
      methods_by_owner.each do |m_owner, meths|
        meths.each do |meth|
          key = "#{m_owner}##{meth[:name]}"
          meth[:delegations].concat(internal_calls[key]) if internal_calls[key]
          meth[:delegations].uniq!
        end
      end

      # Construct modules array
      all_owners = (methods_by_owner.keys + fields_by_owner.keys).uniq.reject(&:empty?)
      all_owners.map do |owner|
        meta = module_metadata(owner, methods_by_owner[owner], first_field_by_owner[owner])
        {
          type: :class,
          name: owner,
          file: meta[:file],
          line: meta[:line],
          span: meta[:span],
          language: meta[:language],
          states: fields_by_owner[owner].to_set,
          ivar_types: {},
          ivar_properties: {},
          methods: methods_by_owner[owner]
        }
      end
    end

    def self.module_metadata(owner, methods, first_field)
      first_meth = methods&.first
      {
        file: first_meth ? first_meth[:file] : (first_field ? first_field["path"] : nil),
        language: first_meth ? first_meth[:language] : (first_field ? first_field["language"]&.to_sym : nil),
        line: first_meth ? first_meth[:line] : (first_field ? first_field["line"] : 1),
        span: first_meth ? first_meth[:span] : (first_field ? first_field["span"] : nil)
      }
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

      if ENV["FACT_MINE_FACTS_FILE"] && !ENV["FACT_MINE_FACTS_FILE"].empty?
        facts_by_file = FactMine::Syntax::TypeExpr.wrap_types!(JSON.parse(File.read(ENV["FACT_MINE_FACTS_FILE"])))
        return build_from_rust_facts(facts_by_file, files)
      end

      profile = @include_annotations ? "nil-kill" : "espalier"
      tmp = Tempfile.new(["espalier-rust-facts", ".json"])
      tmp.close

      args = [FACT_MINE_RUST_BINARY, "profile", profile, "--output", tmp.path]
      args.concat(["--language", @language.to_s]) if @language
      args.concat(files)
      ok = system(*args)
      raise "fact-mine-rust failed with exit status #{$?.exitstatus}" unless ok

      facts_by_file = FactMine::Syntax::TypeExpr.wrap_types!(JSON.parse(File.read(tmp.path)))
      build_from_rust_facts(facts_by_file, files)
    ensure
      tmp&.unlink
    end

    private

    def build_from_rust_facts(facts_by_file, files)
      raw_type_defs = Array(facts_by_file["type_definitions"])
      raw_type_defs.concat(ruby_annotation_type_definitions(files)) if @include_annotations

      state_protocols = normalize_state_protocols(facts_by_file)
      state_param_origins = normalize_state_param_origins(facts_by_file)

      deduped = deduplicate_facts(facts_by_file, raw_type_defs)
      build_payload(facts_by_file, files, deduped, state_protocols, state_param_origins)
    end

    def normalize_state_protocols(facts)
      state_protocols = facts["state_protocols"] || facts["ivar_protocols"] || {}
      state_protocols_map = Hash.new { |h, k| h[k] = Set.new }
      merge_set_map!(state_protocols_map, state_protocols)
      stringify_set_map(state_protocols_map)
    end

    def normalize_state_param_origins(facts)
      state_param_origins_in = facts["state_param_origins"] || facts["ivar_param_origins"] || {}
      state_param_origins_map = Hash.new { |h, k| h[k] = Set.new }
      merge_set_map!(state_param_origins_map, state_param_origins_in)
      stringify_set_map(state_param_origins_map)
    end

    def deduplicate_facts(facts, type_definitions)
      {
        state_type_records: Array(facts["state_type_records"]).uniq do |r|
          [r["language"], r["path"], r["owner"], r["field"], r["declared_type"], r["line"]]
        end,
        state_protocol_records: Array(facts["state_protocol_records"]).uniq do |r|
          [r["language"], r["path"], r["owner"], r["function"], r["field"], r["protocol"], r["line"]]
        end,
        state_param_origin_records: Array(facts["state_param_origin_records"]).uniq do |r|
          [r["language"], r["path"], r["owner"], r["function"], r["field"], r["param"], r["line"]]
        end,
        type_definitions: type_definitions.uniq do |d|
          [d["language"], d["path"], d["owner"], d["kind"], d["name"], d["line"], d["type_system"]]
        end,
        struct_declarations: Array(facts["struct_declarations"]).uniq do |d|
          [d["path"], d["class"], Array(d["fields"])]
        end,
        hash_shapes: Array(facts["hash_shapes"]).uniq do |s|
          [s["path"], s["line"], Array(s["keys"]), Array(s["value_types"])]
        end,
        array_shapes: Array(facts["array_shapes"]).uniq do |s|
          [s["path"], s["line"], Array(s["tuple_types"]), s["size"]]
        end
      }
    end

    def build_payload(facts, files, deduped, state_protocols, state_param_origins)
      methods = Array(facts["methods"])
      fields = Array(facts["fields"])
      state_types = facts["state_types"] || {}
      signatures = facts["signatures"] || {}
      collection_index_lookups = Array(facts["collection_index_lookups"])
      hash_record_blockers = Array(facts["hash_record_blockers"])
      tlet_sites = Array(facts["tlet_sites"])
      dead_nil_checks = Array(facts["dead_nil_checks"])
      deterministic_guards = Array(facts["deterministic_guards"])
      return_origins = Array(facts["return_origins"])
      param_origins = Array(facts["param_origins"])
      noreturn_methods = Array(facts["noreturn_methods"])
      hash_record_escape_sites = Array(facts["hash_record_escape_sites"])
      type_normalizers = Array(facts["type_normalizers"])
      rescue_handlers = Array(facts["rescue_handlers"])
      return_usage_sites = Array(facts["return_usage_sites"])
      return_direct_usage_sites = Array(facts["return_direct_usage_sites"])
      hidden_enum_observations = Array(facts["hidden_enum_observations"])
      dispatcher_inferences = Array(facts["dispatcher_inferences"])
      hash_record_member_calls = Array(facts["hash_record_member_calls"])

      # Collect languages of owners to know if they need @ prepended for fields
      owner_languages = {}
      fields.each do |f|
        owner_languages[f["owner"]] = f["language"] if f["owner"] && f["language"]
      end
      methods.each do |m|
        owner_languages[m["owner"]] = m["language"] if m["owner"] && m["language"]
      end

      # Homogeneous project language default
      project_languages = files.map { |f| normalize_language(TreeSitter.language_for(f)) }.compact.uniq
      default_lang = project_languages.size == 1 ? project_languages.first.to_s : nil

      normalize_key = ->(key) do
        klass, field = key.split("\u0000", 2)
        if klass && field && !field.start_with?("@")
          lang = owner_languages[klass] || default_lang
          if %w[ruby python javascript typescript].include?(lang.to_s)
            "#{klass}\u0000@#{field}"
          else
            key
          end
        else
          key
        end
      end

      # Normalize state_types keys
      normalized_state_types = {}
      state_types.each do |key, val|
        normalized_state_types[normalize_key.call(key)] = val
      end
      state_types = normalized_state_types

      # Normalize state_protocols keys
      normalized_state_protocols = {}
      state_protocols.each do |key, val|
        normalized_state_protocols[normalize_key.call(key)] = val
      end
      state_protocols = normalized_state_protocols

      # Normalize state_param_origins keys
      normalized_state_param_origins = {}
      state_param_origins.each do |key, val|
        normalized_state_param_origins[normalize_key.call(key)] = val
      end
      state_param_origins = normalized_state_param_origins

      type_defs = deduped[:type_definitions]
      alias_recommendations = AliasRecommendations.build(type_definitions: type_defs)
      typed_signature_count = type_defs.count { |definition| definition["kind"] == "method_signature" }
      rbi_field_types = rbi_field_type_records(type_defs)

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
          "state_type_records" => deduped[:state_type_records].sort_by { |r| [r["language"].to_s, r["path"].to_s, r["owner"].to_s, r["field"].to_s] },
          "state_protocols" => state_protocols,
          "state_param_origins" => state_param_origins,
          "state_protocol_records" => deduped[:state_protocol_records].sort_by { |r| [r["language"].to_s, r["path"].to_s, r["owner"].to_s, r["field"].to_s, r["protocol"].to_s] },
          "state_param_origin_records" => deduped[:state_param_origin_records].sort_by { |r| [r["language"].to_s, r["path"].to_s, r["owner"].to_s, r["field"].to_s, r["param"].to_s] },
          "signatures" => Hash[signatures.sort],
          "type_definitions" => type_defs.sort_by { |d| [d["path"].to_s, d["owner"].to_s, d["kind"].to_s, d["name"].to_s] },
          "alias_recommendations" => alias_recommendations,
          "struct_declarations" => deduped[:struct_declarations].sort_by { |decl| [decl["path"].to_s, decl["class"].to_s] },
          "hash_shapes" => deduped[:hash_shapes].sort_by { |shape| [shape["path"].to_s, shape["line"].to_i, shape["keys"].to_s] },
          "array_shapes" => deduped[:array_shapes].sort_by { |shape| [shape["path"].to_s, shape["line"].to_i, shape["tuple_types"].to_s] },
          "collection_index_lookups" => collection_index_lookups.sort_by { |l| [l["path"].to_s, l["line"].to_i, l["code"].to_s] },
          "hash_record_blockers" => hash_record_blockers.sort_by { |b| [b["path"].to_s, b["line"].to_i, b["kind"].to_s] },
          "tlet_sites" => tlet_sites.sort_by { |site| [site["path"].to_s, site["line"].to_i] },
          "dead_nil_checks" => dead_nil_checks.sort_by { |f| [f["path"].to_s, f["line"].to_i, f["kind"].to_s] },
          "deterministic_guards" => deterministic_guards.sort_by { |f| [f["path"].to_s, f["line"].to_i, f["code"].to_s] },
          "return_origins" => return_origins.sort_by { |o| [o["path"].to_s, o["line"].to_i, o["method"].to_s] },
          "param_origins" => param_origins.sort_by { |o| [o["path"].to_s, o["line"].to_i, o["callee"].to_s] },
          "noreturn_methods" => noreturn_methods.sort_by { |m| [m["path"].to_s, m["owner"].to_s, m["name"].to_s] },
          "hash_record_escape_sites" => hash_record_escape_sites.sort_by { |s| [s["path"].to_s, s["line"].to_i] },
          "rbi_field_types" => rbi_field_types.sort_by { |r| [r["class"].to_s, r["field"].to_s] },
          "ivar_runtime" => [],
          "ivar_protocols" => state_protocols,
          "ivar_param_origins" => state_param_origins,
          "type_normalizers" => type_normalizers.sort_by { |f| [f["path"].to_s, f["line"].to_i] },
          "rescue_handlers" => rescue_handlers.sort_by { |f| [f["path"].to_s, f["line"].to_i] },
          "return_usage_sites" => return_usage_sites.sort_by { |f| [f["path"].to_s, f["line"].to_i] },
          "return_direct_usage_sites" => return_direct_usage_sites.sort_by { |f| [f["path"].to_s, f["line"].to_i] },
          "hidden_enum_observations" => hidden_enum_observations.sort_by { |f| [f["path"].to_s, f["line"].to_i] },
          "dispatcher_inferences" => dispatcher_inferences.sort_by { |f| [f["path"].to_s, f["line"].to_i] },
          "hash_record_member_calls" => hash_record_member_calls.sort_by { |f| [f["path"].to_s, f["line"].to_i] },
          "struct_field_hash_shapes" => facts["struct_field_hash_shapes"] || {},
          "struct_field_array_shapes" => facts["struct_field_array_shapes"] || {},
        },
        "summary" => {
          "files" => files.size,
          "methods" => methods.size,
          "fields" => fields.uniq { |field| field["id"] }.size,
          "signatures" => typed_signature_count,
          "state_types" => state_types.size,
          "state_type_records" => deduped[:state_type_records].size,
          "state_protocols" => state_protocols.size,
          "state_param_origins" => state_param_origins.size,
          "state_protocol_records" => deduped[:state_protocol_records].size,
          "state_param_origin_records" => deduped[:state_param_origin_records].size,
          "type_definitions" => type_defs.size,
          "alias_recommendations" => alias_recommendations.size,
          "struct_declarations" => deduped[:struct_declarations].size,
          "hash_shapes" => deduped[:hash_shapes].size,
          "array_shapes" => deduped[:array_shapes].size,
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
      return [] if ENV["FACT_MINE_FACTS_FILE"] && !ENV["FACT_MINE_FACTS_FILE"].empty?
      return [] unless @include_annotations
      return [] unless ruby_annotation_index?(files)

      ruby_annotation_files.flat_map do |file|
        profile_for_rbi_file(file)
      end
    end

    def profile_for_rbi_file(file)
      tmp = Tempfile.new(["espalier-rbi-facts", ".json"])
      tmp.close
      ok = system(FACT_MINE_RUST_BINARY, "profile", "nil-kill", "--language", "ruby", "--output", tmp.path, file)
      return [] unless ok

      FactMine::Syntax::TypeExpr.wrap_types!(JSON.parse(File.read(tmp.path))).fetch("type_definitions", [])
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

    def ruby_rbi_definition?(definition)
      definition["language"].to_s == "ruby" &&
        definition["kind"].to_s == "method_signature" &&
        definition["path"].to_s.end_with?(".rbi")
    end

    def rbi_field_type_records(type_definitions)
      Array(type_definitions).filter_map do |definition|
        next unless ruby_rbi_definition?(definition)

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