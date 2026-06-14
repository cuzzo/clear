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
      files = target_files

      files.each do |file|
        doc = Decomplex::Syntax.parse(file, parser: "tree_sitter")
        provider = Languages.provider_for(doc.language)
        facts = doc.adapter.structural_facts(doc)
        rel_path = rel(file)

        facts[:function_defs].each do |fn|
          owner = fn.owner.to_s
          name = fn.name.to_s
          signature = fn.signature.to_s
          key = [owner, name, fn.kind.to_s]
          methods << {
            "key" => key,
            "owner" => owner,
            "name" => name,
            "kind" => fn.kind.to_s,
            "path" => rel_path,
            "line" => fn.line,
            "span" => fn.span,
            "language" => doc.language.to_s,
            "signature" => signature,
            "params" => Array(fn.params).map(&:to_s),
            "source" => { "sig" => signature },
          }
          signatures[[owner, name].join("\u0000")] = signature unless signature.empty?
        end

        known_states = declared_states_by_owner(facts, provider)
        facts[:state_declarations].each do |state|
          field = provider.declared_state_field(state.field)
          fields << field_record(doc, rel_path, state, field)
          next if state.type.to_s.empty?

          state_types[state_key(state.owner, field)] = state.type.to_s
        end

        facts[:state_param_origins].each do |origin|
          next unless provider.owned_state_origin?(origin, known_states[origin.owner.to_s])
          next if %w[self this].include?(origin.param.to_s)

          field = provider.canonical_state_field(origin.field, receiver: origin.receiver)
          state_param_origins[state_key(origin.owner, field)].add(origin.param.to_s)
        end

        facts[:call_sites].each do |call|
          state = provider.receiver_state_field(call.receiver, known_states[call.owner.to_s])
          next unless state

          state_protocols[state_key(call.owner, state)].add(call.message.to_s)
        end
      end

      state_protocols = stringify_set_map(state_protocols)
      state_param_origins = stringify_set_map(state_param_origins)

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
          "ivar_runtime" => [],
          "ivar_protocols" => state_protocols,
          "ivar_param_origins" => state_param_origins,
        },
        "summary" => {
          "files" => files.size,
          "methods" => methods.size,
          "fields" => fields.uniq { |field| field["id"] }.size,
          "signatures" => methods.count { |method| !method.dig("source", "sig").to_s.empty? },
          "state_types" => state_types.size,
          "state_protocols" => state_protocols.size,
          "state_param_origins" => state_param_origins.size,
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

    def declared_states_by_owner(facts, provider)
      index = Hash.new { |h, k| h[k] = Set.new }
      facts[:state_declarations].each { |state| index[state.owner.to_s].add(provider.declared_state_field(state.field)) }
      index
    end

    def state_key(owner, field)
      [owner.to_s, field.to_s].join("\u0000")
    end

    def field_record(doc, rel_path, state, field)
      {
        "id" => [doc.language, rel_path, state.owner, "field", field].map(&:to_s).join("\u0000"),
        "language" => doc.language.to_s,
        "path" => rel_path,
        "owner" => state.owner.to_s,
        "name" => field.to_s,
        "line" => state.line,
        "span" => state.span,
        "declared_type" => state.type.to_s.empty? ? nil : state.type.to_s,
        "static_origin" => "state_declaration",
      }
    end

    def languages_for(files)
      files.map { |file| Decomplex::Syntax.language_for(file).to_s }.uniq.sort
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
