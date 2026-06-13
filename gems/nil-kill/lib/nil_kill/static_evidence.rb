# typed: false
# frozen_string_literal: true

begin
  require "decomplex/syntax"
rescue LoadError
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
      state_types = {}
      state_protocols = Hash.new { |h, k| h[k] = Set.new }
      state_param_origins = Hash.new { |h, k| h[k] = Set.new }
      signatures = {}
      files = target_files

      files.each do |file|
        doc = Decomplex::Syntax.parse(file, parser: "tree_sitter")
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

        known_states = declared_states_by_owner(facts)
        facts[:state_declarations].each do |state|
          next if state.type.to_s.empty?

          state_types[state_key(state.owner, state.field)] = state.type.to_s
        end

        facts[:state_param_origins].each do |origin|
          next unless owned_state_origin?(origin, known_states[origin.owner.to_s])
          next if %w[self this].include?(origin.param.to_s)

          state_param_origins[state_key(origin.owner, origin.field)].add(origin.param.to_s)
        end

        facts[:call_sites].each do |call|
          state = receiver_state_field(call.receiver, known_states[call.owner.to_s])
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
        "target_dirs" => target_dirs.map { |dir| rel(dir) },
        "target_exclude_dirs" => NilKill.target_exclude_dirs.map { |dir| rel(dir) },
        "runtime_fields" => false,
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
          "signatures" => methods.count { |method| !method.dig("source", "sig").to_s.empty? },
          "state_types" => state_types.size,
          "state_protocols" => state_protocols.size,
          "state_param_origins" => state_param_origins.size,
          "ivar_protocols" => state_protocols.size,
          "ivar_param_origins" => state_param_origins.size,
        },
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
          Dir.glob(File.join(target, "**", "*")).select { |path| source_file?(path, exts) }
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
        !NilKill.target_excluded?(path)
    end

    def declared_states_by_owner(facts)
      index = Hash.new { |h, k| h[k] = Set.new }
      facts[:state_declarations].each { |state| index[state.owner.to_s].add(state.field.to_s) }
      index
    end

    def owned_state_origin?(origin, known_states)
      known_states ||= Set.new
      return true if known_states.include?(origin.field.to_s)

      receiver = origin.receiver.to_s
      return false if receiver == ".literal"

      receiver == "self" || receiver == "this" || receiver.match?(/\A@[A-Za-z_]\w*(?:\.|\z)/) || receiver.start_with?("self.", "this.")
    end

    def receiver_state_field(receiver, known_states)
      known_states ||= Set.new
      text = receiver.to_s.sub(/\A\*/, "")
      return nil if text.empty? || text == "self" || text == "this"
      return text.split(".").first if text.match?(/\A@[A-Za-z_]\w*(?:\.|\z)/)
      return text.split(".")[1] if text.start_with?("self.") || text.start_with?("this.")

      first = text.split(".").first
      known_states.include?(first) ? first : nil
    end

    def state_key(owner, field)
      [owner.to_s, field.to_s].join("\u0000")
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
