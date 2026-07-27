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

    def self.build(targets = nil, root: Espalier::ROOT, language: nil, vcs: nil, include_annotations: true, scip_indexes: [], complexity_summaries: [])
      new(targets, root: root, language: language, vcs: vcs, include_annotations: include_annotations, scip_indexes: scip_indexes, complexity_summaries: complexity_summaries).build
    end

    def self.project_modules(evidence, source_roles: ["production"])
      return [] unless evidence && evidence["methods"]

      input_boundary = proof_boundary_from_input_coverage(evidence["input_coverage"])
      allowed_roles = Array(source_roles).map(&:to_s).to_set
      roles_by_path = Array(evidence["files"]).each_with_object({}) do |file, roles|
        path = file["path"].to_s
        role = file["source_role"] || source_role(path)
        roles[path] = role
        roles[File.expand_path(path, evidence["root"])] = role if evidence["root"]
      end
      role_for = ->(path) { roles_by_path.fetch(path.to_s) { source_role(path) } }

      resolve_owner = ->(owner, path, language) {
        lang = language.to_s.downcase
        # A source file is part of an owner identity in languages that permit
        # unrelated modules/classes with the same short name. Without it,
        # parallel TS/JS version trees (and native compilation units) are
        # merged into a fictional class and produce false state/complexity
        # claims. Deliberate declaration merging remains an explicit future
        # relation, never an accidental name collision.
        if lang == "rust" || lang == "go" || lang == "zig" || lang == "c" || lang == "cpp" || lang == "csharp" || lang == "typescript" || lang == "javascript"
          "#{owner}@#{path}"
        else
          owner
        end
      }

      # Group methods by owner
      methods_by_owner = Hash.new { |h, k| h[k] = [] }
      methods_by_id = {}
      owner_definitions = Array(evidence["owners"]).each_with_object(Hash.new { |h, k| h[k] = [] }) do |owner, definitions|
        key = resolve_owner.call(owner["name"], owner["path"], owner["language"])
        definitions[key] << owner
      end
      owner_definitions.transform_values! { |definitions| preferred_owner_definition(definitions) }
      owner_kinds = owner_definitions.transform_values { |owner| owner["kind"].to_s }
      accesses_by_function = Hash.new { |h, k| h[k] = [] }
      Array(evidence.dig("facts", "state_accesses")).each do |access|
        accesses_by_function[access["function_id"]] << access
      end
      complexity_by_method = Hash.new { |h, k| h[k] = [] }
      Array(evidence.dig("facts", "complexity_facts")).each do |fact|
        key = [fact["path"], fact["owner"], fact["function"], fact["line"].to_i]
        complexity_by_method[key] << fact
      end
      raw_methods = Array(evidence["methods"])
      implementation_keys = raw_methods.filter_map do |method|
        source = method["raw_source"].to_s
        next unless source.include?("{")

        [method["path"].to_s, method["owner"].to_s, method["name"].to_s, method["kind"].to_s]
      end.to_set
      raw_methods.each do |m|
        next unless allowed_roles.include?(role_for.call(m["path"]))
        overload_key = [m["path"].to_s, m["owner"].to_s, m["name"].to_s, m["kind"].to_s]
        # TypeScript overload signatures are declarations immediately followed
        # by a concrete implementation. Reporting both as executable methods
        # doubles every downstream metric; retain the implementation only.
        if implementation_keys.include?(overload_key) && !m["raw_source"].to_s.include?("{")
          next
        end
        accesses = accesses_by_function[m["id"]]
        meth = {
          id: m["id"],
          owner_id: m["owner_id"],
          raw_owner: m["owner"],
          name: m["name"],
          dispatch_name: m["dispatch_name"] || m["name"],
          dispatch_kind: m["kind"],
          signature: m["signature"],
          parameters: Array(m["params"]),
          visibility: (m["visibility"] || :public).to_sym,
          callback_params: Array(m["callback_params"]).map(&:to_s),
          line: m["line"]&.to_i,
          span: m["span"],
          file: m["path"],
          language: m["language"]&.to_sym,
          complexity_facts: complexity_by_method[[m["path"], m["owner"], m["name"], m["line"].to_i]],
          effects: {
            reads: accesses.select { |row| row["kind"] == "reads" }.map { |row| row["field"] }.to_set,
            writes: accesses.select { |row| row["kind"] == "writes" }.map { |row| row["field"] }.to_set
          },
          delegations: []
        }
        owner_key = resolve_owner.call(m["owner"], m["path"], m["language"])
        meth[:projected_owner] = owner_key
        methods_by_owner[owner_key] << meth
        methods_by_id[m["id"]] = meth
      end

      constant_operations = Hash.new { |hash, owner| hash[owner] = Set.new }
      Array(evidence.dig("facts", "struct_declarations")).each do |declaration|
        constant_operations[declaration["class"].to_s].merge(Array(declaration["constant_operations"]).map(&:to_s))
      end
      declared_operations = methods_by_id.each_value.each_with_object(Set.new) do |method, operations|
        operations << [method[:raw_owner].to_s, method[:dispatch_name].to_s]
      end

      # Group fields by owner
      fields_by_owner = Hash.new { |h, k| h[k] = [] }
      first_field_by_owner = {}
      Array(evidence["fields"]).each do |f|
        next unless allowed_roles.include?(role_for.call(f["path"]))
        owner_key = resolve_owner.call(f["owner"], f["path"], f["language"])
        fields_by_owner[owner_key] << f
        first_field_by_owner[owner_key] ||= f
      end

      # Index call graph edges (internal calls)
      internal_calls = Hash.new { |h, k| h[k] = [] }
      Array(evidence.dig("facts", "calls")).each do |call|
        source = methods_by_id[call["source"]]
        next unless source

        target = methods_by_id[call["target"]]
        receiver = call["receiver"].to_s
        implicit_receiver = receiver.empty? || receiver == "self" || receiver == "this"
        # FactMine is the semantic authority for target identity. Rebuilding
        # dispatch here from short owner names, capitalization, or flow-type
        # strings silently crosses package and language boundaries.
        operation_owner = implicit_receiver ? source[:raw_owner].to_s : call["receiver"].to_s
        known_time = call["known_time_complexity"]
        known_space = call["known_space_complexity"]
        if !target && operation_owner &&
            !declared_operations.include?([operation_owner, call["message"].to_s]) &&
            constant_operations[operation_owner].include?(call["message"].to_s)
          known_time ||= "O(1)"
          known_space ||= "O(1)"
        end
        source[:delegations] << {
          receiver: call["receiver"].to_s.empty? ? "self" : call["receiver"],
          message: call["message"],
          line: call["line"]&.to_i,
          span: call["span"],
          type: call["conditional"] ? :conditional : :always,
          confidence: call["confidence"],
          unresolved_reason: (target || known_time || known_space) ? nil : call["unresolved_reason"],
          call_id: call["id"],
          arguments: Array(call["arguments"]).map(&:to_s),
          target_id: target && target[:id],
          target_owner: target && target[:projected_owner],
          target_method: target && target[:name],
          semantic_symbol: call["semantic_symbol"],
          target_provenance: call["target_provenance"],
          candidate_target_ids: Array(call["candidate_targets"]),
          candidate_reason: call["candidate_reason"],
          complexity_provenance: call["complexity_provenance"],
          complexity_bound_quality: call["complexity_bound_quality"],
          complexity_candidates: Array(call["complexity_candidates"]),
          complexity_assumptions: Array(call["complexity_assumptions"]),
          state_receiver: call["state_receiver"] == true,
          known_time_complexity: known_time,
          known_space_complexity: known_space
        }
        if target
          source[:delegations].last[:confidence] = "high"
        end
      end

      calls_by_source = Array(evidence.dig("facts", "calls")).group_by { |call| call["source"].to_s }
      methods_by_id.each do |method_id, method|
        calls = Array(calls_by_source[method_id.to_s])
        method[:semantic_call_identity_complete] = calls.any? && calls.all? do |call|
          call["target_provenance"] == "scip" && !call["semantic_symbol"].to_s.empty?
        end
      end

      # Map state protocols and param origins to reads/writes and delegations
      Array(evidence.dig("facts", "state_protocol_records")).each do |record|
        p_owner = record["owner"]
        func = record["function"]
        field = record["field"]
        proto = record["protocol"]

        owner_key = resolve_owner.call(p_owner, record["path"], record["language"])
        meths = methods_by_owner[owner_key] || []
        candidates = meths.select { |m_item| m_item[:name] == func }
        record_line = record["line"].to_i
        meth = candidates.find do |candidate|
          span = candidate[:span]
          span.is_a?(Array) && record_line >= span[0].to_i && record_line <= span[2].to_i
        end
        meth ||= candidates.first if candidates.one?
        if meth
          duplicate = Array(meth[:delegations]).any? do |delegation|
            same_span = delegation[:span].is_a?(Array) && record["span"].is_a?(Array) &&
              delegation[:span].map(&:to_i) == record["span"].map(&:to_i)
            receiver = delegation[:receiver].to_s
            canonical_receiver = if delegation[:state_receiver]
                                   receiver.split(".").last.to_s.delete_prefix("@")
                                 else
                                   receiver
                                 end
            delegation[:message].to_s == proto.to_s &&
              (same_span || (canonical_receiver == field.to_s.delete_prefix("@") &&
                delegation[:line].to_i == record_line))
          end
          next if duplicate

          meth[:delegations] << {
            receiver: field,
            message: proto,
            line: record["line"]&.to_i,
            type: :always
          }
        end
      end

      Array(evidence.dig("facts", "state_param_origin_records")).each do |record|
        o_owner = record["owner"]
        func = record["function"]
        field = record["field"]

        owner_key = resolve_owner.call(o_owner, record["path"], record["language"])
        meths = methods_by_owner[owner_key] || []
        candidates = meths.select { |m_item| m_item[:name] == func }
        record_line = record["line"].to_i
        meth = candidates.find do |candidate|
          span = candidate[:span]
          span.is_a?(Array) && record_line >= span[0].to_i && record_line <= span[2].to_i
        end
        meth ||= candidates.first if candidates.one?
        meth # parameter origin is metadata, not proof of a write
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
      declared_fields = Hash.new { |hash, owner| hash[owner] = Set.new }
      Array(evidence.dig("facts", "struct_declarations")).each do |declaration|
        Array(declaration["fields"]).each do |field|
          declared_fields[declaration["class"]] << field.to_s.delete_prefix("@")
        end
      end
      all_owners = (methods_by_owner.keys + fields_by_owner.keys).uniq.reject(&:empty?)
      all_owners.map do |owner|
        meta = module_metadata(owner, methods_by_owner[owner], first_field_by_owner[owner], owner_definitions.fetch(owner, nil))
        owner_kind = owner_kinds[owner]
        # Extensions, protocols, traits, and interfaces can contribute
        # behavior, but do not introduce independently-owned mutable stored
        # state. Treating them as lifecycle classes produces unsafe advice in
        # Swift and the same mistake in every other language with those forms.
        module_like = %w[module program namespace extension protocol trait interface].include?(owner_kind) ||
          (%i[javascript typescript].include?(meta[:language]) && owner_kind == "owner")
        {
          type: module_like ? :module : :class,
          name: owner,
          file: meta[:file],
          line: meta[:line],
          span: meta[:span],
          language: meta[:language],
          states: module_like ? Set.new : fields_by_owner[owner].map { |field| field["name"] }.to_set,
          state_records: module_like ? [] : fields_by_owner[owner],
          ivar_types: module_like ? {} : fields_by_owner[owner].to_h { |field| [field["name"], field["declared_type"]] }.compact,
          ivar_properties: {},
          declared_fields: declared_fields,
          proof_boundary: input_boundary,
          methods: methods_by_owner[owner]
        }
      end
    end

    # Corpus completeness belongs to the extractor, not to a later report
    # formatter. Keep the narrow input dimension alongside every projected
    # module so downstream analyses can preserve it without guessing from
    # their own estimate-specific flags.
    def self.proof_boundary_from_input_coverage(coverage)
      coverage = Hash(coverage || {})
      complete = coverage["complete"]
      reason = coverage["reason"].to_s
      if complete == true
        { input_completeness: "complete", input_blockers: [] }
      elsif complete == false
        # Input-coverage prose is retained elsewhere for humans; the shared
        # proof contract transports only its canonical machine-readable kind.
        { input_completeness: "partial", input_blockers: [{ "kind" => "missing_evidence" }] }
      else
        { input_completeness: "unknown", input_blockers: [] }
      end
    end

    def self.module_metadata(owner, methods, first_field, owner_definition = nil)
      first_meth = methods&.first
      {
        file: owner_definition ? owner_definition["path"] : (first_meth ? first_meth[:file] : (first_field ? first_field["path"] : nil)),
        language: first_meth ? first_meth[:language] : (first_field ? first_field["language"]&.to_sym : nil),
        line: owner_definition ? owner_definition["line"] : (first_meth ? first_meth[:line] : (first_field ? first_field["line"] : 1)),
        span: owner_definition ? owner_definition["span"] : (first_meth ? first_meth[:span] : (first_field ? first_field["span"] : nil))
      }
    end

    def self.preferred_owner_definition(definitions)
      definitions.min_by do |owner|
        [owner_definition_rank(owner["kind"]), owner["path"].to_s, owner["line"].to_i]
      end
    end

    def self.owner_definition_rank(kind)
      case kind.to_s
      when "class", "struct", "enum"
        0
      when "protocol", "interface", "trait"
        1
      when "extension"
        2
      else
        3
      end
    end

    def self.source_role(path)
      text = path.to_s.tr("\\", "/")
      parts = text.split("/").reject(&:empty?).map(&:downcase)
      basename = parts.last.to_s
      return "vcs_metadata" if (parts & %w[.git .hg .svn]).any?
      return "vendored" if (parts & %w[vendor vendors third_party third-party]).any?
      return "generated" if (parts & %w[generated gen dist]).any?
      return "benchmark" if (parts & %w[benchmark benchmarks bench benches]).any?
      return "example" if (parts & %w[example examples sample samples]).any?
      return "test" if (parts & %w[test tests spec specs __tests__ jvmtest androidtest commontest nativetest nonwasmtest wasmtest integrationtest unittest uitest functionaltest]).any?
      return "test" if parts.any? { |part| part.end_with?("test") && part.match?(/\A(?:android|common|functional|integration|jvm|native|nonwasm|unit|ui|wasm)/) }
      return "test" if basename.match?(/(?:\A|[_\.])test(?:[_\.]|\z)|(?:\A|[_\.])spec(?:[_\.]|\z)/)
      # Test-helper products are executable support code, not production
      # library surface. Match common portable path spellings, including the
      # Swift Package Manager `ArgumentParserTestHelpers` convention.
      return "test" if parts.any? { |part| part.match?(/test(?:_|-)?(?:helpers?|support)/i) }

      "production"
    end


    def initialize(targets = nil, root: Espalier::ROOT, language: nil, vcs: nil, include_annotations: true, scip_indexes: [], complexity_summaries: [])
      @targets = Array(targets).compact
      @root = root
      @language = normalize_language(language)
      @vcs = normalize_vcs(vcs)
      @include_annotations = include_annotations
      @scip_indexes = Array(scip_indexes).compact
      @complexity_summaries = Array(complexity_summaries).compact
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
      @scip_indexes.each { |index| args.concat(["--scip-index", index.to_s]) }
      @complexity_summaries.each { |summary| args.concat(["--complexity-summary", summary.to_s]) }
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
      owners = Array(facts["owners"])
      methods = Array(facts["methods"])
      fields = Array(facts["fields"])
      state_types = facts["state_types"] || {}
      signatures = facts["signatures"] || {}
      calls = Array(facts["calls"])
      call_resolution_coverage = Hash(facts["call_resolution_coverage"])
      state_accesses = Array(facts["state_accesses"])
      call_graph_edges = Array(facts["call_graph_edges"])
      state_type_edges = Array(facts["state_type_edges"])
      collection_index_lookups = Array(facts["collection_index_lookups"])
      hash_record_blockers = Array(facts["hash_record_blockers"])
      tlet_sites = Array(facts["tlet_sites"])
      dead_nil_checks = Array(facts["dead_nil_checks"])
      deterministic_guards = Array(facts["deterministic_guards"])
      return_origins = Array(facts["return_origins"])
      param_origins = Array(facts["param_origins"])
      noreturn_methods = Array(facts["noreturn_methods"])
      hash_record_escape_sites = Array(facts["hash_record_escape_sites"])
      hazard_sites = Array(facts["hazard_sites"])
      type_normalizers = Array(facts["type_normalizers"])
      rescue_handlers = Array(facts["rescue_handlers"])
      return_usage_sites = Array(facts["return_usage_sites"])
      return_direct_usage_sites = Array(facts["return_direct_usage_sites"])
      hidden_enum_observations = Array(facts["hidden_enum_observations"])
      nullable_refinements = Array(facts["nullable_refinements"])
      nullable_states = Array(facts["nullable_states"])
      nullable_summaries = Array(facts["nullable_summaries"])
      nullable_operations = Array(facts["nullable_operations"])
      presence_correlations = Array(facts["presence_correlations"])
      dispatcher_inferences = Array(facts["dispatcher_inferences"])
      hash_record_member_calls = Array(facts["hash_record_member_calls"])
      complexity_facts = Array(facts["complexity_facts"])
      flow_local_types = Array(facts["flow_local_types"]).uniq do |fact|
        [fact["file"], fact["function"], fact["node_id"], fact["place_id"]]
      end
      type_dependencies = Array(facts["type_dependencies"]).uniq { |fact| fact["id"] }

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
        "languages" => project_languages.map(&:to_s),
        "target_dirs" => target_dirs.map { |dir| rel(dir) },
        "target_exclude_dirs" => Espalier.target_exclude_dirs(root: @root).map { |dir| rel(dir) },
        "input_coverage" => input_coverage_metadata(facts),
        "corpus" => corpus_metadata,
        "runtime_fields" => false,
        "files" => files.map { |file| file_record(file) },
        "owners" => owners.sort_by { |owner| [owner["path"].to_s, owner["line"].to_i, owner["name"].to_s] },
        "fields" => fields.uniq { |field| field["id"] }.sort_by { |field| [field["path"], field["owner"], field["name"]] },
        "methods" => methods.sort_by { |method| [method["path"], method["owner"], method["line"].to_i, method["name"]] },
        "facts" => {
          "calls" => calls.sort_by { |call| [call["path"].to_s, call["line"].to_i, call["id"].to_s] },
          "call_resolution_coverage" => call_resolution_coverage,
          "state_accesses" => state_accesses.sort_by { |access| [access["path"].to_s, access["line"].to_i, access["id"].to_s] },
          "complexity_facts" => complexity_facts.sort_by { |fact| [fact["path"].to_s, fact["line"].to_i, fact["function"].to_s] },
          "flow_local_types" => flow_local_types.sort_by do |fact|
            [fact["file"].to_s, fact["function"].to_s, fact["line"].to_i, fact["name"].to_s, fact["node_id"].to_s]
          end,
          "type_dependencies" => type_dependencies.sort_by { |fact| fact["id"].to_s },
          "call_graph_edges" => call_graph_edges.sort_by { |edge| [edge["source"].to_s, edge["target"].to_s, edge["kind"].to_s] },
          "state_type_edges" => state_type_edges.sort_by { |edge| [edge["source"].to_s, edge["target"].to_s, edge["label"].to_s] },
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
          "nullable_refinements" => nullable_refinements.sort_by { |f| [f["condition_node_id"].to_s, f["place_id"].to_s] },
          "nullable_states" => nullable_states.sort_by { |f| [f["node_id"].to_s, f["place_id"].to_s] },
          "nullable_summaries" => nullable_summaries.sort_by { |f| [f["owner"].to_s, f["function"].to_s] },
          "nullable_operations" => nullable_operations.sort_by { |f| [f["path"].to_s, f["span"].to_s, f["node_id"].to_s] },
          "presence_correlations" => presence_correlations.sort_by { |f| f["group_id"].to_s },
          "dispatcher_inferences" => dispatcher_inferences.sort_by { |f| [f["path"].to_s, f["line"].to_i] },
          "hash_record_member_calls" => hash_record_member_calls.sort_by { |f| [f["path"].to_s, f["line"].to_i] },
          "struct_field_hash_shapes" => facts["struct_field_hash_shapes"] || {},
          "struct_field_array_shapes" => facts["struct_field_array_shapes"] || {},
          "hazards" => hazard_sites.sort_by { |h| [h["path"].to_s, h["line"].to_i, h["hazard_type"].to_s] },
        },
        "summary" => {
          "files" => files.size,
          "owners" => owners.size,
          "methods" => methods.size,
          "fields" => fields.uniq { |field| field["id"] }.size,
          "calls" => calls.size,
          "call_resolution_coverage" => call_resolution_coverage,
          "state_accesses" => state_accesses.size,
          "flow_local_types" => flow_local_types.size,
          "type_dependencies" => type_dependencies.size,
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
          "hazards" => hazard_sites.size,
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
        "input_coverage" => input_coverage_metadata({}),
        "corpus" => corpus_metadata,
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

    def corpus_metadata
      git_top = begin
        git_root_for(@root)
      rescue ArgumentError
        nil
      end
      complete = git_top &&
        target_dirs.any? { |target| File.directory?(target) && File.expand_path(target) == File.expand_path(git_top) } &&
        Espalier.target_exclude_dirs(root: @root).empty?
      {
        "complete" => !!complete,
        "reason" => if complete
          "the selected target includes the Git worktree root without configured exclusions"
        else
          "the selected target is not a proven closed corpus"
        end
      }
    end

    def input_coverage_metadata(facts)
      coverage = Hash(facts["input_coverage"])
      selected = coverage["selected_files"]
      parsed = coverage["parsed_files"]
      recovered = Array(coverage["parse_recovery_files"])
      return { "complete" => nil, "scope" => "selected_source_files", "reason" => "FactMine did not provide input coverage metadata" } unless selected.is_a?(Numeric) && parsed.is_a?(Numeric)

      complete = selected == parsed && recovered.empty?
      {
        "complete" => complete,
        "scope" => "selected_source_files",
        "reason" => if complete
          "all selected supported source files were parsed without recovery"
        elsif recovered.empty?
          "FactMine did not parse every selected supported source file"
        else
          "tree-sitter recovered from syntax errors in #{recovered.size} selected source file(s)"
        end,
        "parse_recovery_files" => recovered.sort
      }
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
      tracked = targets.flat_map do |target|
        git_tracked_files(git_root_for(target))
      end
      tracked.select do |path|
        target_path?(path, targets) && source_file?(path, exts)
      end.uniq.sort
    end

    def git_tracked_files(top)
      out, status = Open3.capture2e("git", "-C", top, "ls-files", "-z")
      raise ArgumentError, "git ls-files failed under #{top}: #{out.strip}" unless status.success?

      out.split("\0").reject(&:empty?).map { |path| File.expand_path(path, top) }
    end

    def git_root_for(target)
      probe = File.directory?(target) ? target : File.dirname(target)
      out, status = Open3.capture2e("git", "-C", probe, "rev-parse", "--show-toplevel")
      raise ArgumentError, "--vcs=git requires #{probe} to be inside a git worktree" unless status.success?

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
        "source_role" => self.class.source_role(rel(file)),
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
