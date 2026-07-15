# typed: false
# frozen_string_literal: true

module NilKill
  module Commands
    class StaticCommand
      SOURCE_ROLES = %w[production test benchmark example generated vendored vcs_metadata].freeze
      TYPE_NEXT_CANDIDATE_KINDS = %w[parameter return state_field field ivar].freeze

      def initialize(argv)
        @argv = argv.dup
      end

      def run
        output = option("--output") || File.join(TMP_DIR, "static.json")
        root = File.expand_path(option("--root") || ROOT)
        language = option("--language")
        vcs = option("--vcs")
        source_roles = parse_source_roles(option("--source-role"))
        targets = @argv.reject { |arg| arg.start_with?("--") }
        evidence = StaticEvidence.build(targets.empty? ? [root] : targets, root: root, language: language, vcs: vcs)
        append_type_next!(evidence, source_roles: source_roles)
        FileUtils.mkdir_p(File.dirname(output))
        File.write(output, JSON.pretty_generate(evidence))
        puts "wrote static evidence to #{NilKill.rel(output)}"
        if (candidate = evidence.dig("facts", "type_next", 0))
          puts "top type-next candidate: #{candidate["candidate"]} (unlocks #{candidate["unlock_count"]} facts)"
        end
      end

      private

      def option(name)
        if (idx = @argv.index(name))
          value = @argv[idx + 1] || abort("#{name} requires a value")
          @argv.slice!(idx, 2)
          value
        elsif (arg = @argv.find { |item| item.start_with?("#{name}=") })
          @argv.delete(arg)
          arg.split("=", 2).last
        end
      end

      def parse_source_roles(value)
        return ["production"] if value.nil?
        return SOURCE_ROLES if value == "all"

        roles = value.split(",").map(&:strip).reject(&:empty?).uniq
        invalid = roles - SOURCE_ROLES
        raise ArgumentError, "unsupported source role: #{invalid.join(", ")}" unless invalid.empty?
        raise ArgumentError, "--source-role requires at least one role" if roles.empty?

        roles
      end

      def append_type_next!(evidence, source_roles: ["production"])
        evidence["facts"] ||= {}
        languages = evidence_languages(evidence)
        unless languages.empty? || languages.all? { |language| type_next_annotation_advice?(evidence, language) }
          evidence["facts"]["type_next"] = []
          evidence["summary"] ||= {}
          evidence["summary"]["type_next_candidates"] = 0
          evidence["summary"]["type_next_status"] = "not_applicable_static_language"
          evidence["summary"]["type_next_languages"] = languages
          return
        end
        roles_by_path = Array(evidence["files"]).each_with_object({}) do |file, roles|
          path = file["path"].to_s
          role = file["source_role"] || "production"
          roles[path] = role
          roles[File.expand_path(path, evidence["root"])] = role if evidence["root"]
        end
        allowed_roles = source_roles.to_set
        dependencies = Array(evidence.dig("facts", "type_dependencies")).select do |dependency|
          path = dependency["file"] || dependency["path"]
          path.nil? || allowed_roles.include?(roles_by_path.fetch(path.to_s, "production"))
        end
        ranked_evidence = evidence.merge(
          "facts" => Hash(evidence["facts"]).merge("type_dependencies" => dependencies)
        )
        pressure = FlowGraph.dependencies_from_evidence(ranked_evidence).unlock_pressure
        evidence["facts"]["type_next"] = pressure.filter_map do |row|
          candidate = row.fetch("candidate_data")
          next unless type_next_candidate?(candidate)

          candidate.slice("file", "line", "owner", "function", "name", "kind")
          row.slice("candidate_data", "direct_ids", "unlocked_ids", "counts")
            .merge(
              "candidate" => candidate.fetch("name"),
              "candidate_id" => row.fetch("candidate"),
              "unlock_count" => row.fetch("unlocked_ids").length,
              "location" => candidate.slice("file", "line", "owner", "function"),
              "reason" => type_next_reason(candidate, row)
            )
        end
        evidence["summary"] ||= {}
        evidence["summary"]["type_next_candidates"] = evidence["facts"]["type_next"].length
        evidence["summary"]["type_next_status"] = "available"
      end

      def evidence_languages(evidence)
        Array(evidence["files"]).filter_map do |file|
          language = file["language"].to_s.downcase
          language unless language.empty?
        end
          .uniq
          .sort
      end

      def type_next_annotation_advice?(evidence, language)
        capability = Hash(evidence["language_capabilities"])[language]
        capability ||= NilKill::Languages.capability_for(language) if defined?(NilKill::Languages)
        Hash(capability)["type_next_annotation_advice"] == true
      end

      def type_next_candidate?(candidate)
        kind = (candidate["candidate_kind"] || candidate["kind"]).to_s
        name = candidate["name"].to_s
        TYPE_NEXT_CANDIDATE_KINDS.include?(kind) && name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      end

      def type_next_reason(candidate, row)
        kind = (candidate["candidate_kind"] || candidate["kind"]).to_s.tr("_", " ")
        direct = row.fetch("direct_ids").length
        total = row.fetch("unlocked_ids").length
        "Add or verify this #{kind} type: it directly resolves #{direct} and transitively unlocks #{total} static flow fact#{total == 1 ? "" : "s"}."
      end
    end
  end
end
