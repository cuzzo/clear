# typed: false
# frozen_string_literal: true

module NilKill
  module Commands
    class StaticCommand
      SOURCE_ROLES = %w[production test benchmark example generated vendored vcs_metadata].freeze

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
        evidence["facts"] ||= {}
        evidence["facts"]["type_next"] = pressure.map do |row|
          row.slice("candidate", "candidate_data", "direct_ids", "unlocked_ids", "counts")
            .merge("unlock_count" => row.fetch("unlocked_ids").length)
        end
        evidence["summary"] ||= {}
        evidence["summary"]["type_next_candidates"] = pressure.length
      end
    end
  end
end
