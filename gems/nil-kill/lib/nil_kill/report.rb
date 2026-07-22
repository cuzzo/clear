# typed: false
# frozen_string_literal: true

require_relative "sarif"

module NilKill
  class Report
    FALLIBILITY_DISPLAY_SCORE = 10

    def initialize(argv = [], evidence: nil)
      @argv = argv.dup
      @evidence_override = evidence
      @with_links = @argv.delete("--with-links")
      @full = @argv.delete("--full")
      @hygiene_only = @argv.delete("--hygiene")
      @format = parse_format(@argv)
      @evidence_path = parse_evidence_path(@argv)
      @report_path = parse_sarif_output_path(@argv) ||
                     parse_output_path(@argv) ||
                     default_report_path
    end

    def run
      evidence = @evidence_override || read_evidence
      @evidence = evidence
      if sarif_format?
        report = to_sarif(evidence)
        FileUtils.mkdir_p(File.dirname(@report_path))
        File.write(@report_path, report)
        puts report
        return
      end
      if Schema::EvidenceBundle.v2?(evidence)
        report = Reporting::MultiLanguageReport.new(evidence).lines.map { |line| format_report_line(line) }.join("\n") + "\n"
        FileUtils.mkdir_p(File.dirname(@report_path))
        File.write(@report_path, report)
        puts report
        return
      end
      actions = evidence["actions"]
      lines = build_header(evidence)
      if @hygiene_only
        append_hygiene_overview_summary(lines, evidence, actions)
        lines = lines.map { |line| format_report_line(line) }
        puts lines.join("\n")
        return
      end
      by_conf = actions.group_by { |a| a["confidence"] }
      append_project_prioritization(lines, evidence, actions)
      append_hygiene_overview(lines, evidence)
      append_action_sections(lines, actions, by_conf)
      append_untyped_breakdown(lines, evidence)
      unless evidence["diagnostics"]["nil_origins"].empty?
        lines << ""
        lines << "## Nil origins"
        evidence["diagnostics"]["nil_origins"].first(20).each { |o| lines << "- #{o["origin"]}: #{o["count"]}" }
      end
      append_callsite_pressure(lines, actions)
      append_type_dependency_pressure(lines, evidence)
      append_return_origin_report(lines, evidence)
      append_param_origin_report(lines, evidence)
      append_foreign_class_pressure(lines, evidence)
      append_type_normalizer_report(lines, evidence)
      append_fallibility_pressure_report(lines, evidence)
      append_struct_report(lines, evidence)
      append_collection_report(lines, evidence)
      append_tuple_report(lines, evidence)
      lines = lines.map { |line| format_report_line(line) }
      lines = prepare_linked_report(lines, full: @full) if @with_links
      FileUtils.mkdir_p(File.dirname(@report_path))
      report = lines.join("\n") + "\n"
      File.write(@report_path, report)
      puts report
    end

    def to_sarif(evidence = @evidence)
      JSON.pretty_generate(to_sarif_hash(evidence))
    end

    def to_sarif_hash(evidence = @evidence)
      results = sarif_results(evidence)
      NilKill::Sarif.document(
        tool_name: "Nil-Kill",
        information_uri: "https://github.com/codeforreno/litedb",
        rules: sarif_rules(evidence),
        results: results,
        properties: {
          "format" => "nil-kill.report.sarif.v1",
          "summary" => sarif_summary(evidence),
          NilKill::Sarif::PROOF_BOUNDARY_SUMMARY_PROPERTY => NilKill::Sarif.proof_boundary_summary(results)
        }
      )
    end

    def build_header(evidence)
      lines = ["# Nil Kill Report", ""]
      lines << "- Target dirs: #{evidence["target_dirs"].join(", ")}"
      lines << "- Excluded target dirs: #{Array(evidence["target_exclude_dirs"]).join(", ")}" unless Array(evidence["target_exclude_dirs"]).empty?
      lines << "- Methods indexed: #{evidence["methods"].size}"
      lines << "- Runtime-observed methods: #{evidence["methods"].count { |m| m["calls"].to_i.positive? }}"
      lines << "- Missing sigs: #{evidence["facts"]["unsigned_methods"].size}"
      lines << "- Existing sigs: #{evidence["facts"]["existing_sigs"].size}"
      lines << "- Existing/candidate T.let sites: #{evidence["facts"]["tlet_sites"].size}"
      lines << "- Sorbet errors captured: #{evidence["diagnostics"]["sorbet_errors"].size}"
      lines
    end

    # Compact slot-only emission for `nil-kill report --hygiene`. Skips the
    # full report's expensive sections (action lists, callsite pressure,
    # origin breakdowns) so a before/after sweep is fast (~ms vs minutes).
    def append_hygiene_overview_summary(lines, evidence, actions)
      lines << ""
      lines << "## Hygiene Overview"
      append_type_soundness_table(lines, evidence)
      append_untyped_slot_name_pressure(lines, evidence)
      append_untyped_cause_table(lines, evidence)
      lines << ""
      lines << "## Action Plan Counts"
      counts = actions.group_by { |a| [a["confidence"], a["kind"], a.dig("data", "source") || "(none)"] }
        .transform_values(&:size)
        .sort_by { |_, count| -count }
      high = counts.select { |key, _| key[0] == "high" }
      review = counts.select { |key, _| key[0] == "review" }
      lines << "- HIGH evidence: #{high.sum { |_, c| c }}"
      high.each { |(_, kind, src), c| lines << "  - #{c.to_s.rjust(4)}  #{kind} / #{src}" }
      lines << "- REVIEW evidence: #{review.sum { |_, c| c }}"
      review.first(8).each { |(_, kind, src), c| lines << "  - #{c.to_s.rjust(4)}  #{kind} / #{src}" }
      lines << "  - ... #{review.size - 8} more action categories" if review.size > 8
    end

    def parse_output_path(argv)
      value = nil
      if (idx = argv.index("--output-path"))
        value = argv[idx + 1] || abort("--output-path requires a path")
        argv.slice!(idx, 2)
      elsif (arg = argv.find { |item| item.start_with?("--output-path=") })
        value = arg.split("=", 2).last
        argv.delete(arg)
      end
      return nil unless value

      path = File.expand_path(value, ROOT)
      output_directory_path?(path) ? File.join(path, report_filename) : path
    end

    def parse_format(argv)
      value = nil
      if (idx = argv.index("--format"))
        value = argv[idx + 1] || abort("--format requires markdown, sarif, or json")
        argv.slice!(idx, 2)
      elsif (arg = argv.find { |item| item.start_with?("--format=") })
        value = arg.split("=", 2).last
        argv.delete(arg)
      end
      value = value.to_s.downcase
      return :markdown if value.empty? || value == "markdown"
      return :sarif if %w[sarif json].include?(value)

      abort("--format must be markdown, sarif, or json")
    end

    def parse_sarif_output_path(argv)
      value = nil
      if (idx = argv.index("--sarif"))
        value = argv[idx + 1] || abort("--sarif requires a path")
        argv.slice!(idx, 2)
      elsif (arg = argv.find { |item| item.start_with?("--sarif=") })
        value = arg.split("=", 2).last
        argv.delete(arg)
      elsif (idx = argv.index("--json"))
        value = argv[idx + 1] || abort("--json requires a path")
        argv.slice!(idx, 2)
      elsif (arg = argv.find { |item| item.start_with?("--json=") })
        value = arg.split("=", 2).last
        argv.delete(arg)
      end
      return nil unless value

      @format = :sarif
      File.expand_path(value, ROOT)
    end

    def parse_evidence_path(argv)
      value = nil
      if (idx = argv.index("--evidence"))
        value = argv[idx + 1] || abort("--evidence requires a path")
        argv.slice!(idx, 2)
      elsif (arg = argv.find { |item| item.start_with?("--evidence=") })
        value = arg.split("=", 2).last
        argv.delete(arg)
      end
      value && File.expand_path(value, ROOT)
    end

    def read_evidence
      return FactMine::Syntax::TypeExpr.wrap_types!(JSON.parse(File.read(@evidence_path))) if @evidence_path

      Store.read
    end

    def output_directory_path?(path)
      File.directory?(path) || File.extname(path).empty?
    end

    def sarif_format?
      @format == :sarif
    end

    def report_filename
      sarif_format? ? "report.sarif" : "report.md"
    end

    def default_report_path
      sarif_format? ? REPORT_PATH.sub(/\.md\z/, ".sarif") : REPORT_PATH
    end

    def sarif_rules(evidence)
      action_kinds = sarif_actions(evidence).map { |action| action["kind"].to_s }.reject(&:empty?).uniq
      diagnostic_codes = sarif_diagnostics(evidence).map { |diagnostic| diagnostic_code(diagnostic) }.uniq
      static_kinds = sarif_static_findings(evidence).map { |finding| finding.fetch("kind") }.uniq
      action_rules = action_kinds.map do |kind|
        NilKill::Sarif.rule(
          id: "nil-kill.action.#{NilKill::Sarif.slug(kind)}",
          name: "Action: #{kind}",
          short_description: "Nil-Kill inferred action"
        )
      end
      diagnostic_rules = diagnostic_codes.map do |code|
        NilKill::Sarif.rule(
          id: "nil-kill.diagnostic.#{NilKill::Sarif.slug(code)}",
          name: "Diagnostic: #{code}",
          short_description: "Nil-Kill diagnostic"
        )
      end
      static_rules = static_kinds.map do |kind|
        NilKill::Sarif.rule(
          id: "nil-kill.static.#{NilKill::Sarif.slug(kind)}",
          name: "Static: #{kind.tr("_", " ")}",
          short_description: "Nil-Kill static analysis signal"
        )
      end
      pressure_rules = sarif_pressure_findings(evidence).map { |finding| finding.fetch("kind") }.uniq.map do |kind|
        NilKill::Sarif.rule(
          id: "nil-kill.pressure.#{NilKill::Sarif.slug(kind)}",
          name: "Pressure: #{kind.tr("_", " ")}",
          short_description: "Nil-Kill pressure signal"
        )
      end
      action_rules + diagnostic_rules + static_rules + pressure_rules
    end

    def sarif_results(evidence)
      sarif_actions(evidence).map { |action| sarif_action_result(action, evidence) } +
        sarif_diagnostics(evidence).map { |diagnostic| sarif_diagnostic_result(diagnostic) } +
        sarif_static_findings(evidence).map { |finding| sarif_static_result(finding, evidence) } +
        sarif_pressure_findings(evidence).map { |finding| sarif_pressure_result(finding, evidence) }
    end

    def sarif_actions(evidence)
      Array(evidence["actions"])
    end

    def sarif_diagnostics(evidence)
      diagnostics = evidence["diagnostics"]
      return diagnostics if diagnostics.is_a?(Array)
      diagnostics = {} unless diagnostics.is_a?(Hash)

      diagnostics.to_h.flat_map do |kind, rows|
        Array(rows).map do |row|
          row.is_a?(Hash) ? row.merge("code" => row["code"] || kind.to_s) : { "code" => kind.to_s, "message" => row.to_s }
        end
      end
    end

    def sarif_static_findings(evidence)
      return [] unless Schema::EvidenceBundle.v2?(evidence)

      return_origins = static_return_origin_index(evidence)
      methods = Array(evidence.dig("static", "methods")).flat_map do |method|
        key = [
          static_identity_path(evidence, method["path"]),
          method["owner"],
          method["name"].to_s.sub(/\Aself\./, ""),
        ]
        static_method_findings(method, return_origin: return_origins[key])
      end
      fields = Array(evidence.dig("static", "fields")).filter_map { |field| static_field_finding(field) }
      aliases = static_alias_recommendations(evidence).map { |recommendation| static_alias_finding(recommendation) }
      methods + fields + aliases
    end

    def static_alias_recommendations(evidence)
      facts = evidence.dig("static", "facts")
      facts = evidence.dig("static", "language_extensions", "nil_kill_static_evidence", "facts") unless facts.is_a?(Hash)
      Array(facts && facts["alias_recommendations"])
    end

    def static_method_findings(method, return_origin: nil)
      signature = method["signature"].to_s
      return [] if signature.empty?

      findings = []
      if static_untyped_signature?(signature)
        findings << {
          "kind" => "untyped_signature",
          "level" => "warning",
          "message" => "untyped signature pressure: #{static_member_label(method)} has `#{signature}`; " \
                       "replace Any/T.untyped/unknown with the narrowest contract to stop downstream type guards",
          "path" => method["path"],
          "line" => method["line"],
          "static_kind" => method["kind"] || "method",
          "language" => method["language"],
          "owner" => method["owner"],
          "name" => method["name"],
          "signature" => signature,
          "proof_boundary" => static_review_boundary("static_signature"),
        }
      end
      if static_nullable_signature?(signature)
        false_nullable = static_nullable_return_signature?(method, signature) &&
          static_origin_proves_non_nil_return?(return_origin)
        findings << {
          "kind" => false_nullable ? "false_nullable_return" : "nullable_signature",
          "level" => false_nullable ? "warning" : "note",
          "message" => if false_nullable
            source_lines = Array(return_origin["sources"]).filter_map { |source| source["line"] }.uniq.sort
            "false-nilable return: #{static_member_label(method)} declares a nullable return, but every " \
              "resolved return path is non-nil (#{source_lines.map { |line| "line #{line}" }.join(', ')}); tighten the return contract"
          else
            "nilability pressure: #{static_member_label(method)} has `#{signature}`; " \
              "confirm absence is meaningful, otherwise tighten the contract or use an empty collection/value"
          end,
          "path" => method["path"],
          "line" => method["line"],
          "static_kind" => method["kind"] || "method",
          "language" => method["language"],
          "owner" => method["owner"],
          "name" => method["name"],
          "signature" => signature,
          "return_evidence" => false_nullable ? return_origin : nil,
          "proof_tier" => false_nullable ? "static_proven" : nil,
          "blockers" => false_nullable ? Array(return_origin["blockers"]) : [],
          "proof_boundary" => if false_nullable
            static_proven_boundary(return_origin, "static_nullable_return")
          else
            static_review_boundary("static_signature")
          end,
        }
      end
      findings
    end

    def static_return_origin_index(evidence)
      facts = evidence.dig("static", "facts")
      facts = evidence.dig("static", "language_extensions", "nil_kill_static_evidence", "facts") unless facts.is_a?(Hash)
      Array(facts && facts["return_origins"]).each_with_object({}) do |origin, index|
        key = [
          static_identity_path(evidence, origin["path"]),
          origin["class"],
          origin["method"].to_s.sub(/\Aself\./, ""),
        ]
        current = index[key]
        index[key] = origin if current.nil? || (current["confidence"] != "strong" && origin["confidence"] == "strong")
      end
    end

    def static_identity_path(evidence, path)
      value = path.to_s.tr("\\", "/")
      root = evidence["root"].to_s
      return value if value.empty? || root.empty?

      root_path = File.expand_path(root)
      expanded_path = File.expand_path(value, root_path)
      return "." if expanded_path == root_path

      prefix = root_path.end_with?(File::SEPARATOR) ? root_path : "#{root_path}#{File::SEPARATOR}"
      return expanded_path.delete_prefix(prefix).tr("\\", "/") if expanded_path.start_with?(prefix)

      value
    end

    def static_nullable_return_signature?(method, signature)
      return_type = method["return_type"]
      return_type ||= method["source"]["return_type"] if method["source"].is_a?(Hash)
      return static_nullable_signature?(return_type) unless return_type.to_s.empty?

      case method["language"].to_s
      when "ruby"
        signature.match?(/\breturns\(\s*T\.nilable\b/)
      when "python"
        arrow = signature.split("->", 2)[1]
        !arrow.to_s.empty? && static_nullable_signature?(arrow)
      when "typescript", "javascript"
        result = signature.match(/\)\s*:\s*(.+)\z/)&.[](1)
        !result.to_s.empty? && static_nullable_signature?(result)
      else
        false
      end
    end

    def static_origin_proves_non_nil_return?(origin)
      return false unless origin.is_a?(Hash)
      return false unless origin["confidence"] == "strong"
      return false unless Array(origin["blockers"]).empty?
      return false if Array(origin["sources"]).empty?

      candidate = origin["candidate_type"]
      kind = candidate.respond_to?(:kind) ? candidate.kind : candidate.is_a?(Hash) ? candidate["kind"] : nil
      return false if %w[Untyped NilClass Nilable Union].include?(kind.to_s)

      Array(origin["sources"]).all? do |source|
        source_kind = source["type"].respond_to?(:kind) ? source["type"].kind : source.dig("type", "kind")
        !source_kind.nil? && !%w[Untyped NilClass Nilable Union].include?(source_kind.to_s)
      end
    end

    def static_field_finding(field)
      type = field["type"] || field["declared_type"] || field["signature"] || (field["source"].is_a?(Hash) ? field["source"]["type"] : nil)
      return nil unless type.to_s.empty? || static_untyped_signature?(type.to_s)

      {
        "kind" => "untyped_field",
        "level" => "warning",
        "message" => "untyped field pressure: #{static_member_label(field)} has no precise static type; " \
                     "add a declared field type or typed initializer so readers do not need guards",
        "path" => field["path"],
        "line" => field["line"],
        "static_kind" => field["kind"] || "field",
        "language" => field["language"],
        "owner" => field["owner"],
        "name" => field["name"] || field["field"],
        "signature" => type,
        "proof_boundary" => static_review_boundary("static_field"),
      }
    end

    def static_alias_finding(recommendation)
      alias_name = recommendation["alias"].to_s
      target = recommendation["target"].to_s
      {
        "kind" => "alias_recommendation",
        "level" => "note",
        "message" => recommendation["message"].to_s.empty? ?
          "use #{alias_name} for #{target} in static type slots" :
          recommendation["message"].to_s,
        "path" => recommendation["path"] || recommendation.dig("definition", "path"),
        "line" => recommendation["line"] || recommendation.dig("definition", "line"),
        "static_kind" => "type_alias",
        "language" => recommendation["language"],
        "type_system" => recommendation["type_system"],
        "alias" => alias_name,
        "target" => target,
        "definition" => recommendation["definition"],
        "slot_count" => recommendation["slot_count"],
        "slots" => recommendation["slots"],
        "proof_boundary" => static_review_boundary("static_alias_recommendation"),
      }
    end

    def static_untyped_signature?(signature)
      signature.to_s.match?(/\bT\.untyped\b|\btyping\.Any\b|\bAny\b|(?<!\.)\bany\b|\bunknown\b/)
    end

    def static_nullable_signature?(signature)
      text = signature.to_s
      text.match?(/\bT\.nilable\b/) ||
        text.match?(/\bOptional\s*\[/) ||
        text.match?(/\bnull\b/) ||
        text.match?(/\bundefined\b/) ||
        text.match?(/\bNone\s*\|/) ||
        text.match?(/\|\s*(?:None|null|undefined)\b/)
    end

    def static_member_label(member)
      owner = member["owner"].to_s
      name = (member["name"] || member["field"]).to_s
      return name if owner.empty?
      return owner if name.empty?

      "#{owner}##{name}"
    end

    def sarif_pressure_findings(evidence)
      fallibility_pressure_findings(evidence) +
        primitive_record_pressure_findings(evidence)
    end

    def fallibility_pressure_findings(evidence)
      fallibility_display_rows(Array(evidence.dig("facts", "fallibility_pressure"))).map do |row|
        runtime = row["runtime"] || {}
        raised = "#{runtime["raised_calls"].to_i}/#{runtime["calls"].to_i}"
        classes = Array(runtime["raised_classes"]).first(4).join(", ")
        class_text = classes.empty? ? "" : "; raised #{classes}"
        {
          "kind" => "fallibility",
          "level" => row["handler_pressure"].to_i.positive? || runtime["raised_calls"].to_i.positive? ? "warning" : "note",
          "message" => "fallibility pressure: #{row["label"]} score #{row["score"].to_i}; " \
                       "direct sources #{Array(row["direct_sources"]).size}; runtime raises #{raised} " \
                       "(#{runtime["raised_rate"].to_f}%#{class_text}); handlers #{row["handler_pressure"].to_i}; " \
                       "unhandled callers #{Array(row["fallible_callers"]).size}",
          "path" => row["path"],
          "line" => row["line"],
          "pressure" => row,
          "proof_boundary" => static_review_boundary("fallibility_pressure"),
        }
      end
    end

    def primitive_record_pressure_findings(evidence)
      hash_record_struct_pressure(evidence).map do |row|
        location = parse_location(Array(row["examples"]).first)
        keys = Array(row["keys"]).first(10).join(", ")
        {
          "kind" => "primitive_record",
          "level" => row["total_pressure"].to_i >= 3 ? "warning" : "note",
          "message" => "primitive record pressure: #{row["label"]} behaves like an ad-hoc struct; " \
                       "total pressure #{row["total_pressure"].to_i} " \
                       "(return #{row["return_slots"].to_i}, param #{row["param_slots"].to_i}, " \
                       "ivar #{row["ivar_slots"].to_i}, collection #{row["collection_slots"].to_i}); keys #{keys}",
          "path" => location[:path],
          "line" => location[:line],
          "pressure" => row,
          "proof_boundary" => static_review_boundary("primitive_record_pressure"),
        }
      end
    end

    def sarif_action_result(action, evidence)
      kind = action["kind"].to_s.empty? ? "action" : action["kind"].to_s
      NilKill::Sarif.result(
        rule_id: "nil-kill.action.#{NilKill::Sarif.slug(kind)}",
        level: sarif_action_level(action),
        message: "#{kind} [#{action["confidence"] || "unknown"}]: #{action["message"]}",
        path: action_path(action),
        line: action_line(action),
        properties: NilKill::Sarif.json_safe_value(action).merge(
          "source_format" => Schema::EvidenceBundle.v2?(evidence) ? "nil-kill.evidence.v2" : "nil-kill.evidence.v1",
          NilKill::Sarif::PROOF_BOUNDARY_PROPERTY => unknown_observation_boundary("nil_kill_action")
        )
      )
    end

    def sarif_diagnostic_result(diagnostic)
      code = diagnostic_code(diagnostic)
      NilKill::Sarif.result(
        rule_id: "nil-kill.diagnostic.#{NilKill::Sarif.slug(code)}",
        level: diagnostic["severity"] || "warning",
        message: diagnostic["message"] || diagnostic.to_s,
        path: diagnostic_path(diagnostic),
        line: diagnostic_line(diagnostic),
        properties: NilKill::Sarif.json_safe_value(diagnostic).merge(
          "source_format" => "nil-kill.diagnostics",
          NilKill::Sarif::PROOF_BOUNDARY_PROPERTY => unknown_observation_boundary("nil_kill_diagnostic")
        )
      )
    end

    def sarif_static_result(finding, evidence)
      kind = finding["kind"].to_s.empty? ? "static" : finding["kind"].to_s
      NilKill::Sarif.result(
        rule_id: "nil-kill.static.#{NilKill::Sarif.slug(kind)}",
        level: finding["level"] || "note",
        message: finding["message"] || kind,
        path: finding["path"],
        line: finding["line"],
        properties: NilKill::Sarif.json_safe_value(finding.except("proof_boundary")).merge(
          "source_format" => "nil-kill.static.evidence.v2",
          NilKill::Sarif::PROOF_BOUNDARY_PROPERTY => static_proof_boundary(finding, "static_nil_finding", evidence)
        )
      )
    end

    def sarif_pressure_result(finding, evidence)
      kind = finding["kind"].to_s.empty? ? "pressure" : finding["kind"].to_s
      NilKill::Sarif.result(
        rule_id: "nil-kill.pressure.#{NilKill::Sarif.slug(kind)}",
        level: finding["level"] || "note",
        message: finding["message"] || kind,
        path: finding["path"],
        line: finding["line"],
        properties: NilKill::Sarif.json_safe_value(finding.except("proof_boundary")).merge(
          "source_format" => "nil-kill.pressure",
          NilKill::Sarif::PROOF_BOUNDARY_PROPERTY => static_proof_boundary(finding, "static_nil_pressure", evidence)
        )
      )
    end

    def static_proof_boundary(finding, scope, evidence = nil)
      boundary = finding["proof_boundary"]
      return apply_corpus_completeness(boundary, evidence) if boundary.is_a?(Hash)

      # Legacy evidence had no typed boundary. Do not reinterpret arbitrary
      # payload fields such as `complete` or `proof_tier` while rendering.
      static_review_boundary(scope, **corpus_boundary_attributes(evidence))
    end

    def static_proven_boundary(evidence, scope)
      blockers = Array(evidence["blockers"])
      NilKill::Sarif.proof_boundary(
        # A fact's local proof completeness is not corpus/input completeness.
        # Only `input_coverage` may set this boundary dimension.
        input_completeness: "unknown",
        claim_status: "proven",
        coverage_discharge: "unsatisfiable",
        authority: ["fact_mine_normalized_ast", "nil_kill_static"],
        claim_kind: scope,
        scope: { kind: "local", closed: false },
        blockers: blockers
      )
    end

    def static_review_boundary(scope, input_completeness: nil, blockers: [])
      NilKill::Sarif.proof_boundary(
        input_completeness: input_completeness || (blockers.empty? ? "unknown" : "partial"),
        claim_status: "review",
        coverage_discharge: "unsatisfiable",
        authority: ["fact_mine_normalized_ast", "nil_kill_static"],
        claim_kind: scope,
        scope: { kind: "local", closed: false },
        blockers: blockers
      )
    end

    def apply_corpus_completeness(boundary, evidence)
      coverage = corpus_boundary_attributes(evidence)
      return boundary if coverage.fetch(:input_completeness) == "unknown"
      return boundary if coverage.fetch(:input_completeness) == "complete" && boundary["input_completeness"] != "unknown"

      NilKill::Sarif.proof_boundary(
        input_completeness: coverage.fetch(:input_completeness),
        claim_status: boundary.fetch("claim_status"),
        coverage_discharge: boundary.fetch("coverage_discharge"),
        authority: boundary.fetch("authority"),
        claim_kind: boundary.fetch("claim_kind"),
        scope: boundary.fetch("scope"),
        blockers: Array(boundary["blockers"]) + coverage.fetch(:blockers)
      )
    end

    def corpus_boundary_attributes(evidence)
      corpus = evidence.is_a?(Hash) ? (evidence.dig("static", "input_coverage") || evidence["input_coverage"]) : nil
      return { input_completeness: "unknown", blockers: [] } unless corpus.is_a?(Hash)
      return { input_completeness: "complete", blockers: [] } if corpus["complete"] == true

      if corpus["complete"] == false
        return {
          input_completeness: "partial",
          blockers: [corpus["reason"].to_s.empty? ? "incomplete_input_coverage" : corpus["reason"].to_s]
        }
      end

      { input_completeness: "unknown", blockers: [] }
    end

    def unknown_observation_boundary(scope)
      NilKill::Sarif.proof_boundary(
        input_completeness: "unknown",
        claim_status: "observed",
        coverage_discharge: "not_applicable",
        authority: ["nil_kill"],
        claim_kind: scope,
        scope: { kind: "local", closed: false }
      )
    end

    def sarif_action_level(action)
      case action["confidence"].to_s
      when HIGH then "warning"
      when GAP then "note"
      else "note"
      end
    end

    def action_path(action)
      action.dig("target", "path") || action["path"] || action.dig("data", "path") ||
        action.dig("data", "file") || parse_location(action["location"])[:path]
    end

    def action_line(action)
      action.dig("target", "line") || action["line"] || action.dig("data", "line") ||
        parse_location(action["location"])[:line] || 1
    end

    def diagnostic_code(diagnostic)
      diagnostic["code"].to_s.empty? ? "diagnostic" : diagnostic["code"].to_s
    end

    def diagnostic_path(diagnostic)
      diagnostic["path"] || diagnostic["file"] || parse_location(diagnostic["location"] || diagnostic["message"])[:path]
    end

    def diagnostic_line(diagnostic)
      diagnostic["line"] || parse_location(diagnostic["location"] || diagnostic["message"])[:line] || 1
    end

    def parse_location(text)
      match = text.to_s.match(%r{\b(?<path>(?:src|gems|tools|test|spec|lib|zig|transpile-tests)/[^:\s]+):(?<line>\d+)})
      return {} unless match

      { path: match[:path], line: match[:line].to_i }
    end

    def sarif_summary(evidence)
      if Schema::EvidenceBundle.v2?(evidence)
        {
          "schema_version" => evidence["schema_version"],
          "languages" => Array(evidence["languages"]),
          "static_files" => Array(evidence.dig("static", "files")).size,
          "static_methods" => Array(evidence.dig("static", "methods")).size,
          "actions" => sarif_actions(evidence).size,
          "diagnostics" => sarif_diagnostics(evidence).size
        }
      else
        {
          "target_dirs" => Array(evidence["target_dirs"]),
          "methods" => Array(evidence["methods"]).size,
          "runtime_observed_methods" => Array(evidence["methods"]).count { |m| m["calls"].to_i.positive? },
          "actions" => sarif_actions(evidence).size,
          "diagnostics" => sarif_diagnostics(evidence).size
        }
      end
    end

    def format_report_line(line)
      formatted = relativize_project_paths(line.to_s)
      formatted = format_code_references(formatted)
      @with_links ? link_report_paths(formatted) : formatted
    end

    def format_code_references(text)
      text.split("`", -1).each_with_index.map do |part, idx|
        next part if idx.odd?
        part.gsub(/\b([A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*#[A-Za-z_][A-Za-z0-9_]*[!?=]?)(?=\s|[:;,.)\]]|$)/, '`\1`')
          .gsub(/\b([A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\.[A-Za-z_][A-Za-z0-9_]*[!?=]?)(?!\()(?=\s|[:;,.)\]]|$)/, '`\1`')
      end.join("`")
    end

    def relativize_project_paths(text)
      root = File.expand_path(ROOT)
      text.gsub(root + File::SEPARATOR, "").gsub(root, ".")
    end

    def link_report_paths(text)
      text.gsub(%r{(?<![\[(])\b((?:src|gems|tools|sorbet|test|tmp)/[A-Za-z0-9_.\-/]+\.(?:rb|rbi|md|json|txt))(?:\:(\d+))?}) do
        path = Regexp.last_match(1)
        line = Regexp.last_match(2)
        label = line ? "#{path}:#{line}" : path
        target_path = link_target_for_path(path)
        target = line ? "#{target_path}#L#{line}" : target_path
        "[#{label}](#{target})"
      end
    end

    def link_target_for_path(path)
      report_dir = Pathname.new(File.dirname(@report_path || REPORT_PATH))
      target = Pathname.new(File.expand_path(path, ROOT))
      target.relative_path_from(report_dir).to_s
    rescue ArgumentError
      path
    end

    def prepare_linked_report(lines, full: false)
      lines = move_run_summary_after_body(lines)
      lines = insert_table_of_contents(lines)
      full ? collapse_long_bullet_runs(lines) : truncate_long_bullet_runs(lines)
    end

    def move_run_summary_after_body(lines)
      first_section_idx = lines.index { |line| line.match?(/\A##\s+/) }
      return lines unless first_section_idx && first_section_idx > 2
      title = lines[0, 2]
      summary = lines[2...first_section_idx].reject(&:empty?)
      body = lines[first_section_idx..]
      title + body + ["", "## Run Summary"] + summary
    end

    def insert_table_of_contents(lines)
      headings = lines.each_with_index.filter_map do |line, idx|
        next if idx.zero?
        match = line.match(/\A([#]{2,3})\s+(.+)\z/)
        next unless match
        level = match[1].length
        text = match[2]
        [level, text, github_anchor(text)]
      end
      return lines if headings.empty?
      toc = ["## Table of Contents"]
      headings.each do |level, text, anchor|
        indent = level == 3 ? "  " : ""
        toc << "#{indent}- [#{text}](##{anchor})"
      end
      lines[0, 2] + toc + [""] + lines[2..]
    end

    def github_anchor(text)
      text.downcase.gsub(/<[^>]+>/, "")
        .gsub(/`([^`]+)`/, "\\1")
        .gsub(/[^a-z0-9 _-]/, "")
        .strip
        .gsub(/\s+/, "-")
    end

    def collapse_long_bullet_runs(lines, visible_count = 10)
      out = []
      top_level_bullets = 0
      in_details = false
      in_toc = false
      close_details = lambda do
        if in_details
          out << ""
          out << "</details>"
          out << ""
          in_details = false
        end
      end
      lines.each do |line|
        if line.match?(/\A[#]{1,6}\s+/)
          close_details.call
          top_level_bullets = 0
          in_toc = line == "## Table of Contents"
          out << line
        elsif in_toc
          out << line
        elsif line.start_with?("- ")
          top_level_bullets += 1
          if top_level_bullets == visible_count + 1
            out << ""
            out << "<details><summary>More items</summary>"
            out << ""
            in_details = true
          end
          out << line
        elsif line.match?(/\A\s+- /)
          out << line
        elsif !line.empty?
          close_details.call
          top_level_bullets = 0
          out << line
        else
          out << line
        end
      end
      close_details.call
      out
    end

    def truncate_long_bullet_runs(lines, visible_count = 10)
      out = []
      top_level_bullets = 0
      hidden_top_level_bullets = 0
      in_toc = false
      flush_hidden = lambda do
        if hidden_top_level_bullets.positive?
          out << "- ... and #{hidden_top_level_bullets} more (run with `--full` to see all)"
          hidden_top_level_bullets = 0
        end
      end
      lines.each do |line|
        if line.match?(/\A[#]{1,6}\s+/)
          flush_hidden.call unless in_toc
          out << "" unless out.empty? || out.last == ""
          top_level_bullets = 0
          in_toc = line == "## Table of Contents"
          out << line
        elsif in_toc
          out << line
        elsif line.start_with?("- ")
          top_level_bullets += 1
          if top_level_bullets <= visible_count
            out << line
          else
            hidden_top_level_bullets += 1
          end
        elsif line.match?(/\A\s+- /)
          out << line if top_level_bullets <= visible_count
        elsif !line.empty?
          flush_hidden.call
          top_level_bullets = 0
          out << line
        else
          flush_hidden.call
          out << line
        end
      end
      flush_hidden.call
      out
    end

    def append_action_sections(lines, actions, by_conf)
      lines << ""
      append_review_actions(lines, by_conf[REVIEW] || [])
      append_high_actions(lines, by_conf[HIGH] || [])
      append_gap_actions(lines, by_conf[GAP] || [])
      extra_conf = by_conf.keys - [HIGH, REVIEW, GAP]
      extra_conf.each do |conf|
        list = by_conf[conf] || []
        lines << ""
        lines << "## #{conf} actions (#{list.size})"
        list.first(50).each { |a| lines << "- #{a["path"]}:#{a["line"]} #{a["kind"]}: #{a["message"]}" }
        lines << "- ... #{list.size - 50} more" if list.size > 50
      end
    end

    def append_project_prioritization(lines, evidence, actions)
      lines << ""
      lines << "## Project Prioritization"
      append_project_action_summary(lines, "Nil Source Fixes", actions.select { |action| action["kind"] == "nil_param_observed" }, "`T.nilable` slot(s)")
      append_project_action_summary(lines, "Union / T.any Candidates", actions.select { |action| %w[union_observed bad_input_type_candidate].include?(action["kind"]) }, "union slot(s)")
      append_project_hash_summary(lines, evidence)
      append_project_fallibility_summary(lines, evidence)
    end

    def grouped_action_priorities(actions)
      groups = {}
      actions.each do |action|
        site, calls = primary_action_callsite(action)
        site ||= "#{action["path"]}:#{action["line"]}"
        group = groups[site] ||= { "site" => site, "calls" => 0, "actions" => [] }
        group["calls"] += calls.to_i
        group["actions"] << action
      end
      groups.values.sort_by { |group| [-group["actions"].size, -group["calls"].to_i, group["site"]] }
    end

    def primary_action_callsite(action)
      callsites = action.dig("data", "callsites") || {}
      return [nil, 0] if callsites.empty?
      site, calls = callsites.max_by { |candidate, count| [count.to_i, candidate.to_s] }
      [site.to_s.sub(/:[^:]+\z/, ""), calls.to_i]
    end

    def append_project_action_summary(lines, title, actions, label)
      return if actions.empty?
      groups = grouped_action_priorities(actions)
      top = groups.first
      summary = "#{groups.size} action item(s), #{actions.size} #{label}"
      summary += "; top source affects #{top["actions"].size} slot(s), #{top["calls"].to_i} source calls" if top
      lines << "- #{report_section_link("#{title} (#{actions.size})")}: #{summary}"
    end

    def append_project_hash_summary(lines, evidence)
      candidates = hash_record_struct_candidates(evidence)
      pressure_rows = hash_record_struct_pressure(evidence)
      return if candidates.empty? && pressure_rows.empty?
      top = candidates.first
      unmatched = pressure_rows.count { |row| !candidate_matches_pressure?(candidates, row) }
      summary = "#{candidates.size} struct candidate(s), #{pressure_rows.size} pressure record(s)"
      summary += "; top candidate #{top["struct_name"]} has pressure #{top["total_pressure"]}" if top
      summary += "; #{unmatched} pressure record(s) without a literal shape cluster" if unmatched.positive?
      lines << "- #{report_section_link("Hash Record Struct Candidates (Shapes + Pressure)")}: #{summary}"
    end

    def append_project_fallibility_summary(lines, evidence)
      all_rows = Array(evidence.dig("facts", "fallibility_pressure"))
      rows = fallibility_display_rows(all_rows)
      return if all_rows.empty?

      top = rows.first
      hidden = all_rows.size - rows.size
      summary = "#{rows.size} material fallibility root(s), #{all_rows.size} total"
      summary += ", #{hidden} low-tail hidden" if hidden.positive?
      if top
        summary += "; top root #{top["label"]} participates in #{top["handler_pressure"].to_i} handler(s)"
        summary += " and leaks to #{Array(top["fallible_callers"]).size} caller(s)"
      end
      lines << "- #{report_section_link("Fallibility Pressure (#{rows.size})")}: #{summary}"
    end

    def report_section_link(title)
      "[#{title}](##{github_anchor(title)})"
    end

    def append_high_actions(lines, actions)
      lines << "## High-Confidence Actions (#{actions.size})"
      if actions.empty?
        lines << "- none"
        return
      end
      actions.first(50).each { |action| append_action_detail(lines, action) }
      lines << "- ... #{actions.size - 50} more" if actions.size > 50
    end

    def append_action_detail(lines, action)
      lines << "- #{action["path"]}:#{action["line"]} #{action["kind"]}: #{action["message"]}"
      method = method_at(action["path"], action["line"])
      if method
        lines << "  - method: #{method["class"]}##{method["method"]}"
        lines << "  - current: #{method["sig"]}" if method["sig"]
      end
      proposed = proposed_action_text(action, method)
      lines << "  - proposed: #{proposed}" if proposed
      evidence = action_evidence_text(action)
      lines << "  - evidence: #{evidence}" if evidence && !evidence.empty?
    end

    def append_review_actions(lines, actions)
      lines << ""
      lines << "## Review Actions (#{actions.size})"
      if actions.empty?
        lines << "- none"
        return
      end
      groups = [
        ["Default Replacement Candidates", actions.select { |a| a["kind"] == "replace_nil_with_default" }],
        ["Nil Source Fixes", actions.select { |a| a["kind"] == "nil_param_observed" }],
        ["Union / T.any Candidates", actions.select { |a| %w[union_observed bad_input_type_candidate].include?(a["kind"]) }],
        ["Missing Sigs Needing Manual Review", actions.select { |a| a["kind"] == "add_sig" }],
        ["Other Review Actions", actions.reject { |a| %w[replace_nil_with_default nil_param_observed union_observed bad_input_type_candidate add_sig].include?(a["kind"]) }],
      ]
      groups.each do |title, list|
        next if list.empty?
        list = list.sort_by { |action| action_sort_key(action) }
        lines << ""
        lines << "### #{title} (#{list.size})"
        if title == "Nil Source Fixes"
          append_grouped_review_actions(lines, list, "nil source fix", "nil source fixes")
        elsif title == "Union / T.any Candidates"
          append_grouped_review_actions(lines, list, "union candidate", "union candidates")
        else
          list.first(20).each { |action| append_review_action_line(lines, action) }
          lines << "- ... #{list.size - 20} more" if list.size > 20
        end
      end
    end

    def action_sort_key(action)
      site, calls = primary_action_callsite(action)
      [-calls.to_i, action["path"].to_s, action["line"].to_i, action.dig("data", "name").to_s, site.to_s]
    end

    def append_grouped_review_actions(lines, actions, singular_label, plural_label)
      groups = grouped_action_priorities(actions)
      total = actions.size
      groups.first(20).each do |group|
        affected = group["actions"].size
        calls = group["calls"].to_i
        noun = affected == 1 ? singular_label : plural_label
        lines << "- #{group["site"]}: affects #{affected} of #{total} #{noun}; source calls #{calls}"
        group["actions"].first(6).each { |action| append_review_action_line(lines, action, indent: "  ") }
      end
      lines << "- ... #{groups.size - 20} more source group(s)" if groups.size > 20
    end

    def append_review_action_line(lines, action, indent: "")
      case action["kind"]
      when "nil_param_observed"
        sites = top_action_sites(action)
        candidate = action.dig("data", "candidate_type")
        default = default_for_type(candidate)
        suffix = []
        suffix << "candidate #{candidate}" if NilKill.useful_type?(candidate)
        suffix << "auto-default #{default}" if default
        suffix << "top source #{sites.first}" unless sites.empty?
        detail = suffix.empty? ? "no non-nil candidate yet" : suffix.join("; ")
        lines << "#{indent}- #{action["path"]}:#{action["line"]} #{action.dig("data", "name")}; #{detail}"
      when "union_observed", "bad_input_type_candidate"
        classes = Array(action.dig("data", "classes") || action.dig("data", "raised_only_classes")).first(8).join(", ")
        classes += ", ..." if Array(action.dig("data", "classes") || action.dig("data", "raised_only_classes")).size > 8
        lines << "#{indent}- #{action["path"]}:#{action["line"]} #{action.dig("data", "name")}; observed #{classes}; #{top_action_sites(action).first || "no source callsite"}"
      when "replace_nil_with_default"
        lines << "#{indent}- #{action["path"]}:#{action["line"]} replace nil with #{action.dig("data", "default")} for #{action.dig("data", "target_method")}##{action.dig("data", "name")}; observed calls #{action.dig("data", "observed_calls")}"
      else
        lines << "#{indent}- #{action["path"]}:#{action["line"]} #{action["kind"]}: #{action["message"]}"
      end
    end

    def append_gap_actions(lines, actions)
      lines << ""
      lines << "## Gap Actions (#{actions.size})"
      if actions.empty?
        lines << "- none"
      else
        actions.first(50).each { |a| lines << "- #{a["path"]}:#{a["line"]} #{a["kind"]}: #{a["message"]}" }
        lines << "- ... #{actions.size - 50} more" if actions.size > 50
      end
    end

    def method_at(path, line)
      @method_at ||= (Array(@evidence["facts"]["existing_sigs"]) + Array(@evidence["facts"]["unsigned_methods"])).each_with_object({}) do |m, h|
        h[[m["path"], m["line"]]] = m
      end
      @method_at[[path, line]]
    end

    def default_for_type(type)
      case type
      when "Array", /\AT::Array\b/ then "[]"
      when "Hash", /\AT::Hash\b/ then "{}"
      when "String" then "\"\""
      else nil
      end
    end

    def proposed_action_text(action, method)
      case action["kind"]
      when "fix_sig_return"
        "change return to #{action.dig("data", "type")}"
      when "fix_sig_param"
        "change param #{action.dig("data", "name")} to #{action.dig("data", "type")}"
      when "narrow_tlet"
        "change T.let type to #{action.dig("data", "type")}"
      when "add_tlet"
        "wrap #{action.dig("data", "name")} in T.let(..., #{action.dig("data", "type")})"
      when "replace_nil_with_default"
        "replace nil with #{action.dig("data", "default")}"
      when "add_sig"
        action.dig("data", "sig") || (method && "add #{method["sig"]}")
      end
    end

    def action_evidence_text(action)
      data = action["data"] || {}
      parts = []
      parts << "#{data["observed_calls"]} observed call(s)" if data["observed_calls"]
      if data["type"]
        label = data["source"] == "static_return_origin" ? "static candidate" : "observed"
        parts << "#{label} #{data["type"]}"
      end
      sites = top_action_sites(action)
      parts << "top source #{sites.first}" unless sites.empty?
      parts.join("; ")
    end

    def top_action_sites(action, limit = 3)
      (action.dig("data", "callsites") || {}).sort_by { |_site, count| -count.to_i }.first(limit).map do |site, count|
        "#{site.sub(/:[^:]+\z/, "")}; source calls #{count}"
      end
    end

    def append_callsite_pressure(lines, actions)
      nil_pressure = callsite_pressure(actions, "nil_param_observed")
      union_pressure = merge_pressure(
        callsite_pressure(actions, "union_observed"),
        callsite_pressure(actions, "bad_input_type_candidate")
      )
      lines << ""
      lines << "## Nilability Pressure By Root Callsite"
      lines << "- pressure: how many review actions are attributed to the same source location"
      lines << "- root callsite: the caller/source location where nil entered one or more typed slots"
      append_pressure_list(lines, nil_pressure, "T.nilable")
      lines << ""
      lines << "## Union Pressure Downgraded To T.untyped"
      lines << "- downgrade: a slot observed with multiple runtime types was kept as `T.untyped` instead of emitted as `T.any(...)`"
      lines << "- why it happens: `T.any(...)` is risky when the runtime sample may not include every type that can reach the slot"
      lines << "Changing these to T.any(...) can be dangerous unless you are certain the runtime sample includes every type that can reach the slot. Static analysis can separately look for other types that could be passed without breaking the function."
      append_pressure_list(lines, union_pressure, "T.any")
      lines << ""
      lines << "## T.any Downgrades By Signature"
      lines << "- signature downgrade: an individual param or return slot where union evidence exists but the report kept the current `T.untyped` signature"
      actions.select { |a| a["kind"] == "union_observed" }.first(50).each do |action|
        classes = Array(action.dig("data", "classes")).join(", ")
        lines << "- #{action["path"]}:#{action["line"]} #{action.dig("data", "name")}: observed #{classes}; kept as T.untyped"
      end
    end

    def append_return_origin_report(lines, evidence)
      origins = untyped_return_origins(evidence)
      lines << ""
      lines << "## Return Origin Pressure"
      lines << "- origin: the expression or forwarded callee that currently determines a method's return type"
      lines << "- pressure: how many untyped returns could be improved by fixing the same origin"
      lines << "- cascading return fix: a return annotation that can unlock other forwarded-return annotations after it becomes typed"
      if origins.empty?
        lines << "- none"
        return
      end
      grouped = origins.group_by { |origin| origin["confidence"] }
      %w[blocked weak strong].each do |confidence|
        list = grouped[confidence] || []
        lines << "- #{confidence}: #{list.size}"
      end
      root_pressure = return_root_pressure(origins, evidence)
      cascade_pressure = return_cascade_pressure(origins, evidence)
      forwarded_pressure = forwarded_return_blocker_pressure(origins, evidence)
      if root_pressure.empty?
        lines << "- no untyped/nil root pressure found"
      else
        lines << ""
        lines << "Top root return blockers:"
        root_pressure.first(30).each do |root, data|
          suggestion = data["suggestion"] ? "; suggestion #{data["suggestion"]}" : ""
          lines << "- #{root}; affects #{data["methods"].size} return(s); #{data["count"]} source occurrence(s)#{suggestion}"
          data["examples"].first(4).each { |example| lines << "  - #{example}" }
        end
      end
      unless cascade_pressure.empty?
        lines << ""
        lines << "Top cascading return fixes:"
        cascade_pressure.first(20).each do |root, data|
          suggestion = data["suggestion"] ? "; suggestion #{data["suggestion"]}" : ""
          lines << "- #{root}; may unlock #{data["returns"].size} return(s) (#{data["direct"].size} direct, #{data["cascade"].size} cascading), #{data["params"].size} possible param flow(s)#{suggestion}"
          data["examples"].first(4).each { |example| lines << "  - #{example}" }
        end
      end
      unless forwarded_pressure.empty?
        lines << ""
        lines << "Forwarded return blocker pressure:"
        forwarded_pressure.first(20).each do |callee, data|
          lines << "- #{callee}: #{data["status"]}; affects #{data["returns"].size} return(s), #{data["params"].size} possible param flow(s)"
          data["examples"].first(4).each { |example| lines << "  - #{example}" }
        end
      end
      action_items = root_pressure.select { |_root, data| data["suggestion"] }.first(20)
      unless action_items.empty?
        lines << ""
        lines << "High-impact root return actions:"
        action_items.each do |root, data|
          lines << "- #{root}: #{data["suggestion"]}; may unblock #{data["methods"].size} return(s)"
        end
      end
      blocked = origins.select { |origin| origin["confidence"] == "blocked" }
      unless blocked.empty?
        lines << ""
        lines << "Blocked return examples:"
        blocked.first(12).each do |origin|
          method = "#{origin["class"]}##{origin["method"]}"
          blocker = Array(origin["blockers"]).first || "no blocker recorded"
          lines << "- #{origin["path"]}:#{origin["line"]} #{method}: #{blocker}"
        end
      end
    end

    def append_type_dependency_pressure(lines, evidence)
      pressure = type_dependency_pressure(evidence).select do |row|
        !row.dig("candidate_data", "candidate_kind").to_s.empty?
      end
      lines << ""
      lines << "## Type Dependency Unlock Pressure"
      lines << "- definite lower bound: each row counts only slots that become resolvable from this annotation alone"
      lines << "- conjunctive joins are excluded unless the same annotation satisfies every unresolved input"
      if pressure.empty?
        lines << "- none"
        return
      end
      pressure.first(30).each do |row|
        candidate = row["candidate_data"]
        counts = row["counts"]
        location = [candidate["file"], candidate["line"]].compact.join(":")
        label = candidate["label"] || candidate["name"] || row["candidate"]
        kind = candidate["candidate_kind"] || candidate["kind"]
        breakdown = %w[flow_read return param].filter_map do |target_kind|
          count = counts[target_kind].to_i
          "#{count} #{target_kind.tr("_", " ")}" if count.positive?
        end
        suffix = breakdown.empty? ? "dependent facts" : breakdown.join(", ")
        lines << "- #{location} #{label} (#{kind}); definitely unlocks #{row["unlocked_ids"].size} #{suffix}"
      end
    end

    def untyped_return_origins(evidence)
      untyped = Array(evidence.dig("facts", "existing_sigs")).each_with_object(Set.new) do |method, set|
        next unless extract_return_type(method["sig"].to_s) == "T.untyped"
        set << [method["path"], method["line"].to_i, method["class"].to_s, method["method"].to_s, method["kind"].to_s]
      end
      Array(evidence.dig("facts", "return_origins")).select do |origin|
        untyped.include?([origin["path"], origin["line"].to_i, origin["class"].to_s, origin["method"].to_s, origin["kind"].to_s])
      end
    end

    def return_root_pressure(origins, evidence)
      usage = return_usage_by_name(evidence)
      pressure = Hash.new { |hash, key| hash[key] = { "count" => 0, "methods" => Set.new, "examples" => [] } }
      origins.each do |origin|
        method_key = "#{origin["path"]}:#{origin["line"]} #{origin["class"]}##{origin["method"]}"
        Array(origin["sources"]).each do |source|
          root = case source["kind"]
          when "call_untyped"
            "untyped callee #{source["callee"]}"
          when "setter_assignment_unknown"
            "setter assignment #{source["callee"]}"
          when "nil"
            "nil return at #{origin["path"]}:#{source["line"] || origin["line"]}"
          when "unknown"
            "unknown expression at #{origin["path"]}:#{source["line"] || origin["line"]}"
          else
            next
          end
          data = pressure[root]
          data["count"] += 1
          data["methods"] << method_key
          data["suggestion"] ||= root_return_suggestion(root, source, usage)
          data["examples"] << method_key if data["examples"].size < 6
        end
        Array(origin["blockers"]).each do |blocker|
          next unless blocker.include?("untyped callee") || blocker.include?("unknown return") || blocker.include?("safe navigation") ||
            blocker.include?("setter assignment")
          data = pressure[blocker]
          data["count"] += 1
          data["methods"] << method_key
          data["suggestion"] ||= root_return_suggestion(blocker, nil, usage)
          data["examples"] << method_key if data["examples"].size < 6
        end
      end
      pressure.sort_by { |_root, data| [-data["methods"].size, -data["count"]] }
    end

    def return_cascade_pressure(origins, evidence)
      usage = return_usage_by_name(evidence)
      indexed_origins = Array(evidence.dig("facts", "return_origins"))
      indexed_keys = indexed_origins.map { |origin| return_method_key(origin) }.to_set
      requested_keys = origins.map { |origin| return_method_key(origin) }.to_set
      rows = if requested_keys.subset?(indexed_keys)
        type_dependency_pressure(evidence)
      else
        facts = Hash(evidence["facts"]).merge("return_origins" => origins)
        FlowGraph.dependencies_from_evidence(evidence.merge("facts" => facts)).unlock_pressure
      end
      requested_methods = origins.map { |origin| origin["method"].to_s }.to_set
      rows.each_with_object({}) do |row, pressure|
        candidate = row["candidate_data"]
        next unless candidate["kind"] == "return_root"
        returns = row["unlocked_nodes"].select do |node|
          node["kind"] == "return" && requested_keys.include?(node["label"])
        end
        next if returns.empty?
        return_ids = returns.map { |node| node["id"] }.to_set
        direct = (row["direct_ids"].to_set & return_ids)
        params = row["unlocked_nodes"].select do |node|
          node["kind"] == "param" && requested_methods.include?(node["source_method"].to_s)
        end
          .map { |node| node["label"] }.compact.to_set
        root = candidate["label"]
        pressure[root] = {
          "returns" => return_ids,
          "direct" => direct,
          "cascade" => return_ids - direct,
          "params" => params,
          "suggestion" => root_return_suggestion(root, nil, usage),
          "examples" => returns.map { |node| node["label"] }.compact.first(6),
        }
      end.sort_by { |_root, data| [-data["returns"].size, -data["cascade"].size, -data["params"].size] }
    end

    def forwarded_return_blocker_pressure(origins, evidence)
      status = forwarded_return_status_index(evidence)
      param_flows = Array(evidence.dig("facts", "param_origins")).select { |origin| %w[typed_return untyped_return].include?(origin["origin_kind"]) }
      param_flows_by_source = param_flows.group_by { |flow| flow["source_method"].to_s }
      pressure = Hash.new { |hash, key| hash[key] = { "returns" => Set.new, "params" => Set.new, "examples" => [], "status" => "unknown" } }
      origins.each do |origin|
        callees = Array(origin["sources"]).select { |source| source["kind"].to_s == "call_untyped" }.map { |source| source["callee"].to_s }.reject(&:empty?)
        next if callees.empty?
        method_key = return_method_key(origin)
        callees.each do |callee|
          data = pressure[callee]
          data["status"] = status[callee] || "unresolved forwarded callee"
          data["returns"] << method_key
          data["examples"] << method_key if data["examples"].size < 6
        end
      end
      pressure.each do |callee, data|
        Array(param_flows_by_source[callee]).each do |flow|
          data["params"] << "#{flow["path"]}:#{flow["line"]} #{flow["callee"]}(#{flow["slot"]})"
        end
      end
      pressure.sort_by { |callee, data| [-data["returns"].size, -data["params"].size, callee] }.to_h
    end

    def forwarded_return_status_index(evidence)
      sig_types = Array(evidence.dig("facts", "existing_sigs")).each_with_object(Hash.new { |h, k| h[k] = [] }) do |method, types|
        ret = extract_return_type(method["sig"].to_s)
        types[method["method"].to_s] << ret if NilKill.useful_type?(ret)
      end
      sig_counts = Array(evidence.dig("facts", "existing_sigs")).each_with_object(Hash.new(0)) do |method, counts|
        counts[method["method"].to_s] += 1
      end
      origins = Array(evidence.dig("facts", "return_origins")).group_by { |origin| origin["method"].to_s }
      names = (sig_types.keys + origins.keys).uniq
      names.each_with_object({}) do |name, index|
        typed = Array(sig_types[name]).compact.uniq.reject { |type| type == "T.untyped" || type == "void" }
        if sig_counts[name] == 1 && typed.size == 1 && Array(sig_types[name]).compact.uniq.size == 1
          index[name] = "typed signature #{typed.first}"
          next
        end
        origin_list = Array(origins[name])
        if origin_list.size > 1
          index[name] = "ambiguous method name"
        elsif origin_list.size == 1 && NilKill.useful_type?(origin_list.first["candidate_type"]) && !NilKill.weak_type?(origin_list.first["candidate_type"])
          index[name] = "static candidate #{origin_list.first["candidate_type"]}"
        elsif origin_list.size == 1
          index[name] = "callee return still untyped"
        end
      end
    end

    def return_method_key(origin)
      "#{origin["path"]}:#{origin["line"]} #{origin["class"]}##{origin["method"]}"
    end

    def root_return_suggestion(root, source, usage = {})
      if root.start_with?("setter assignment ") || root.match?(/\b\w+=\b/)
        return "model assignment syntax as returning the assigned RHS; type the RHS source or avoid using setter assignment as method return"
      end
      callee = source&.dig("callee") || root[/untyped callee ([^ ;]+)/, 1]
      stats = usage[callee.to_s]
      if stats && stats["value"].zero? && stats["return"].positive?
        return "void candidate: return is only forwarded into other returns, never used as a value"
      elsif stats && stats["value"].zero? && stats["statement"].positive?
        return "void candidate: return is only used as a statement"
      end
      case callee
      when "raise"
        "mark as no-return/raises path, or keep callers from using it as a value"
      when "puts", "print"
        "review as void side-effect helper"
      when "each", "each_pair", "each_value"
        "review as receiver-returning iterator; callers probably want explicit return value"
      when "any?", "include?", "==", "!"
        "review as boolean return"
      when "join", "to_s", "chomp", "rstrip"
        "review as String return"
      when "[]"
        "review as nilable lookup or replace with fetch/typed accessor"
      when "[]=", "<<"
        "review as mutation expression; prefer explicit return after side effect"
      else
        nil
      end
    end

    def return_usage_by_name(evidence)
      names = Array(evidence.dig("facts", "existing_sigs")).filter_map { |method| method["method"].to_s }.to_set
      usage = Hash.new { |hash, key| hash[key] = { "value" => 0, "return" => 0, "statement" => 0 } }
      return usage if names.empty?

      if evidence.dig("facts")&.key?("return_direct_usage_sites")
        Array(evidence.dig("facts", "return_direct_usage_sites")).each do |site|
          name = site["name"].to_s
          next unless names.include?(name)
          context = site["context"].to_s
          next unless usage[name].key?(context)
          usage[name][context] += 1
        end
        return usage
      end

      evidence_target_files(evidence).each do |path|
        parsed = NilKill.cached_parse_file(path)
        next unless parsed.success?
        mark_return_usage(parsed.value, :statement, names, usage)
      rescue StandardError
        next
      end
      usage
    end

    def evidence_target_files(evidence)
      return [] unless evidence.is_a?(Hash) && evidence.key?("target_dirs")

      dirs = Array(evidence["target_dirs"]).map(&:to_s).reject(&:empty?)
      return [] if dirs.empty?

      excludes = Array(evidence["target_exclude_dirs"]).map { |dir| File.expand_path(dir.to_s, ROOT) }
      dirs.flat_map do |dir|
        abs = File.expand_path(dir, ROOT)
        File.directory?(abs) ? Dir.glob(File.join(abs, "**", "*.rb")) : [abs]
      end.select do |path|
        File.file?(path) && excludes.none? { |dir| path == dir || path.start_with?(dir + File::SEPARATOR) }
      end.sort
    end

    def mark_return_usage(node, context, names, usage)
      return unless node
      case node
      when Syntax::DefNode
        mark_return_usage(node.body, :return, names, usage)
      when Syntax::BodyStatementNode, Syntax::BeginNode
        mark_return_usage(node.statements, context, names, usage)
      when Syntax::StatementsNode
        body = node.body || []
        body.each_with_index do |child, idx|
          mark_return_usage(child, idx == body.length - 1 ? context : :statement, names, usage)
        end
      when Syntax::ReturnNode, Syntax::ArgumentsNode
        node.child_nodes.compact.each { |child| mark_return_usage(child, :return, names, usage) }
      when Syntax::IfNode
        mark_return_usage(node.predicate, :value, names, usage) if node.respond_to?(:predicate)
        mark_return_usage(node.statements, context, names, usage)
        mark_return_usage(node.subsequent, context, names, usage)
      when Syntax::ElseNode
        mark_return_usage(node.statements, context, names, usage)
      when Syntax::CallNode
        usage[node.name.to_s][context.to_s] += 1 if names.include?(node.name.to_s)
        node.child_nodes.compact.each { |child| mark_return_usage(child, :value, names, usage) }
      else
        node.child_nodes.compact.each { |child| mark_return_usage(child, :value, names, usage) } if node.respond_to?(:child_nodes)
      end
    end

    def append_return_hygiene_report(lines, evidence, heading_level: 2)
      rows = return_hygiene_rows(evidence)
      lines << ""
      lines << "#{"#" * heading_level} Return Hygiene"
      lines << "- control shape: whether the method return is branchless or depends on branching control flow"
      lines << "- return syntax: whether the method uses implicit return, explicit `return`, or a mix"
      lines << "- return value usage: whether static callsites use this method's return value, forward it, or ignore it"
      lines << "- return source kind: the kind of expression that produces the return value"
      lines << "- fixability: the report's estimate of whether the return is already addressed, high-evidence, cascading, or needs more evidence"
      lines << "- row percent: share of all return slots; strength percents: share within that row"
      if rows.empty?
        lines << "- none"
        return
      end

      total = rows.size
      counts = return_hygiene_type_counts(rows)
      lines << "- Return slots indexed: #{total}"
      lines << "- Return slot strength: #{format_hygiene_strength_counts(counts, total)}"
      append_hygiene_bucket_lines(lines, "Control Shape", rows, "control_shape", total)
      append_hygiene_bucket_lines(lines, "Return Syntax", rows, "return_syntax", total)
      append_hygiene_bucket_lines(lines, "Return Value Usage", rows, "usage", total)
      append_hygiene_bucket_lines(lines, "Return Source Kind", rows, "source_kind", total)
      append_hygiene_bucket_lines(lines, "Fixability", rows, "fixability", total)

      easy = rows.select { |row| row["fixability"].start_with?("addressed") || row["fixability"].start_with?("high action") }
      addressed = easy.count { |row| row["fixability"].start_with?("addressed") }
      lines << "- Easily addressable/addressed returns: #{format_hygiene_count(addressed, easy.size)}"

      action_rows = rows.select { |row| row["return_type"] == "T.untyped" && !row["fixability"].start_with?("addressed") }
        .sort_by { |row| [hygiene_fixability_rank(row["fixability"]), row["path"], row["line"].to_i] }
      unless action_rows.empty?
        lines << ""
        lines << "#### Top Return Hygiene Actions"
        lines << ""
        action_rows.first(20).each do |row|
          lines << "- #{row["path"]}:#{row["line"]} #{row["class"]}##{row["method"]}: #{row["fixability"]}; #{row["usage"]}; #{row["source_kind"]}"
        end
      end
    end

    def append_hygiene_bucket_lines(lines, title, rows, key, total)
      lines << ""
      lines << "#### #{title}"
      lines << ""
      rows.group_by { |row| row[key] }.sort_by { |name, list| [-list.size, name] }.each do |name, list|
        counts = return_hygiene_type_counts(list)
        lines << "- #{name}: total #{format_hygiene_count(list.size, total)} of all returns; #{format_hygiene_strength_counts(counts, list.size)} within row"
      end
    end

    def format_hygiene_count(count, total)
      return "#{count} (0.0%)" if total.to_i.zero?
      "#{count} (#{format("%.1f", (count.to_f * 100.0) / total)}%)"
    end

    def return_hygiene_type_counts(rows)
      rows.each_with_object(empty_type_counts) do |row, counts|
        classify_type!(counts, row["return_type"])
      end
    end

    def format_hygiene_strength_counts(counts, total)
      "strong #{format_hygiene_count(counts["strong"], total)}; " \
        "weak #{format_hygiene_count(counts["weak"], total)}; " \
        "untyped #{format_hygiene_count(counts["untyped"], total)}; " \
        "nilable #{format_hygiene_count(counts["nilable"], total)}"
    end

    def hygiene_fixability_rank(fixability)
      case fixability
      when /\Ahigh action: void/ then 0
      when /\Ahigh action/ then 1
      when /\Acascade/ then 2
      when /\Aneeds collection/ then 3
      else 4
      end
    end

    def return_hygiene_rows(evidence)
      origins = Array(evidence.dig("facts", "return_origins")).each_with_object({}) do |origin, lookup|
        lookup[[origin["path"], origin["line"].to_i, origin["class"].to_s, origin["method"].to_s, origin["kind"].to_s]] = origin
      end
      graph = return_usage_graph_summary(evidence)
      direct_usage = return_usage_by_name(evidence)
      action_lookup = return_fix_action_lookup(evidence)

      Array(evidence.dig("facts", "existing_sigs")).filter_map do |method|
        sig = method["sig"].to_s
        return_type = sig.match?(/\bvoid\b/) ? "void" : extract_return_type(sig)
        next unless return_type

        origin = method["return_origin"] ||
          origins[[method["path"], method["line"].to_i, method["class"].to_s, method["method"].to_s, method["kind"].to_s]] || {}
        usage = return_usage_bucket(method, return_type, graph, direct_usage)
        source_kind = return_hygiene_source_kind(origin)
        action = action_lookup[[method["path"], method["line"].to_i]]
        {
          "path" => method["path"],
          "line" => method["line"],
          "class" => method["class"],
          "method" => method["method"],
          "return_type" => return_type,
          "control_shape" => origin["control_shape"] || "unknown control shape",
          "return_syntax" => origin["return_syntax"] || (origin["implicit"] ? "implicit" : "unknown syntax"),
          "usage" => usage,
          "source_kind" => source_kind,
          "fixability" => return_hygiene_fixability(return_type, usage, source_kind, action, origin),
        }
      end
    end

    def return_fix_action_lookup(evidence)
      Array(evidence["actions"]).each_with_object({}) do |action, lookup|
        next unless action["kind"] == "fix_sig_return"
        key = [action["path"], action["line"].to_i]
        current = lookup[key]
        lookup[key] = action if current.nil? || return_fix_action_rank(action) < return_fix_action_rank(current)
      end
    end

    def return_fix_action_rank(action)
      return 0 if action["confidence"] == HIGH
      return 1 if action["confidence"] == REVIEW
      2
    end

    def return_usage_graph_summary(evidence)
      candidates = Array(evidence.dig("facts", "existing_sigs")).select do |method|
        sig = method["sig"].to_s
        sig.match?(/\bvoid\b/) || extract_return_type(sig)
      end
      candidates_by_name = candidates.group_by { |method| method["method"].to_sym }
      candidate_names = candidates_by_name.select { |_name, methods| methods.size == 1 }.keys.to_set
      method_return_types = unambiguous_method_return_types(evidence)
      used = Set.new
      return_edges = Hash.new { |hash, key| hash[key] = Set.new }
      return { "candidate_names" => candidate_names, "used" => used, "return_edges" => return_edges } if candidate_names.empty?

      if evidence.dig("facts")&.key?("return_usage_sites")
        apply_return_usage_sites(Array(evidence.dig("facts", "return_usage_sites")), candidate_names, method_return_types, used, return_edges)
        propagate_return_usage!(used, return_edges)
        return { "candidate_names" => candidate_names, "used" => used, "return_edges" => return_edges }
      end

      evidence_target_files(evidence).each do |path|
        parsed = NilKill.cached_parse_file(path)
        next unless parsed.success?
        mark_return_usage_graph(parsed.value, :statement, nil, candidate_names, method_return_types, used, return_edges)
      rescue StandardError
        next
      end
      propagate_return_usage!(used, return_edges)
      { "candidate_names" => candidate_names, "used" => used, "return_edges" => return_edges }
    end

    def return_usage_bucket(method, return_type, graph, direct_usage)
      return "declared void" if return_type == "void"
      return "declared noreturn" if return_type == "T.noreturn"

      name = method["method"].to_sym
      stats = direct_usage[method["method"].to_s] || { "value" => 0, "return" => 0, "statement" => 0 }
      return "ambiguous method name" unless graph["candidate_names"].include?(name)
      return "used as value" if graph["used"].include?(name) || stats["value"].positive?
      return "unused via return-forwarding" if stats["return"].positive?
      return "unused statement-only" if stats["statement"].positive?
      "no static callsites found"
    end

    def return_hygiene_source_kind(origin)
      sources = Array(origin["sources"])
      return "unknown source" if sources.empty?

      kinds = sources.map { |source| source["kind"].to_s }.to_set
      return "struct/class field or instance variable" if kinds.include?("ivar_read")
      return "collection lookup" if sources.any? { |source| collection_lookup_source?(source) }
      return "mutation/setter assignment" if kinds.include?("assignment") || kinds.include?("setter_assignment_unknown")
      return "mixed sources" if sources.any? { |source| ruby_stdlib_source?(source) } && !ruby_stdlib_return_sources?(sources)
      return "Ruby stdlib call" if ruby_stdlib_return_sources?(sources)
      if kinds.any? { |kind| %w[typed_call typed_call_inferred call_untyped safe_call].include?(kind) }
        return "#{origin["return_syntax"] || "unknown syntax"}/direct forwarded return"
      end
      return "literal/static" if kinds.all? { |kind| %w[static nil].include?(kind) }
      return "mixed sources" if kinds.size > 1
      "unknown source"
    end

    def collection_lookup_source?(source)
      source["callee"].to_s == "[]" || source["code"].to_s.match?(/\[[^\]]*\]/) ||
        source["type"].to_s.match?(/\AT::(?:Array|Hash|Enumerable|Set)\b/)
    end

    def ruby_stdlib_source?(source)
      return false unless %w[typed_call safe_call].include?(source["kind"].to_s)
      callee = source["callee"].to_s
      source["stdlib"] || (!callee.empty? && NilKill.rbi_return_type(callee))
    end

    def ruby_stdlib_return_sources?(sources)
      useful = Array(sources).reject { |source| source["kind"].to_s == "nil" }
      return false unless useful.any? { |source| ruby_stdlib_source?(source) }
      !useful.empty? && useful.all? do |source|
        ruby_stdlib_source?(source) || source["kind"].to_s == "static"
      end
    end

    def return_hygiene_fixability(return_type, usage, source_kind, action = nil, origin = nil)
      return "addressed: void" if return_type == "void"
      return "addressed: noreturn" if return_type == "T.noreturn"
      return "addressed: #{return_hygiene_type_strength(return_type)}" if return_type != "T.untyped"
      if action && action["confidence"] == HIGH
        type = action.dig("data", "type") || "return"
        return "high action: #{type}"
      end
      if action
        type = action.dig("data", "type") || "return"
        source = action.dig("data", "source") || action["confidence"]
        return "review action: #{type} from #{source}"
      end
      if ["literal/static", "Ruby stdlib call", "mutation/setter assignment"].include?(source_kind)
        candidate = origin && origin["candidate_type"]
        return "missing action: static/RBI candidate #{candidate}" if NilKill.useful_type?(candidate)
        return "missing action: no singular static/RBI candidate"
      end
      return "cascade: forwarded return" if source_kind.include?("forwarded return")
      return "needs collection/field evidence" if source_kind == "collection lookup" || source_kind.include?("instance variable")
      "manual review"
    end

    def return_hygiene_type_strength(type)
      inner = strip_nilable(type.to_s.strip)
      return "untyped" if untyped_type?(inner)
      return "weak" if weak_type?(inner)
      "strong"
    end

    def append_param_origin_report(lines, evidence)
      origins = Array(evidence.dig("facts", "param_origins"))
      lines << ""
      lines << "## Input Param Origin Backflow"
      lines << "- origin: the caller-side expression passed into a parameter slot"
      lines << "- backflow: tracing weak or untyped parameter pressure backward from the callee slot to the caller expression that supplied it"
      lines << "- return-to-param flow: a method return value that is later passed into another method's parameter"
      if origins.empty?
        lines << "- none"
        return
      end
      counts = origins.group_by { |origin| origin["origin_kind"] }.transform_values(&:size)
      lines << "- Origins indexed: #{origins.size}"
      counts.sort_by { |kind, count| [-count, kind] }.each do |kind, count|
        lines << "- #{kind}: #{count}"
      end
      return_flows = origins.select { |origin| %w[typed_return untyped_return].include?(origin["origin_kind"]) }
      unless return_flows.empty?
        lines << ""
        lines << "Return-to-param flows:"
        return_flows.group_by { |origin| origin["source_method"] || "unknown" }.sort_by { |_method, list| -list.size }.first(20).each do |method, list|
          examples = list.first(4).map { |origin| "#{origin["path"]}:#{origin["line"]} -> #{origin["callee"]}(#{origin["slot"]})" }
          lines << "- #{method}: #{list.size} flow(s); #{examples.join("; ")}"
        end
      end
    end

    def append_foreign_class_pressure(lines, evidence)
      pressure = foreign_class_pressure(evidence)
      lines << ""
      lines << "## Foreign Scalar Inputs Into Object-Typed Params"
      lines << "This ranks caller origins where `String`/`Symbol` values flow into params that also receive object instances. It skips `src/tools` origins unless `NIL_KILL_FOREIGN_INCLUDE_TOOLS=1`."
      if pressure.empty?
        lines << "- none"
        return
      end
      pressure.sort_by { |_origin, data| [-data["calls"], -data["slots"].size] }.first(50).each do |origin, data|
        lines << "- #{origin} #{source_line(origin)}; #{data["calls"]} foreign scalar call(s), affects #{data["slots"].size} slot(s)"
        data["examples"].values.sort_by { |example| -example["calls"] }.first(6).each do |example|
          desired = Array(example["desired"]).first(5).join(", ")
          foreign = Array(example["foreign"]).first(5).join(", ")
          trace = example["trace"].empty? ? "" : "; trace #{example["trace"].first(4).join(" -> ")}"
          lines << "  - #{example["sink"]} #{example["param"]}: #{foreign} into #{desired} (#{example["calls"]})#{trace}"
        end
      end
    end

    def foreign_class_pressure(evidence)
      pressure = Hash.new { |h, k| h[k] = { "calls" => 0, "slots" => Set.new, "examples" => {} } }
      Array(evidence["methods"]).each do |rec|
        source = rec["source"]
        next unless source
        params = rec["params_ok"].empty? ? rec["params_by_name"] : rec["params_ok"]
        traces = rec["param_traces_ok"].empty? ? rec["param_traces"] : rec["param_traces_ok"]
        sites = rec["param_sites_ok"].empty? ? rec["param_sites"] : rec["param_sites_ok"]
        params.each do |name, classes|
          foreign = Array(classes) & foreign_scalar_classes
          desired = desired_object_classes(classes)
          next if foreign.empty? || desired.empty?
          each_foreign_origin(rec, name, foreign, traces[name], sites[name]) do |origin, count, trace|
            next if skip_foreign_origin?(origin)
            slot = "#{source["path"]}:#{source["line"]}:#{name}"
            sink = "#{source["path"]}:#{source["line"]} #{source["class"]}##{source["method"]}"
            data = pressure[origin]
            data["calls"] += count.to_i
            data["slots"] << slot
            key = "#{slot}:#{foreign.sort.join("/")}"
            ex = (data["examples"][key] ||= { "sink" => sink, "param" => name, "desired" => desired,
              "foreign" => foreign, "calls" => 0, "trace" => trace })
            ex["calls"] += count.to_i
          end
        end
      end
      pressure
    end

    def foreign_scalar_classes
      %w[String Symbol]
    end

    def desired_object_classes(classes)
      Array(classes).compact.uniq.reject do |klass|
        klass == "NilClass" || klass == "T.untyped" || foreign_scalar_classes.include?(klass) ||
          klass.include?("#") || klass.start_with?("Sorbet::Private::") || klass.match?(/\A(?:Integer|Float|TrueClass|FalseClass)\z/)
      end.select { |klass| klass.match?(/\A[A-Z]/) }.sort
    end

    def each_foreign_origin(rec, name, foreign, traces, sites)
      if traces && !traces.empty?
        traces.each do |trace_key, count|
          trace, klass = split_trace_key(trace_key)
          next unless foreign.include?(klass)
          origin = trace_origin(rec, trace)
          yield origin, count, trace if origin
        end
      else
        filter_sites_by_class(sites, foreign).each do |site, count|
          root = site.sub(/:[^:]+\z/, "")
          yield root, count, [root]
        end
      end
    end

    def split_trace_key(trace_key)
      trace_part, _sep, klass = trace_key.to_s.rpartition(":")
      [trace_part.split("|"), klass]
    end

    def trace_origin(rec, trace)
      source = rec["source"] || {}
      trace.find do |frame|
        path, line = split_site(frame)
        next false unless path && line
        rel = NilKill.rel(path)
        !(rel == source["path"] && line >= source["line"].to_i && line <= source.fetch("end_line", source["line"]).to_i)
      end
    end

    def skip_foreign_origin?(origin)
      return false if ENV["NIL_KILL_FOREIGN_INCLUDE_TOOLS"] == "1"
      rel = NilKill.rel(origin.sub(/:\d+\z/, ""))
      rel.start_with?("src/tools/")
    end

    def source_line(origin)
      path, line = split_site(origin)
      return "" unless path && line
      source = File.readlines(path)[line - 1]&.strip
      source && !source.empty? ? "`#{source[0, 160]}`" : ""
    rescue Errno::ENOENT
      ""
    end

    def split_site(site)
      match = site.to_s.match(/\A(.+):(\d+)\z/)
      match ? [match[1], match[2].to_i] : [nil, nil]
    end

    def filter_sites_by_class(sites, classes)
      wanted = Array(classes).to_set
      (sites || {}).select { |site, _count| wanted.include?(site.to_s.split(":").last) }
    end

    def append_type_normalizer_report(lines, evidence)
      normalizers = Array(evidence.dig("facts", "type_normalizers"))
      lines << ""
      lines << "## Type Normalizer Sites"
      lines << "- Sites matching `is_a?(Type)` plus `Type.new(...)`: #{normalizers.size}"
      if normalizers.empty?
        lines << "- none"
        return
      end
      grouped = normalizers.group_by { |site| site["path"] }
      grouped.sort_by { |path, sites| [-sites.size, path] }.first(20).each do |path, sites|
        lines << "- #{path}: #{sites.size}"
        sites.first(5).each do |site|
          method = [site["class"], site["method"]].compact.reject(&:empty?).join("#")
          method = "top-level" if method.empty?
          lines << "  - line #{site["line"]} #{method}: #{site["code"]}"
        end
        lines << "  - ... #{sites.size - 5} more" if sites.size > 5
      end
    end

    def append_fallibility_pressure_report(lines, evidence)
      all_rows = Array(evidence.dig("facts", "fallibility_pressure"))
      rows = fallibility_display_rows(all_rows)
      hidden = all_rows.size - rows.size
      lines << ""
      lines << "## Fallibility Pressure (#{rows.size})"
      lines << "- pressure: direct failure roots ranked by static raises, runtime raises, unhandled caller fan-out, and rescue/fallback handler participation"
      lines << "- handler participation is shared attribution: a root participates in a rescue if a protected project call can reach it; shared handlers may have other causes too"
      lines << "- display threshold: score >= #{FALLIBILITY_DISPLAY_SCORE}, or any handler/runtime raise pressure; hidden low-tail roots: #{hidden}" if hidden.positive?
      if all_rows.empty?
        lines << "- none"
        return
      end
      if rows.empty?
        lines << "- none above display threshold"
        return
      end

      rows.first(50).each do |row|
        runtime = row["runtime"] || {}
        direct_sources = Array(row["direct_sources"])
        callers = Array(row["fallible_callers"])
        handlers = Array(row["handlers"])
        raised = "#{runtime["raised_calls"].to_i}/#{runtime["calls"].to_i}"
        classes = Array(runtime["raised_classes"]).first(4).join(", ")
        class_text = classes.empty? ? "" : "; raised #{classes}"
        lines << "- #{row["path"]}:#{row["line"]} #{row["label"]}: score #{row["score"].to_i}; " \
                 "direct sources #{direct_sources.size}; runtime raises #{raised} (#{runtime["raised_rate"].to_f}%#{class_text}); " \
                 "handlers #{row["handler_pressure"].to_i} (exclusive #{row["exclusive_handlers"].to_i}, shared #{row["shared_handlers"].to_i}); " \
                 "unhandled callers #{callers.size}"
        direct_sources.first(3).each do |source|
          lines << "  - source: #{source["path"]}:#{source["line"]} #{source["kind"]} `#{source["code"]}`"
        end
        lines << "  - ... #{direct_sources.size - 3} more source(s)" if direct_sources.size > 3
        handlers.first(3).each do |handler|
          shared = Array(handler["roots"]).size > 1 ? "shared" : "exclusive"
          protected_calls = Array(handler["protected_calls"]).first(4).join(" | ")
          roots = Array(handler["roots"]).first(4).join(" | ")
          lines << "  - handler: #{handler["path"]}:#{handler["line"]} #{handler["method"]} #{shared}; protected #{protected_calls}; roots #{roots}"
        end
        lines << "  - ... #{handlers.size - 3} more handler(s)" if handlers.size > 3
        unless callers.empty?
          preview = callers.first(5).join(" | ")
          lines << "  - unhandled callers: #{preview}#{callers.size > 5 ? " | ..." : ""}"
        end
      end
      lines << "- ... #{rows.size - 50} more fallibility root(s)" if rows.size > 50
    end

    def fallibility_display_rows(rows)
      rows.select do |row|
        row["score"].to_i >= FALLIBILITY_DISPLAY_SCORE ||
          row["handler_pressure"].to_i.positive? ||
          row.dig("runtime", "raised_calls").to_i.positive?
      end
    end

    def append_hygiene_overview(lines, evidence)
      lines << ""
      lines << "## Hygiene Overview"
      append_type_soundness_table(lines, evidence)
      append_untyped_slot_name_pressure(lines, evidence)
      append_untyped_cause_table(lines, evidence)
      append_union_decomplexity(lines, evidence)
      append_deterministic_guard_collapse(lines, evidence)
      append_node_alias_candidates(lines, evidence)
      append_untyped_evidence_gaps(lines, evidence)
      append_signature_slot_evidence(lines, evidence)
      append_return_hygiene_report(lines, evidence, heading_level: 3)
    end

    UNION_DECOMPLEXITY_TOP_N = 30

    GUARD_RECEIVER_RE = /(@?[A-Za-z_]\w*)\.is_a\?\(Type\)/.freeze

    # type_normalizers are defensive `recv.is_a?(Type) ? recv :
    # Type.new(recv)` guards. Each one exists because some slot feeding
    # `recv` is sometimes Type, sometimes raw. Index: [class,method] ->
    # receiver-name -> { count:, sites:[loc...] }. Receiver-name is the
    # contract the guard protects; strip a leading @ so an ivar receiver
    # keys the same as its slot.
    def type_normalizer_guard_index(evidence)
      idx = Hash.new { |h, k| h[k] = Hash.new { |g, r| g[r] = { "count" => 0, "sites" => [] } } }
      Array(evidence.dig("facts", "type_normalizers")).each do |site|
        recv = site["code"].to_s[GUARD_RECEIVER_RE, 1]
        next unless recv
        recv = recv.sub(/\A@/, "")
        cell = idx[[site["class"].to_s, site["method"].to_s]][recv]
        cell["count"] += 1
        cell["sites"] << "#{site["path"]}:#{site["line"]}" if cell["sites"].size < 3
        # Keep the first resolved one-hop origin for this receiver (the
        # collector tags every guard site identically per receiver).
        if cell["origin_kind"].nil? && site["origin_kind"]
          cell["origin_kind"] = site["origin_kind"]
          cell["origin_name"] = site["origin_name"]
        end
      end
      idx
    end

    # Runtime classes empirically observed flowing OUT of every method
    # name (its return values) and into every ivar (its assignments).
    # This is the lower-cost producer substrate: no static points-to,
    # just the facts the tracer already gathers, keyed for the origin
    # join below.
    def runtime_return_classes_by_method(evidence)
      idx = Hash.new { |h, k| h[k] = [] }
      Array(evidence["methods"]).each do |m|
        next unless m["method"]
        idx[m["method"].to_s].concat(Array(m["returns"]))
      end
      idx.transform_values { |cs| cs.uniq.select { |c| NilKill.useful_type?(c.to_s) } }
    end

    def runtime_ivar_classes(evidence)
      idx = Hash.new { |h, k| h[k] = [] }
      (Array(evidence.dig("facts", "struct_field_runtime")) +
       Array(evidence.dig("facts", "struct_field_static"))).each do |f|
        next unless f["class"] && f["field"]
        cs = Array(f["classes"]) + [f["type"]].compact
        idx[[f["class"].to_s, f["field"].to_s]].concat(cs)
      end
      Array(evidence.dig("facts", "ivar_runtime")).each do |f|
        next unless f["class"] && f["name"]
        idx[[f["class"].to_s, f["name"].to_s.sub(/\A@/, "")]].concat(Array(f["classes"]))
      end
      idx.transform_values { |cs| cs.uniq.select { |c| NilKill.useful_type?(c.to_s) } }
    end

    # Accessor/ivar contracts in Union Decomplexity aggregate GLOBALLY
    # by name (`.type_info` is one contract across ~38 classes/methods).
    # A like-named accessor is overwhelmingly backed by the like-named
    # ivar, so the producer types for `.type_info` = the union of every
    # `@type_info` runtime class set, regardless of declaring class.
    def runtime_ivar_classes_by_name(evidence)
      by_name = Hash.new { |h, k| h[k] = [] }
      runtime_ivar_classes(evidence).each { |(_cls, name), cs| by_name[name].concat(cs) }
      by_name.transform_values { |cs| cs.uniq.select { |c| NilKill.useful_type?(c.to_s) } }
    end

    # Join type_normalizers (N defensive guards on a slot) with the
    # slot's producer distribution (param_origins): the actionable
    # "fix K outlier producers -> N guards collapse" row, ranked by N.
    # Slot source is widened past sig params to every method nil-kill
    # indexes (existing_sigs + unsigned_methods), so an unsigned/
    # T.untyped param that is guarded still surfaces -- the guard, not
    # the declared type, is what makes it a union in practice.
    def guard_collapse_rows(evidence)
      guards = type_normalizer_guard_index(evidence)
      methods = (Array(evidence.dig("facts", "existing_sigs")) +
                 Array(evidence.dig("facts", "unsigned_methods")))
        .each_with_object({}) { |m, h| h[[m["class"].to_s, m["method"].to_s]] ||= m }
      po_by_callee = Array(evidence.dig("facts", "param_origins")).group_by { |o| o["callee"].to_s }
      rt_returns = runtime_return_classes_by_method(evidence)
      rt_ivars = runtime_ivar_classes(evidence)
      rt_ivars_by_name = runtime_ivar_classes_by_name(evidence)
      rows = []
      guards.each do |(klass, mname), receivers|
        meth = methods[[klass, mname]]
        receivers.each do |recv, g|
          param_names = Array(meth && meth["params"]).map { |p| p["name"].to_s }
          slot_idx = param_names.index(recv)
          producers =
            if meth && slot_idx
              Array(po_by_callee[mname]).select do |o|
                (o["slot"].to_s == slot_idx.to_s || o["slot"].to_s == recv) &&
                  NilKill.useful_type?(o["type"].to_s) && o["origin_kind"].to_s != "unknown"
              end
            else
              []
            end
          dominant = nil
          share = 0.0
          outliers = []
          via = nil
          members = []
          total = producers.size
          if !producers.empty?
            by_type = producers.group_by { |o| o["type"].to_s }
            dominant, dom = by_type.max_by { |_, os| os.size }
            share = dom.size.to_f / total
            outliers = by_type.reject { |t, _| t == dominant }.flat_map do |t, os|
              os.first(3).map { |o| { "type" => t, "loc" => "#{o["path"]}:#{o["line"]}", "code" => o["code"].to_s.gsub(/\s+/, " ").strip[0, 50] } }
            end
          else
            # Lower-cost origin join: receiver is a local fed by a call
            # return or an ivar -- use the runtime classes already
            # gathered for that origin. Gives the empirical member set
            # (and a 100%/collapse verdict when it is a singleton); does
            # NOT pinpoint the producing return statement (runtime is
            # per-method aggregate, not per-return-site).
            case g["origin_kind"]
            when "call", "attr"
              # An attr reader (`node.type_info`) is a zero-arg method;
              # try its runtime return classes first. attr_reader-backed
              # accessors have no traced `def`, so fall back to the
              # like-named ivar's runtime classes (the accessor's
              # backing store) -- the producer types feeding the guard.
              nm = g["origin_name"].to_s
              members = rt_returns[nm]
              if members&.any?
                via = "returns of #{nm}#{g["origin_kind"] == "call" ? "()" : ""}"
              else
                members = rt_ivars_by_name[nm.sub(/\A@/, "")]
                via = "@#{nm.sub(/\A@/, "")} assignments" if members&.any?
              end
            when "ivar"
              nm = g["origin_name"].to_s.sub(/\A@/, "")
              members = rt_ivars[[klass, nm]]
              members = rt_ivars_by_name[nm] if members.nil? || members.empty?
              via = "@#{nm} assignments" if members&.any?
            end
            members = Array(members)
            if via && members.size == 1
              dominant = members.first
              share = 1.0
            end
          end
          rows << {
            "guards" => g["count"],
            "guard_sites" => g["sites"],
            "method" => "#{klass}##{mname}",
            "slot" => recv,
            "slot_kind" => slot_idx ? "param" : (g["origin_kind"] || "local/ivar"),
            "origin_kind" => slot_idx ? "param" : g["origin_kind"],
            "origin_name" => slot_idx ? recv : g["origin_name"],
            "dominant" => dominant,
            "dominant_share" => share,
            "producers" => total,
            "outliers" => outliers,
            "via" => via,
            "members" => members,
          }
        end
      end
      rows.sort_by { |r| [-r["guards"], -r["dominant_share"], -r["producers"], -r["members"].size, r["method"]] }
    end

    # The canonical contract a guarded receiver resolves to. attr /
    # hashkey / ivar / call origins aggregate GLOBALLY by name (the
    # whole point: `.type_info` is one contract feeding hundreds of
    # guards across ~90 methods, not 90 separate 2-guard locals). param
    # / unresolved-local cannot aggregate cross-method, so they stay
    # keyed to their method.
    def canonical_contract(row)
      case row["origin_kind"]
      when "attr"    then [".#{row["origin_name"]}", "accessor"]
      when "hashkey" then ["#{row["origin_name"]}", "hash-key"]
      when "ivar"    then ["#{row["origin_name"]}", "ivar"]
      when "call"    then ["#{row["origin_name"]}()", "call"]
      when "param"   then ["param `#{row["slot"]}` (#{row["method"]})", "param"]
      else ["local `#{row["slot"]}` (#{row["method"]})", "local"]
      end
    end

    def append_union_decomplexity(lines, evidence)
      rows = guard_collapse_rows(evidence)
      lines << ""
      lines << "### Union Decomplexity"
      lines << "- Each entry is a canonical origin contract (an accessor like `.type_info`, a hash key like `[:type]`, an ivar, a call) and the TOTAL `is_a?(Type)` guards that collapse if that one contract is given a concrete type. Guards are aggregated across every method that reads the contract. Producer types come from runtime evidence for that contract; `unattributed` = no runtime trace yet for it."
      if rows.empty?
        lines << "- none"
        return
      end
      agg = {}
      rows.each do |r|
        key, kind = canonical_contract(r)
        a = (agg[key] ||= { "kind" => kind, "guards" => 0, "methods" => [], "sites" => [],
                            "via" => nil, "members" => [], "dominant" => nil, "share" => 0.0, "outliers" => [] })
        a["guards"] += r["guards"]
        a["methods"] |= [r["method"]]
        a["sites"] |= r["guard_sites"]
        if a["via"].nil? && (r["via"] || r["producers"].positive?)
          a["via"] = r["via"]
          a["members"] = r["members"]
          a["dominant"] = r["dominant"]
          a["share"] = r["dominant_share"]
          a["outliers"] = r["outliers"]
        end
      end
      agg.sort_by { |_, a| -a["guards"] }.first(UNION_DECOMPLEXITY_TOP_N).each do |key, a|
        head = "- #{a["guards"]} guards collapse | `#{key}` (#{a["kind"]}) across #{a["methods"].size} method(s)"
        if a["dominant"] && a["share"].to_f >= 0.99 && a["outliers"].empty?
          head += " -> always `#{a["dominant"]}`: collapse, all #{a["guards"]} die"
        elsif a["dominant"]
          pct = (a["share"] * 100).round(1)
          head += " -> #{pct}% `#{a["dominant"]}`#{a["outliers"].any? ? " + #{a["outliers"].size} outlier producer(s)" : ""}"
        elsif a["via"] && a["members"].any?
          head += " -> via #{a["via"]} (runtime) {#{a["members"].join(", ")}}: tighten that contract"
        else
          head += " -> producers unattributed (no runtime trace for this contract yet)"
        end
        lines << head.gsub(/\s+/, " ").strip
        lines << "  - methods: #{a["methods"].first(6).join(", ")}#{a["methods"].size > 6 ? ", +#{a["methods"].size - 6} more" : ""}"
        lines << "  - guards at: #{a["sites"].first(5).join(", ")}" if a["sites"].any?
        a["outliers"].first(6).each do |o|
          lines << "  - outlier producer `#{o["type"]}` at #{o["loc"]} `#{o["code"]}`"
        end
      end
    end

    DETERMINISTIC_GUARD_TOP_N = 30

    def append_deterministic_guard_collapse(lines, evidence)
      static_guards = Array(evidence.dig("facts", "deterministic_guards"))
      contract_rows = guard_collapse_rows(evidence).select do |row|
        row["dominant"] && row["dominant_share"].to_f >= 0.99 && Array(row["outliers"]).empty?
      end
      lines << ""
      lines << "### Deterministic Guard Collapse"
      lines << "- `static_proven` rows are predicates nil-kill can prove from source/type facts. `contract_proven` rows are guard clusters that collapse when the named origin is typed to its observed singleton producer. Runtime-only dominance is review material, not a rewrite proof."
      if static_guards.empty? && contract_rows.empty?
        lines << "- none"
        return
      end

      unless contract_rows.empty?
        lines << "- Contract-proven collapses: #{contract_rows.size}"
        contract_rows.first(DETERMINISTIC_GUARD_TOP_N).each do |row|
          key, kind = canonical_contract(row)
          lines << "  - contract_proven: #{row["guards"]} guard(s) collapse | `#{key}` (#{kind}) -> always `#{row["dominant"]}`"
          lines << "    - methods/sites: #{row["method"]}; #{Array(row["guard_sites"]).first(5).join(", ")}"
          lines << "    - producer evidence: #{row["via"] || "param origins"}"
        end
      end

      unless static_guards.empty?
        grouped = static_guards.group_by { |guard| [guard["path"], guard["line"], guard["code"]] }
        rows = grouped.map do |(_path, _line, _code), guards|
          guard = guards.first
          {
            "guard" => guard,
            "count" => guards.size,
            "methods" => guards.map { |g| [g["class"], g["method"]].compact.reject(&:empty?).join("#") }.uniq,
          }
        end.sort_by { |row| [-row["count"], row["guard"]["path"].to_s, row["guard"]["line"].to_i] }
        lines << "- Static-proven branch predicates: #{static_guards.size}"
        rows.first(DETERMINISTIC_GUARD_TOP_N).each do |row|
          guard = row["guard"]
          site = "#{guard["path"]}:#{guard["line"]}"
          method = row["methods"].first || "top-level"
          lines << "  - static_proven: #{site} #{method} `#{guard["code"]}` -> always #{guard["truth_value"]} (#{guard["branch_kind"]} takes #{guard["taken_branch"]})"
          lines << "    - #{guard["reason"]}"
        end
      end
    end

    NODE_ALIAS_NAMES = { "AST" => "AstNode", "MIR" => "MirNode" }.freeze
    NODE_ALIAS_MIN = 3

    # Heterogeneous param slots whose ENTIRE observed concrete class set
    # lives in a single namespace (AST::*, MIR::*, ...) are not really
    # "untyped" -- they are one node-union. One `T.type_alias` per
    # namespace types ~80% of them. Returns namespace -> sorted rows.
    def node_alias_candidate_rows(evidence)
      method_lookup = Array(evidence["methods"]).each_with_object({}) do |m, h|
        s = m["source"]
        h[[s["path"], s["line"]]] = m if s
      end
      origins_by_callee = Array(evidence.dig("facts", "param_origins")).group_by { |o| o["callee"].to_s }
      by_ns = Hash.new { |h, k| h[k] = [] }
      total_het = 0
      Array(evidence.dig("facts", "existing_sigs")).each do |method|
        rec = method_lookup[[method["path"], method["line"]]]
        extract_param_entries(method["sig"].to_s).each_with_index do |(name, type), idx|
          next unless type == "T.untyped"
          classes = Array(rec && rec.dig("params_ok", name))
          classes = Array(rec && rec.dig("params_by_name", name)) if classes.empty?
          slot_origins = Array(origins_by_callee[method["method"].to_s]).select do |o|
            o["slot"].to_s == idx.to_s || o["slot"].to_s == name.to_s
          end
          next unless classify_param_untyped_cause(method, name, classes, rec, slot_origins) == "Heterogeneous"
          concrete = Array(classes).reject { |c| c == "NilClass" || c.to_s.empty? }
          next if concrete.empty?
          total_het += 1
          namespaces = concrete.map { |c| c.split("::").first }.uniq
          next unless namespaces.size == 1
          by_ns[namespaces.first] << {
            "loc" => "#{method["path"]}:#{method["line"]}",
            "method" => "#{method["class"]}##{method["method"]}",
            "param" => name, "classes" => concrete.size,
          }
        end
      end
      [by_ns, total_het]
    end

    EVIDENCE_GAP_CAP = 50
    # Only HONEST, ACTIONABLE reasons are table columns. The two
    # impossible-in-a-healthy-collect states are NOT columns -- they are
    # hard, loud failures (see untyped_evidence_gaps), so a regression
    # can never be a silently-dropped row or a misread "no data == dead":
    #   - collect_ran_untraced: ran in THIS collect but no record => a
    #     tracer/trace-plan regression. RAISES.
    #   - never_run: evidence has NO collect_coverage at all => the
    #     report was built without a real collect. RAISES (precondition).
    EVIDENCE_GAP_REASONS = {
      "unseen" => "Not reached by the collect workload (a superset of every suite) and no runtime record -- genuinely dead/unreachable, or a real missing test. Investigate or delete.",
      "arg_untraced" => "Block / kwarg / splat arg -- the tracer types only positional named args (these are ~always Proc; low value)",
      "only_nil" => "Only ever nil at runtime -- likely unused / optional-dead; verify it is reachable with a real value",
      "discarded_return" => "Return value never consumed -- likely should be `sig { ... .void }`",
      "collection_no_elements" => "Collection never observed holding an element -- only-empty, or built/consumed off any instrumented path",
      "struct_unobserved" => "Struct/class field never observed assigned during collect -- the tracer signal for fields is struct_field_runtime/ivar_runtime, not line coverage, so the method-oriented coverage split does not apply. Either the class is never constructed by the workload, or the field is always left at its default.",
    }.freeze

    # NOTE: the foreign SimpleCov baseline (SIMPLECOV_RESULTSET /
    # simplecov_covered_files) was DELETED. It was a SEPARATE,
    # file-granular, stale-prone artifact produced by a DIFFERENT
    # workload than the collect; comparing the collect against it made
    # "untraced_covered" structurally non-zeroable. The collect's own
    # aggregated Ruby Coverage (facts.collect_coverage) -- a superset of
    # every suite, freshness-gated by guard_fresh_* -- is now the SOLE
    # source of truth for "was this reached by the workload".

    # A block / Proc / splat-block param: the tracer types only
    # positional named args and TracePlan prunes a method whose only
    # untyped slot is one of these (sample=false -> no record). Detect
    # from the sig so a pruned block-arg method is arg_untraced, not
    # mislabeled never_run.
    def untraceable_arg_kind?(name, type)
      n = name.to_s
      t = type.to_s
      n == "block" || n == "blk" || n.start_with?("&", "*") ||
        n.end_with?("_block", "_blk") ||
        t.include?("T.proc") || t == "Proc" || t.start_with?("T.nilable(Proc")
    end

    # ROOT-relative path -> Set of line numbers executed during THIS
    # collect run (Ruby stdlib Coverage dumped by the tracer, unioned
    # across every traced process). nil when the collect produced no
    # Coverage at all -> never_run_reason falls back to "never_run".
    def collect_coverage_index(evidence)
      return @collect_coverage_index if defined?(@collect_coverage_index)
      cc = evidence.dig("facts", "collect_coverage")
      @collect_coverage_index =
        if cc.is_a?(Hash) && !cc.empty?
          cc.each_with_object({}) { |(p, lines), h| h[p.to_s] = Array(lines).map(&:to_i).to_set }
        end
    end

    # "Did the method BODY execute" -- NOT "is any line in lo..hi
    # covered". Ruby's Coverage marks the `def` line as executed the
    # moment the method is *defined* (class-body evaluation at file
    # load), independent of whether it is ever called. Counting the
    # `def` line therefore makes every defined method in any loaded
    # file look "ran", mass-mislabeling defined-but-never-called methods
    # as collect_ran_untraced ("tracer defect"). Require a covered line
    # strictly inside the def (lo, hi) -- the open interval excludes the
    # signature line and the trailing `end`. For 1-2 line bodies the
    # interior is empty; those cannot be proven run from line coverage
    # alone, so they fall through to "unseen" unless a source-wrapped
    # runtime record exists (in-place wrapping guarantees the record
    # whenever the body actually executes).
    def collect_ran?(idx, rel_path, lo, hi)
      return false unless idx
      path = rel_path.to_s
      path = NilKill.rel(File.expand_path(path, ROOT)) if Pathname.new(path).absolute?
      ls = idx[path]
      return false unless ls
      lo = lo.to_i
      hi = (hi || lo).to_i
      ls.any? { |n| n > lo && n < hi }
    end

    # A method with no runtime record. ONE source of truth -- the
    # collect's own aggregated Ruby Coverage (facts.collect_coverage),
    # which is a superset of every suite. There is no foreign baseline
    # to diverge from, so the old "untraced_covered" state cannot occur:
    #  1. body interior ran in THIS collect but no record =>
    #     "collect_ran_untraced" -- a tracer/trace-plan regression.
    #     NOT a category: enforce_no_hard_gaps! RAISES on it.
    #  2. collect produced Coverage but this body did NOT run anywhere
    #     in the (superset) workload => genuinely dead/missing test
    #     ("unseen" -- the one honest, actionable bucket).
    #  3. no collect Coverage at all => "never_run" -- means the report
    #     was built without a real collect. NOT a category:
    #     enforce_no_hard_gaps! RAISES on it (you must collect first).
    # lo/hi = the method's def line range (always supplied by callers;
    # struct fields use the dedicated "struct_unobserved" reason, not
    # this method-oriented split).
    def never_run_reason(evidence, rel_path, lo = nil, hi = nil)
      cc = collect_coverage_index(evidence)
      return "collect_ran_untraced" if lo && collect_ran?(cc, rel_path, lo, hi)
      return "never_run" if cc.nil?
      "unseen"
    end

    # Break the residual NoEvidence out by WHY, with locations, so each
    # is triageable: dead code, missing test, should-be-void, or an
    # inherently untraceable arg. Mirrors the exact NoEvidence gate of
    # the cause classifiers so the counts reconcile.
    def untyped_evidence_gaps(evidence)
      enforce_trace_plan_coverage!(evidence)
      ml = Array(evidence["methods"]).each_with_object({}) do |m, h|
        s = m["source"]
        h[[s["path"], s["line"]]] = m if s
      end
      po = Array(evidence.dig("facts", "param_origins")).group_by { |o| o["callee"].to_s }
      build_program_return_index!(evidence)
      unused = unused_return_method_names(evidence)
      gaps = Hash.new { |h, k| h[k] = [] }
      Array(evidence.dig("facts", "existing_sigs")).each do |m|
        rec = ml[[m["path"], m["line"]]]
        loc = "#{m["path"]}:#{m["line"]}"
        who = "#{m["class"]}##{m["method"]}"
        extract_param_entries(m["sig"].to_s).each_with_index do |(n, t), i|
          next unless t == "T.untyped"
          cs = Array(rec && rec.dig("params_ok", n))
          cs = Array(rec && rec.dig("params_by_name", n)) if cs.empty?
          so = Array(po[m["method"].to_s]).select { |o| o["slot"].to_s == i.to_s || o["slot"].to_s == n.to_s }
          next unless classify_param_untyped_cause(m, n, cs, rec, so) == "NoEvidence"
          # A block/Proc/kwarg/splat param is untraceable by design --
          # the tracer types only positional named args, and TracePlan
          # prunes a method whose only untyped slot is one of these
          # (sample=false -> no record). That is arg_untraced, NOT
          # "never_run": classify it from the SIG before the
          # rec.nil?/pruned check, or pruned block-arg methods get
          # mislabeled dead/untraced.
          reason = if untraceable_arg_kind?(n, t) || Array(m["untraceable_params"]).include?(n) then "arg_untraced"
                   elsif rec.nil? || rec["calls"].to_i <= 0 then never_run_reason(evidence, m["path"], m["line"], m["end_line"])
                   elsif Array(cs).any? { |c| c != "NilClass" } then "arg_untraced"
                   elsif Array(cs).include?("NilClass") then "only_nil"
                   else "arg_untraced"
                   end
          gaps[reason] << { "cat" => "Params", "text" => "#{loc} `#{who}` param `#{n}`" }
        end
        next unless extract_return_type(m["sig"].to_s) == "T.untyped"
        next unless classify_return_untyped_cause(m, rec, unused) == "NoEvidence"
        reason = rec.nil? || rec["calls"].to_i <= 0 ? never_run_reason(evidence, m["path"], m["line"], m["end_line"]) : "discarded_return"
        gaps[reason] << { "cat" => "Returns", "text" => "#{loc} `#{who}` return" }
      end
      rt = Hash.new { |h, k| h[k] = [] }
      Array(evidence.dig("facts", "struct_field_runtime")).each { |r| rt[[r["class"].to_s, r["field"].to_s]].concat(Array(r["classes"])) }
      Array(evidence.dig("facts", "ivar_runtime")).each { |r| rt[[r["class"].to_s, r["name"].to_s.sub(/\A@/, "")]].concat(Array(r["classes"])) }
      resolvable = Array(evidence["actions"]).each_with_object(Set.new) { |a, s| s << [a.dig("data", "class").to_s, a.dig("data", "field").to_s] if a["kind"] == "add_struct_field_sig" }
      rbi = struct_rbi_types
      # A field with a strong static type was deliberately NOT sampled
      # at runtime (trace_plan.rb sets struct_fields[key]=false when
      # !strong_trace_type?). It is already typed -- not a NoEvidence
      # gap. The report previously consulted only struct_rbi_types
      # (sorbet RBI file); when that key missed, a fully-typed field was
      # mislabeled "never constructed/assigned". Consult the SAME signal
      # the trace plan used: facts.struct_field_static.
      strong_static = Set.new
      Array(evidence.dig("facts", "struct_field_static")).each do |f|
        next unless NilKill.strong_trace_type?(f["type"].to_s)
        strong_static << [f["class"].to_s, f["field"].to_s]
      end
      Array(evidence.dig("facts", "struct_declarations")).each do |decl|
        Array(decl["fields"]).each do |field|
          next if strong_static.include?([decl["class"].to_s, field.to_s])
          type = struct_declared_type(decl, field, rbi)
          next if type && !untyped_type?(strip_nilable(type.to_s))
          observed = rt[[decl["class"].to_s, field.to_s]].uniq
          non_nil = observed.reject { |c| c == "NilClass" || c.to_s.empty? }
          useful = non_nil.select { |c| NilKill.useful_type?(c) && !weak_collection_type?(c) }
          next unless useful.empty? && !(observed.any? && non_nil.empty?) && !resolvable.include?([decl["class"].to_s, field.to_s])
          gaps["struct_unobserved"] << { "cat" => "Struct/ivar", "text" => "#{decl["path"]}:#{decl["line"]} `#{decl["class"]}.#{field}` (field never constructed/assigned)" }
        end
      end
      collection_evidence_slots(evidence).each do |slot|
        next unless slot["elems"].empty? && slot["shapes"].empty?
        gaps["collection_no_elements"] << { "cat" => "Collections", "text" => "#{slot["loc"]} #{slot["what"]}" }
      end
      enforce_no_hard_gaps!(gaps)
      gaps
    end

    # Validate instrumentation before inference can hide a missing runtime
    # record by resolving the sampled slot from static evidence. The trace
    # plan samples a method when at least one traceable parameter or its
    # return remains weak. If that method's body ran during this collect, a
    # source-wrapped record is mandatory regardless of the actions inferred
    # later. Keeping this check at the method/coverage boundary makes the
    # negative control non-vacuous and uses the same facts as TracePlan rather
    # than rediscovering source structure with another walker.
    def enforce_trace_plan_coverage!(evidence)
      coverage = collect_coverage_index(evidence)
      return unless coverage

      recorded = Array(evidence["methods"]).each_with_object(Set.new) do |method, out|
        source = method["source"]
        next unless source && method["calls"].to_i.positive?

        out << [source["path"].to_s, source["line"].to_i]
      end
      missing = (Array(evidence.dig("facts", "existing_sigs")) +
                 Array(evidence.dig("facts", "unsigned_methods"))).filter_map do |method|
        next unless trace_plan_samples_method?(method)
        next if recorded.include?([method["path"].to_s, method["line"].to_i])
        next unless collect_ran?(coverage, method["path"], method["line"], method["end_line"])

        owner = method["class"].to_s
        name = method["method"].to_s
        {
          "cat" => "Methods",
          "text" => "#{method["path"]}:#{method["line"]} `#{owner}##{name}`",
        }
      end
      return if missing.empty?

      sample = missing.first(20).map { |gap| gap["text"] }
      more = missing.size > 20 ? " (+#{missing.size - 20} more)" : ""
      raise "nil-kill: #{missing.size} collect_ran_untraced -- " \
            "#{EVIDENCE_GAP_HARD["collect_ran_untraced"]}. This MUST be zero " \
            "(see spec/zero_evidence_gap_guarantee_spec.rb). Offenders: #{sample.join("; ")}#{more}"
    end

    def trace_plan_samples_method?(method)
      signature = method["sig"].to_s
      untraceable = Array(method["untraceable_params"]).map(&:to_s).to_set
      samples_param = extract_param_entries(signature).any? do |name, type|
        !untraceable.include?(name.to_s) && !NilKill.strong_trace_type?(type)
      end
      return true if samples_param

      return_type = extract_return_type(signature)
      !signature.match?(/\bvoid\b/) && !NilKill.strong_trace_type?(return_type)
    end

    # Neither collect_ran_untraced nor never_run is a report column:
    #
    #  - collect_ran_untraced: ran during THIS collect but produced NO
    #    record -- a tracer/trace-plan regression. It MUST be impossible
    #    (the in-place wrapper records every executed body), so the
    #    report does not paper over it with a permanently-zero column:
    #    it RAISES, loudly. A regression can never be a silently-dropped
    #    row.
    #
    #  - never_run: only arises when evidence has NO collect_coverage at
    #    all -- i.e. not a real collect (production is already guarded:
    #    cli.rb aborts a traced collect with zero Coverage). It carries
    #    no signal (there is nothing to tell dead from un-exercised), so
    #    it is simply dropped from the table -- NOT raised (raising
    #    would break every unit test that classifies synthetic evidence
    #    without a collect) and NOT folded into "unseen" (that would
    #    misread "no data" as "dead").
    #
    # Both are deleted from `gaps` so the renderer (and its Total) only
    # ever sees honest, actionable reasons.
    EVIDENCE_GAP_HARD = {
      "collect_ran_untraced" => "ran during THIS collect but produced NO nil-kill record -- a tracer/trace-plan regression (the in-place wrapper must record every executed body)",
      "never_run" => "no collect_coverage in evidence -- not a real collect (dropped, not actionable)",
    }.freeze

    def enforce_no_hard_gaps!(gaps)
      gaps.delete("never_run") # degenerate (no real collect) -> drop, no signal
      rows = gaps.delete("collect_ran_untraced")
      return if rows.nil? || rows.empty?
      sample = rows.first(20).map { |g| g["text"] }
      more = rows.size > 20 ? " (+#{rows.size - 20} more)" : ""
      raise "nil-kill: #{rows.size} collect_ran_untraced -- " \
            "#{EVIDENCE_GAP_HARD["collect_ran_untraced"]}. This MUST be zero " \
            "(see spec/zero_evidence_gap_guarantee_spec.rb). Offenders: #{sample.join("; ")}#{more}"
    end

    EVIDENCE_GAP_CATEGORIES = ["Params", "Returns", "Struct/ivar", "Collections"].freeze

    def append_untyped_evidence_gaps(lines, evidence)
      gaps = untyped_evidence_gaps(evidence)
      lines << ""
      lines << "### Untyped Evidence Gaps"
      lines << "- The residual NoEvidence, by category x WHY, then listed with locations. Each is a triage candidate (dead code / missing test / should-be-void / untraceable arg), not a classifier defect."
      total = gaps.values.sum(&:size)
      if total.zero?
        lines << "- none"
        return
      end
      reasons = EVIDENCE_GAP_REASONS.keys
      hdr = ["", *reasons.map { |r| r.tr("_", " ") }, "Total"]
      lines << ""
      lines << "| #{hdr.join(" | ")} |"
      lines << "|#{(["---"] * hdr.size).join("|")}|"
      EVIDENCE_GAP_CATEGORIES.each do |cat|
        cells = reasons.map { |r| gaps[r].count { |g| g["cat"] == cat } }
        next if cells.sum.zero?
        lines << "| #{cat} | #{cells.join(" | ")} | #{cells.sum} |"
      end
      tot = reasons.map { |r| gaps[r].size }
      lines << "| **Total** | #{tot.join(" | ")} | #{tot.sum} |"
      reasons.each { |r| lines << "- `#{r.tr("_", " ")}`: #{EVIDENCE_GAP_REASONS[r]}" }
      EVIDENCE_GAP_REASONS.each do |reason, _why|
        rows = gaps[reason]
        next if rows.empty?
        lines << "- #{rows.size} #{reason.tr("_", " ")}"
        if reason == "struct_unobserved"
          # Grouped by struct so the pattern is visible: which classes,
          # how many of their fields, and where each is declared.
          by_class = Hash.new { |h, k| h[k] = { "loc" => nil, "fields" => [] } }
          rows.each do |g|
            m = g["text"].match(/\A(\S+) `([^`]+)\.([^`]+)`/)
            next unless m
            grp = by_class[m[2]]
            grp["loc"] ||= m[1]
            grp["fields"] << m[3]
          end
          by_class.sort_by { |cls, info| [-info["fields"].size, cls] }.each do |cls, info|
            lines << "  - `#{cls}` (#{info["loc"]}): #{info["fields"].size} field(s) -- #{info["fields"].sort.join(", ")}"
          end
        else
          rows.map { |g| g["text"] }.sort.first(EVIDENCE_GAP_CAP).each { |t| lines << "  - #{t}" }
          lines << "  - ... +#{rows.size - EVIDENCE_GAP_CAP} more" if rows.size > EVIDENCE_GAP_CAP
        end
      end
    end

    def append_node_alias_candidates(lines, evidence)
      by_ns, total_het = node_alias_candidate_rows(evidence)
      ranked = by_ns.sort_by { |_, rows| -rows.size }.select { |_, rows| rows.size >= NODE_ALIAS_MIN }
      lines << ""
      lines << "### Node-Union Alias Candidates"
      lines << "- Heterogeneous param slots whose every observed class is in ONE namespace. Each namespace below collapses to a single `T.type_alias` (e.g. `AstNode = T.type_alias { T.any(AST::...) }`); applying it types every listed param at once. `classes` = distinct node types observed at that slot (small = a precise sub-union; large = the full node grab-bag)."
      if ranked.empty?
        lines << "- none"
        return
      end
      resolvable = ranked.sum { |_, rows| rows.size }
      lines << "- #{resolvable} of #{total_het} Heterogeneous params (#{total_het.zero? ? 0 : (100.0 * resolvable / total_het).round}%) collapse to #{ranked.size} alias(es)."
      ranked.each do |ns, rows|
        alias_name = NODE_ALIAS_NAMES[ns] || "#{ns}Node"
        lines << "- `#{alias_name}` (#{ns}::*): #{rows.size} param slot(s)"
        rows.sort_by { |r| [-r["classes"], r["loc"]] }.each do |r|
          lines << "  - #{r["loc"]} `#{r["method"]}` param `#{r["param"]}` (#{r["classes"]} node types)"
        end
      end
    end

    def append_signature_coverage(lines, evidence, accumulator: nil)
      param_counts = empty_type_counts
      return_counts = empty_type_counts
      evidence["facts"]["existing_sigs"].each do |method|
        sig = method["sig"].to_s
        extract_param_types(sig).each { |type| classify_type!(param_counts, type) }
        return_type = extract_return_type(sig)
        classify_type!(return_counts, return_type) if return_type
      end
      lines << ""
      lines << "### Signature Slots"
      lines << "- Param slots: #{format_type_counts(param_counts)}"
      lines << "  - of which weak primitive collection (T::Array[T.untyped] etc.): #{param_counts["weak_collection"]}" if param_counts["weak_collection"].to_i.positive?
      lines << "- Return slots: #{format_type_counts(return_counts)}"
      lines << "  - of which weak primitive collection (T::Array[T.untyped] etc.): #{return_counts["weak_collection"]}" if return_counts["weak_collection"].to_i.positive?
      lines << "- Nilable param slots: #{param_counts["nilable"]}"
      lines << "- Nilable return slots: #{return_counts["nilable"]}"
      accumulator&.add("param", param_counts)
      accumulator&.add("return", return_counts)
    end

    def append_variable_assignment_coverage(lines, evidence, accumulator: nil)
      sites = Array(evidence.dig("facts", "tlet_sites"))
      typed = sites.select { |site| site["tlet"] && site["type"] }
      candidates = sites.reject { |site| site["tlet"] }
      typed_counts = empty_type_counts
      typed.each { |site| classify_type!(typed_counts, site["type"]) }

      lines << ""
      lines << "### Class And Instance Variable Slots"
      lines << "- Existing T.let assignment slots: #{format_type_counts(typed_counts)}"
      lines << "  - of which weak primitive collection (T::Array[T.untyped] etc.): #{typed_counts["weak_collection"]}" if typed_counts["weak_collection"].to_i.positive?
      lines << "- Candidate T.let assignment slots: #{candidates.size}"
      accumulator&.add("tlet", typed_counts)
      candidates.first(8).each do |site|
        lines << "  - #{site["path"]}:#{site["line"]} #{site["name"]} -> #{site["candidate_type"]}"
      end
      lines << "  - ... #{candidates.size - 8} more" if candidates.size > 8
    end

    SOUNDNESS_CATEGORIES = ["Param inputs", "Returns", "Struct/class fields & ivars", "Arrays/Sets/Hashmaps"].freeze

    # A parameterised stdlib container (strong OR weak element). Such a
    # slot is routed to the Arrays/Sets/Hashmaps row so the four
    # categories stay mutually exclusive and the two tables reconcile:
    # the Collections "Weak" column == the Untyped-Causes Collections
    # denominator.
    def collection_typed?(type)
      strip_nilable(type.to_s).match?(/\AT::(?:Array|Hash|Set|Enumerable)\b/)
    end

    # Table 1: Type Soundness. One row per slot category, columns
    # Total / Strong / Weak / Untyped / Nilable. Nilable is a cross-cut
    # sub-count (a T.nilable(String) slot is Strong AND Nilable), so
    # Total = Strong + Weak + Untyped; Nilable <= Total.
    def type_soundness_table(evidence)
      rows = SOUNDNESS_CATEGORIES.each_with_object({}) do |c, h|
        h[c] = { "total" => 0, "strong" => 0, "weak" => 0, "untyped" => 0, "nilable" => 0 }
      end
      tally = lambda do |structural_category, type|
        type = type.to_s.strip
        return if type.empty?
        cat = collection_typed?(type) ? "Arrays/Sets/Hashmaps" : structural_category
        r = rows[cat]
        r["total"] += 1
        r["nilable"] += 1 if nilable_type?(type)
        inner = strip_nilable(type)
        if untyped_type?(inner) || inner.include?("T.untyped")
          r["untyped"] += 1
        elsif weak_type?(inner)
          r["weak"] += 1
        else
          r["strong"] += 1
        end
      end

      Array(evidence.dig("facts", "existing_sigs")).each do |m|
        extract_param_entries(m["sig"].to_s).each { |_n, t| tally.("Param inputs", t) }
        rt = extract_return_type(m["sig"].to_s)
        tally.("Returns", rt) if rt
      end
      rbi_types = struct_field_types(evidence)
      Array(evidence.dig("facts", "struct_declarations")).each do |decl|
        Array(decl["fields"]).each do |field|
          tally.("Struct/class fields & ivars", struct_declared_type(decl, field, rbi_types) || "T.untyped")
        end
      end
      state_tlet_sites(evidence).each do |s|
        next unless s["tlet"] && s["type"]
        tally.("Struct/class fields & ivars", s["type"])
      end
      rows
    end

    def append_type_soundness_table(lines, evidence)
      rows = type_soundness_table(evidence)
      lines << ""
      lines << "### Type Soundness"
      lines << ""
      lines << "| Slot category | Total | Strong | Weak | Untyped | Nilable |"
      lines << "|---|---|---|---|---|---|"
      SOUNDNESS_CATEGORIES.each do |cat|
        r = rows[cat]
        t = r["total"]
        pc = ->(n) { t.positive? ? " (#{(100.0 * n / t).round(1)}%)" : "" }
        lines << "| #{cat} | #{t} | #{r["strong"]}#{pc.(r["strong"])} | #{r["weak"]}#{pc.(r["weak"])} | #{r["untyped"]}#{pc.(r["untyped"])} | #{r["nilable"]}#{pc.(r["nilable"])} |"
      end
      lines << ""
      lines << "Total = Strong + Weak + Untyped. Nilable is a cross-cut sub-count (a `T.nilable(String)` slot is Strong and Nilable, not a fourth bucket). Collection-typed slots (`T::Array[...]` etc.) are counted only in the Arrays/Sets/Hashmaps row, so the four categories are mutually exclusive. The Param/Returns/Struct Untyped columns equal the per-row denominators in the Untyped Cause Breakdown below."
    end

    def append_untyped_slot_name_pressure(lines, evidence)
      rows = untyped_slot_name_pressure(evidence)
      lines << ""
      lines << "### Top Untyped Slot Names"
      lines << "- Repeated names are prioritization pressure only; Nil-Kill does not infer a type from a name."
      if rows.empty?
        lines << "- none"
        return
      end

      lines << ""
      lines << "| Name | Slots | Categories | Type hints | Example sites |"
      lines << "|---|---:|---|---|---|"
      rows.first(20).each do |row|
        categories = row["categories"].sort.map { |kind, count| "#{kind} #{count}" }.join(", ")
        hints = Array(row["typed_hints"]).map do |hint|
          "`#{hint["type"]}` #{hint["count"]} (#{hint["percent"]}%)"
        end.join(", ")
        hints = "-" if hints.empty?
        examples = row["examples"].first(3).join("; ")
        lines << "| `#{row["name"]}` | #{row["count"]} | #{categories} | #{hints} | #{examples} |"
      end
      lines << "- ... #{rows.size - 20} more repeated name(s)" if rows.size > 20
    end

    def untyped_slot_name_pressure(evidence)
      static_rows = Array(evidence.dig("facts", "top_untyped_slot_names"))
      return static_rows unless static_rows.empty?

      rows = Hash.new do |hash, name|
        hash[name] = {"name" => name, "count" => 0, "categories" => Hash.new(0), "examples" => []}
      end
      add = lambda do |name, category, site|
        clean_name = name.to_s.sub(/\A@/, "")
        return if clean_name.empty?

        row = rows[clean_name]
        row["count"] += 1
        row["categories"][category] += 1
        row["examples"] << site if row["examples"].size < 3
      end

      Array(evidence.dig("facts", "existing_sigs")).each do |method|
        extract_param_entries(method["sig"].to_s).each do |name, type|
          next unless untyped_type?(strip_nilable(type.to_s))

          add.(name, "param", "#{method["path"]}:#{method["line"]} param `#{name}`")
        end
      end

      rbi_types = struct_field_types(evidence)
      Array(evidence.dig("facts", "struct_declarations")).each do |decl|
        Array(decl["fields"]).each do |field|
          type = struct_declared_type(decl, field, rbi_types) || "T.untyped"
          next unless untyped_type?(strip_nilable(type.to_s))

          add.(field, "field", "#{decl["path"]}:#{decl["line"]} #{decl["class"]}.#{field}")
        end
      end

      Array(evidence.dig("facts", "tlet_sites")).each do |site|
        next unless site["tlet"] && untyped_type?(strip_nilable(site["type"].to_s))

        add.(site["name"], "var", "#{site["path"]}:#{site["line"]} #{site["name"]}")
      end

      rows.values
        .select { |row| row["count"] > 1 }
        .sort_by { |row| [-row["count"], row["name"]] }
    end

    # Ordered cause taxonomy. First match wins (most-actionable first).
    # Keep keys short -- they are the markdown column headers.
    UNTYPED_CAUSES = %w[Refused/Pending PropagationGap WeakEvidence Heterogeneous NoEvidence].freeze
    UNTYPED_CAUSE_LEGEND = {
      "Refused/Pending" => "type IS determinable from local evidence (single observed runtime type, void/unused, boolean pair) -- untyped only because the fix is unapplied or conservatively refused",
      "PropagationGap" => "type is determinable elsewhere but needs cross-method/whole-program flow (forwarded return, ivar-from-param capture, callee untyped-but-resolvable, coherent collection needing the typed-collection rewrite)",
      "WeakEvidence" => "a type is known but only weakly (T::Array[T.untyped], a union wider than policy) -- the weak-collection / union-policy axis",
      "Heterogeneous" => "slot legitimately holds many unrelated types/shapes (AST/MIR node grab-bags, dynamic dispatch) -- T.untyped is the correct type",
      "NoEvidence" => "never observed at runtime AND no static expression/callsite to infer from -- needs a test or a hand-written sig",
    }.freeze

    # Builds the 7-column untyped-cause breakdown:
    #   col 1  = slot category (with its untyped total)
    #   cols 2-7 = the six causes, each "N (P%)" of that row's untyped slots
    def untyped_cause_table(evidence)
      method_lookup = evidence["methods"].each_with_object({}) do |method, lookup|
        src = method["source"]
        lookup[[src["path"], src["line"]]] = method if src
      end
      param_origins = Array(evidence.dig("facts", "param_origins"))
      origins_by_callee = param_origins.group_by { |o| o["callee"].to_s }
      unused = unused_return_method_names(evidence)
      sigs = Array(evidence.dig("facts", "existing_sigs"))
      build_program_return_index!(evidence)

      rows = {
        "Param inputs" => Hash.new(0),
        "Returns" => Hash.new(0),
        "Struct/class fields & ivars" => Hash.new(0),
        "Arrays/Sets/Hashmaps" => Hash.new(0),
      }

      sigs.each do |method|
        rec = method_lookup[[method["path"], method["line"]]]
        extract_param_entries(method["sig"].to_s).each_with_index do |(name, type), idx|
          inner = strip_nilable(type.to_s)
          next if collection_typed?(type)
          next unless inner.include?("T.untyped")
          if inner != "T.untyped"
            rows["Param inputs"]["WeakEvidence"] += 1
            next
          end
          classes = Array(rec&.dig("params_ok", name))
          classes = Array(rec&.dig("params_by_name", name)) if classes.empty?
          slot_origins = Array(origins_by_callee[method["method"].to_s]).select do |o|
            o["slot"].to_s == idx.to_s || o["slot"].to_s == name.to_s
          end
          rows["Param inputs"][classify_param_untyped_cause(method, name, classes, rec, slot_origins)] += 1
        end
        return_type = extract_return_type(method["sig"].to_s).to_s
        return_inner = strip_nilable(return_type)
        next if collection_typed?(return_type)
        next unless return_inner.include?("T.untyped")
        if return_inner != "T.untyped"
          rows["Returns"]["WeakEvidence"] += 1
          next
        end
        rows["Returns"][classify_return_untyped_cause(method, rec, unused)] += 1
      end

      classify_struct_ivar_untyped!(rows["Struct/class fields & ivars"], evidence)
      classify_collection_untyped!(rows["Arrays/Sets/Hashmaps"], evidence)
      rows
    end

    # Program-wide resolvable-return map (method name -> uniq concrete
    # return types) + the noreturn-method set. A "far end" of a
    # call_untyped edge is resolvable iff its name maps to exactly one
    # concrete type here, or it is a known noreturn helper. Mirrors the
    # data the whole-program return-propagation pass actually uses, so
    # the cause table reports the TRUE fixable size, not "has a
    # cross-method-shaped blocker".
    def build_program_return_index!(evidence)
      ri = Hash.new { |h, k| h[k] = [] }
      Array(evidence.dig("facts", "return_origins")).each do |o|
        next unless o["confidence"] == "strong"
        t = o["candidate_type"].to_s
        next if t.empty? || untyped_type?(t) || weak_collection_type?(t)
        ri[o["method"].to_s] << t
      end
      Array(evidence.dig("facts", "existing_sigs")).each do |m|
        rt = extract_return_type(m["sig"].to_s).to_s.strip
        next if rt.empty? || rt == "T.untyped"
        ri[m["method"].to_s] << rt
      end
      @program_return_index = Hash.new([]).tap { |h| ri.each { |k, v| h[k] = v.uniq } }
      @program_noreturn_names = Array(evidence.dig("facts", "return_origins"))
        .select { |o| o["candidate_type"].to_s == "T.noreturn" }
        .map { |o| o["method"].to_s }.to_set
    end

    def classify_param_untyped_cause(method, name, classes, rec, slot_origins)
      classes = Array(classes).compact.uniq
      non_nil = classes.reject { |c| c == "NilClass" }
      hit = rec && rec["calls"].to_i.positive?
      return "Refused/Pending" if hit && non_nil.size == 1
      return "Refused/Pending" if hit && non_nil.sort == %w[FalseClass TrueClass]
      srccat = untyped_param_source_category(slot_origins)
      concrete_types = slot_origins.select do |o|
        ty = o["type"].to_s
        NilKill.useful_type?(ty) && !weak_collection_type?(ty) && o["origin_kind"].to_s != "unknown"
      end.map { |o| o["type"].to_s }.uniq
      # Honest classifier (mirrors classify_return_untyped_cause): a
      # concrete caller only makes the slot resolvable if the callers
      # agree on ONE concrete type. Divergent concrete callers are
      # genuinely polymorphic -- narrowing the sig would break the
      # other callers (whole-program-consistency wall), so it is
      # Heterogeneous, not a propagation we can perform.
      unless concrete_types.empty?
        return "Heterogeneous" if concrete_types.size > NilKill::MAX_UNION_TYPES
        return "Heterogeneous" if concrete_types.size > 1
        return "PropagationGap"
      end
      # A forwarded return whose far end is a TYPED return is resolvable
      # program-wide -> PropagationGap (actionable), independent of
      # runtime observation.
      if srccat == "untyped forwarded return" && slot_origins.any? { |o| o["origin_kind"].to_s == "typed_return" }
        return "PropagationGap"
      end
      # NoEvidence means (per the legend) NEVER observed at runtime AND
      # no static expression. A param the runtime actually observed with
      # concrete classes can never be NoEvidence -- runtime polymorphism
      # is stronger evidence than the static source shape. So the
      # forwarded-return / ivar source categories only collapse to
      # NoEvidence when there is genuinely no runtime evidence; with
      # runtime classes they fall through to the Heterogeneous /
      # WeakEvidence verdict below.
      if !(hit && non_nil.any?)
        return "NoEvidence" if srccat == "untyped forwarded return"
        return "NoEvidence" if srccat == "untyped instance variable"
      end
      return "WeakEvidence" if srccat == "untyped struct/array/collection value"
      return "Heterogeneous" if hit && non_nil.size > NilKill::MAX_UNION_TYPES
      return "WeakEvidence" if hit && non_nil.size > 1
      "NoEvidence"
    end


    def classify_return_untyped_cause(method, rec, unused)
      return "Refused/Pending" if unused.include?(method["method"].to_sym)
      origin = method["return_origin"] || {}
      sources = Array(origin["sources"])
      blockers = Array(origin["blockers"]).join(" ; ")
      returns = Array(rec&.dig("returns")).compact.uniq
      non_nil = returns.reject { |c| c == "NilClass" }
      hit = rec && rec["calls"].to_i.positive?
      return "Refused/Pending" if hit && non_nil.size == 1
      return "Refused/Pending" if hit && non_nil.sort == %w[FalseClass TrueClass]
      # Executed but never produced a usable (non-nil) return: only nil,
      # OR no return value ever recorded at runtime (side-effect / bang
      # methods). Determinable as .void / T.nilable -- the runtime_void
      # proposer emits that fix; per the legend this is Refused/Pending
      # ("type IS determinable, fix unapplied"), NOT "no evidence".
      # EXCEPTION: only when the return was NEVER observed at runtime
      # (returns empty -- not sampled at all, distinct from "observed,
      # only nil"). Then the runtime told us nothing; if it forwards to
      # another method (call_untyped) or an ivar, the static propagation
      # chain still can -- defer to the call_untyped / ivar_read
      # resolution below (PropagationGap if the far end resolves,
      # NoEvidence if it is the transitive wall). An executed return
      # OBSERVED only as nil stays Refused/Pending (runtime says void),
      # even with a forwarded source.
      never_observed = returns.empty?
      propagatable = sources.any? { |s| %w[call_untyped ivar_read].include?(s["kind"].to_s) }
      return "Refused/Pending" if hit && non_nil.empty? && !(never_observed && propagatable)
      # Honest call_untyped handling: only PropagationGap if the callee's
      # return is actually resolvable program-wide. If the far end is
      # itself untyped everywhere it's the transitive wall (NoEvidence);
      # if the name resolves to >1 distinct type it's genuinely
      # polymorphic (Heterogeneous). ivar_read = class-wide ivar typing,
      # a propagation we could build.
      callees = sources.select { |s| s["kind"].to_s == "call_untyped" }
        .map { |s| s["callee"].to_s }.reject(&:empty?)
      ri = @program_return_index
      nrm = @program_noreturn_names
      if sources.any? { |s| s["kind"].to_s == "ivar_read" } && callees.empty?
        return "PropagationGap"
      end
      unless callees.empty?
        per = callees.map { |c| nrm.include?(c) ? :resolvable : (sz = ri[c].size; sz == 1 ? :resolvable : sz > 1 ? :ambiguous : :untyped) }
        return "PropagationGap" if per.all? { |v| v == :resolvable }
        return "Heterogeneous" if per.any? { |v| v == :ambiguous } && per.none? { |v| v == :untyped }
        # >=1 callee untyped anywhere = the static transitive wall. But
        # the runtime may have OBSERVED concrete returns -- do not
        # discard that evidence (same fix already applied to params).
        # With runtime non-nil classes, fall through to the runtime
        # Heterogeneous / WeakEvidence verdict below.
        return "NoEvidence" unless hit && non_nil.any?
      end
      cand = origin["candidate_type"].to_s
      return "WeakEvidence" if weak_collection_return_source?(cand, sources) || weak_collection_type?(cand)
      return "Heterogeneous" if hit && non_nil.size > NilKill::MAX_UNION_TYPES
      return "WeakEvidence" if hit && non_nil.size > 1
      return "NoEvidence" if !hit && sources.empty?
      "NoEvidence"
    end

    # Plain `T.untyped` struct fields + ivar T.let slots. Weak-collection
    # (`T::Array[T.untyped]`) slots are NOT counted here -- they belong
    # to the Arrays/Sets/Hashmaps row so the four categories stay
    # mutually exclusive and additive, matching the Hygiene Overview
    # split (untyped vs weak-collection are separate there too).
    def classify_struct_ivar_untyped!(bucket, evidence)
      # Explicit `T.let(x, T.untyped)` -- a deliberate untyped
      # declaration that is almost always narrowable.
      state_tlet_sites(evidence).each do |site|
        next unless site["tlet"]
        type = strip_nilable(site["type"].to_s)
        next if collection_typed?(site["type"].to_s) || !type.include?("T.untyped")
        bucket[type == "T.untyped" ? "Refused/Pending" : "WeakEvidence"] += 1
      end
      rbi_types = struct_field_types(evidence)
      # Honest PropagationGap signal (same fix as returns/params): a
      # struct field is genuinely propagation-resolvable ONLY if there
      # is a concrete `add_struct_field_sig` action for it -- i.e. the
      # refill actually resolved a type for its RHS. The old heuristic
      # ("RHS expression looks like a local/ivar / is a captured
      # param") over-counted massively: ~282 of those have an RHS
      # local/ivar that is itself untyped (the transitive wall) and
      # were never typeable. Those are NoEvidence, not PropagationGap.
      resolvable = Array(evidence["actions"]).each_with_object(Set.new) do |a, set|
        set << [a.dig("data", "class").to_s, a.dig("data", "field").to_s] if a["kind"] == "add_struct_field_sig"
      end
      # Runtime classes observed for each struct field / ivar. Until the
      # instrumented-path fix this was always empty, so every field
      # collapsed to NoEvidence. Honest classifier (same as
      # returns/params): an observed field is determinable / weak /
      # heterogeneous, never "no evidence".
      rt = Hash.new { |h, k| h[k] = [] }
      Array(evidence.dig("facts", "struct_field_runtime")).each do |r|
        rt[[r["class"].to_s, r["field"].to_s]].concat(Array(r["classes"]))
      end
      Array(evidence.dig("facts", "ivar_runtime")).each do |r|
        rt[[r["class"].to_s, r["name"].to_s.sub(/\A@/, "")]].concat(Array(r["classes"]))
      end
      Array(evidence.dig("facts", "struct_declarations")).each do |decl|
        Array(decl["fields"]).each do |field|
          type = struct_declared_type(decl, field, rbi_types)
          inner = strip_nilable(type.to_s)
          next if collection_typed?(type.to_s)
          # "missing" (no RBI type) and plain untyped both count here;
          # weak-collection goes to the Arrays/Sets/Hashmaps row.
          next if type && !inner.include?("T.untyped")
          if type && inner != "T.untyped"
            bucket["WeakEvidence"] += 1
            next
          end
          observed = rt[[decl["class"].to_s, field.to_s]].uniq
          non_nil = observed.reject { |c| c == "NilClass" || c.to_s.empty? }
          useful = non_nil.select { |c| NilKill.useful_type?(c) && !weak_collection_type?(c) }
          if useful.size == 1
            bucket["Refused/Pending"] += 1  # single observed type -> determinable
          elsif observed.any? && non_nil.empty?
            bucket["Refused/Pending"] += 1  # only ever nil -> void / T.nilable
          elsif resolvable.include?([decl["class"].to_s, field.to_s])
            bucket["PropagationGap"] += 1   # a concrete sig is proposable; loop --struct-rbi lands it
          elsif useful.size > NilKill::MAX_UNION_TYPES
            bucket["Heterogeneous"] += 1    # grab-bag node field -> T.untyped is correct
          elsif useful.size > 1
            bucket["WeakEvidence"] += 1     # known but a small union
          else
            bucket["NoEvidence"] += 1       # genuinely no runtime + no proposable static type
          end
        end
      end
    end

    def classify_collection_untyped!(bucket, evidence)
      collection_evidence_slots(evidence).each do |slot|
        elems = slot["elems"]
        shapes = slot["shapes"]
        if elems.size == 1 && NilKill.useful_type?(elems.first)
          bucket["Refused/Pending"] += 1
        elsif shapes.size == 1
          bucket["PropagationGap"] += 1
        elsif elems.size > NilKill::MAX_UNION_TYPES || shapes.size > 1
          bucket["Heterogeneous"] += 1
        elsif elems.size > 1
          bucket["WeakEvidence"] += 1
        else
          bucket["NoEvidence"] += 1
        end
      end
    end

    # Single source of truth for weak-collection slots + their merged
    # runtime element evidence (mutation hooks + call/return boundary +
    # struct construction). Returns [{loc, what, elems, shapes}] so the
    # classifier and the evidence-gap breakdown agree exactly.
    def collection_evidence_slots(evidence)
      runtime = Array(evidence.dig("facts", "collection_runtime"))
      rel = ->(p) { p.to_s.sub(/\A#{Regexp.escape(ROOT)}\/?/, "") }
      # collection_runtime records the OBSERVATION/mutation site line,
      # not the sig/decl line, so a [path,line,name] join misses almost
      # everything (the false-NoEvidence bug). Join on owner IDENTITY
      # instead: param name within the method's line range, method name
      # for returns, and the class-qualified "Class.field" for struct
      # fields (already unique).
      params_idx = Hash.new { |h, k| h[k] = [] }
      returns_idx = Hash.new { |h, k| h[k] = [] }
      struct_idx = Hash.new { |h, k| h[k] = [] }
      runtime.each do |r|
        case r["owner_kind"]
        when "method_param" then params_idx[[rel.(r["path"]), r["name"].to_s]] << r
        when "method_return" then returns_idx[[rel.(r["path"]), r["name"].to_s]] << r
        when "struct_field" then struct_idx[r["name"].to_s] << r
        end
      end
      seen = ->(t) { weak_collection_type?(strip_nilable(t.to_s)) }
      # Method-boundary element capture: the tracer ALSO records element
      # classes/shapes for every collection param and return at the
      # call/return boundary (param_elem/return_elem/*_kv/*_shapes),
      # independent of the mutation hooks. That covers read-only params
      # and build-and-return values collection_runtime never sees. The
      # classifier must consult it too, or those stay false-NoEvidence.
      method_lookup = Array(evidence["methods"]).each_with_object({}) do |m, h|
        s = m["source"]
        h[[s["path"], s["line"]]] = m if s
      end
      sfr = Hash.new { |h, k| h[k] = [] }
      Array(evidence.dig("facts", "struct_field_runtime")).each do |r|
        sfr[[r["class"].to_s, r["field"].to_s]] << r
      end
      # Pull elem/key/value classes + shapes out of a runtime record
      # bundle (collection_runtime hits and/or boundary kv pairs).
      rec_elems = lambda do |recs|
        recs.flat_map { |r| Array(r["elem_classes"]) + Array(r["key_classes"]) + Array(r["value_classes"]) }
      end

      mk = lambda do |loc, what, raw_elems, raw_shapes|
        { "loc" => loc, "what" => what,
          "elems" => Array(raw_elems).uniq.reject { |c| c == "NilClass" || c.to_s.empty? },
          "shapes" => Array(raw_shapes).uniq }
      end
      slots = []
      Array(evidence.dig("facts", "existing_sigs")).each do |m|
        rp = rel.(m["path"])
        lo = m["line"].to_i
        hi = (m["end_line"] || m["line"]).to_i
        mrec = method_lookup[[m["path"], m["line"]]]
        loc = "#{m["path"]}:#{m["line"]}"
        who = "#{m["class"]}##{m["method"]}"
        extract_param_entries(m["sig"].to_s).each do |n, t|
          next unless seen.(t)
          hits = params_idx[[rp, n.to_s]].select { |r| (lo..hi).cover?(r["line"].to_i) }
          slots << mk.(loc, "#{who} param `#{n}`",
                       rec_elems.(hits) + Array(mrec && mrec.dig("param_elem", n)) + Array(mrec && mrec.dig("param_kv", n)).flatten,
                       hits.flat_map { |r| Array(r["elem_shapes"]) } + Array(mrec && mrec.dig("param_elem_shapes", n)) + Array(mrec && mrec.dig("param_kv_shapes", n)).flatten)
        end
        next unless seen.(extract_return_type(m["sig"].to_s).to_s)
        hits = returns_idx[[rp, m["method"].to_s]]
        slots << mk.(loc, "#{who} return",
                     rec_elems.(hits) + Array(mrec && mrec["return_elem"]) + Array(mrec && mrec["return_kv"]).flatten,
                     hits.flat_map { |r| Array(r["elem_shapes"]) } + Array(mrec && mrec["return_elem_shapes"]) + Array(mrec && mrec["return_kv_shapes"]).flatten)
      end
      rbi_types = struct_field_types(evidence)
      Array(evidence.dig("facts", "struct_declarations")).each do |decl|
        Array(decl["fields"]).each do |field|
          next unless seen.(struct_declared_type(decl, field, rbi_types).to_s)
          recs = struct_idx["#{decl["class"]}.#{field}"] + sfr[[decl["class"].to_s, field.to_s]]
          slots << mk.("#{decl["path"]}:#{decl["line"]}", "#{decl["class"]}.#{field}",
                       rec_elems.(recs), recs.flat_map { |r| Array(r["elem_shapes"]) })
        end
      end
      Array(evidence.dig("facts", "tlet_sites")).each do |s|
        next unless s["tlet"] && seen.(s["type"].to_s)
        recs = runtime.select { |r| r["line"].to_i == s["line"].to_i && rel.(r["path"]) == rel.(s["path"]) }
        slots << mk.("#{s["path"]}:#{s["line"]}", "T.let `#{s["name"]}`",
                     rec_elems.(recs), recs.flat_map { |r| Array(r["elem_shapes"]) })
      end
      slots
    end

    def append_untyped_cause_table(lines, evidence)
      rows = untyped_cause_table(evidence)
      lines << ""
      lines << "### Untyped Cause Breakdown"
      lines << ""
      lines << "| Slot category | #{UNTYPED_CAUSES.join(" | ")} |"
      lines << "|#{(["---"] * (UNTYPED_CAUSES.size + 1)).join("|")}|"
      rows.each do |category, counts|
        total = UNTYPED_CAUSES.sum { |c| counts[c] }
        cells = UNTYPED_CAUSES.map do |cause|
          n = counts[cause]
          pct = total.positive? ? (100.0 * n / total).round(1) : 0.0
          "#{n} (#{pct}%)"
        end
        lines << "| #{category} (#{total} untyped) | #{cells.join(" | ")} |"
      end
      lines << ""
      UNTYPED_CAUSES.each { |c| lines << "- **#{c}**: #{UNTYPED_CAUSE_LEGEND[c]}" }
      lines << ""
      lines << "Actionable by more nil-kill work: PropagationGap (and the policy half of WeakEvidence). Inherent (correct T.untyped or needs human/tests): Heterogeneous + NoEvidence. Refused/Pending is resolvable today but unapplied or conservatively declined."
    end

    def append_untyped_breakdown(lines, evidence)
      method_lookup = evidence["methods"].each_with_object({}) do |method, lookup|
        source = method["source"]
        next unless source
        lookup[[source["path"], source["line"]]] = method
      end
      unused_return_names = unused_return_method_names(evidence)
      protocol_index = protocol_class_index(evidence)
      param_buckets = Hash.new(0)
      return_buckets = Hash.new(0)
      param_examples = Hash.new { |hash, key| hash[key] = {} }
      return_examples = Hash.new { |hash, key| hash[key] = {} }
      evidence["facts"]["existing_sigs"].each do |method|
        rec = method_lookup[[method["path"], method["line"]]]
        extract_param_entries(method["sig"].to_s).each do |name, type|
          next unless type == "T.untyped"
          classes = Array(rec&.dig("params_ok", name))
          classes = Array(rec&.dig("params_by_name", name)) if classes.empty?
          bucket = untyped_param_bucket(method, name, classes, rec)
          param_buckets[bucket] += 1
          example = slot_example(method, name, classes, rec,
            protocol_hint: bucket == "runtime union; kept T.untyped by policy" ? protocol_hint(method, name, classes, protocol_index) : nil)
          record_bucket_example!(param_examples[bucket], slot_example_key(method), example)
        end
        ret = extract_return_type(method["sig"].to_s)
        next unless ret == "T.untyped"
        bucket = untyped_return_bucket(method, rec, unused_return_names)
        return_buckets[bucket] += 1
        record_bucket_example!(return_examples[bucket], slot_example_key(method), slot_example(method, "return", Array(rec&.dig("returns")), rec))
      end
      lines << ""
      lines << "## Untyped Slots"
      lines << "- bucket: runtime-observation state for the current `T.untyped` slot, such as unobserved, nil-only, single-type, or runtime union"
      lines << "- source category: static origin category explaining where the untyped value appears to come from"
      lines << "- unknown expression cause: parser/indexer reason the report could not classify the expression more precisely"
      lines << ""
      lines << "### Param T.untyped Buckets"
      append_bucket_lines(lines, param_buckets, param_examples)
      lines << ""
      lines << "### Return T.untyped Buckets"
      append_bucket_lines(lines, return_buckets, return_examples)
      append_untyped_param_source_categories(lines, evidence["facts"]["existing_sigs"], Array(evidence.dig("facts", "param_origins")))
      append_untyped_return_source_categories(lines, evidence["facts"]["existing_sigs"])
      append_unknown_expression_breakdowns(lines, evidence["facts"]["existing_sigs"], Array(evidence.dig("facts", "param_origins")))
    end

    def append_signature_slot_evidence(lines, evidence)
      rows = signature_slot_evidence_rows(evidence).select { |row| row["strength"] != "strong" }
      param_rows = rows.select { |row| row["slot_kind"] == "param" }
      return_rows = rows.select { |row| row["slot_kind"] == "return" }

      lines << ""
      lines << "### Signature Slot Evidence"
      lines << "- primary reason: the single strongest current explanation for why this weak/untyped signature slot has not been safely strengthened"
      lines << "- evidence count: runtime observations plus static callsite/origin records feeding the slot"
      lines << "- candidate action: an existing nil-kill action that could rewrite this slot, if one exists"
      lines << ""
      lines << "#### Param Slot Evidence"
      append_signature_evidence_bucket_lines(lines, param_rows)
      lines << ""
      lines << "#### Return Slot Evidence"
      append_signature_evidence_bucket_lines(lines, return_rows)
    end

    def signature_slot_evidence_rows(evidence)
      method_lookup = evidence["methods"].each_with_object({}) do |method, lookup|
        source = method["source"]
        next unless source
        lookup[[source["path"], source["line"]]] = method
      end
      param_origins = Array(evidence.dig("facts", "param_origins"))
      return_origins = Array(evidence.dig("facts", "return_origins")).each_with_object({}) do |origin, lookup|
        lookup[[origin["path"], origin["line"].to_i, origin["class"].to_s, origin["method"].to_s, origin["kind"].to_s]] = origin
      end
      actions = signature_action_lookup(evidence)
      unused_return_names = unused_return_method_names(evidence)
      protocol_index = protocol_class_index(evidence)

      Array(evidence.dig("facts", "existing_sigs")).flat_map do |method|
        rec = method_lookup[[method["path"], method["line"]]]
        sig = method["sig"].to_s
        rows = []
        extract_param_entries(sig).each_with_index do |(name, type), idx|
          strength = signature_slot_strength(type)
          next if strength == "strong"
          origins = param_origins_for_slot(param_origins, method, name, idx)
          classes = Array(rec&.dig("params_ok", name))
          classes = Array(rec&.dig("params_by_name", name)) if classes.empty?
          source_category = untyped_param_source_category(origins)
          bucket = strip_nilable(type.to_s) == "T.untyped" ? untyped_param_bucket(method, name, classes, rec) : weak_signature_type_reason(type)
          action = actions[["param", method["path"], method["line"].to_i, name.to_s]]
          primary = param_slot_primary_reason(type, bucket, source_category, origins, action)
          rows << signature_slot_row(method, "param", name, type, strength, primary,
            evidence_count: origins.size + classes.size,
            detail: param_slot_detail(bucket, source_category, origins),
            action: action,
            protocol_hint: bucket == "runtime union; kept T.untyped by policy" ? protocol_hint(method, name, classes, protocol_index) : nil)
        end

        return_type = sig.match?(/\bvoid\b/) ? "void" : extract_return_type(sig)
        if return_type
          strength = signature_slot_strength(return_type)
          if strength != "strong"
            origin = method["return_origin"] ||
              return_origins[[method["path"], method["line"].to_i, method["class"].to_s, method["method"].to_s, method["kind"].to_s]] || {}
            classes = Array(rec&.dig("returns"))
            source_category = untyped_return_source_category(method.merge("return_origin" => origin))
            bucket = strip_nilable(return_type.to_s) == "T.untyped" ? untyped_return_bucket(method, rec, unused_return_names) : weak_signature_type_reason(return_type)
            primary = return_slot_primary_reason(return_type, bucket, source_category, origin)
            action = actions[["return", method["path"], method["line"].to_i, nil]]
            rows << signature_slot_row(method, "return", "return", return_type, strength, primary,
              evidence_count: Array(origin["sources"]).size + classes.size,
              detail: return_slot_detail(bucket, source_category, origin),
              action: action)
          end
        end
        rows
      end
    end

    def signature_slot_row(method, slot_kind, slot_name, type, strength, primary, evidence_count:, detail:, action:, protocol_hint: nil)
      text = "#{method["path"]}:#{method["line"]} #{method["class"]}##{method["method"]} #{slot_name}; #{type}; #{detail}"
      text += "; protocol hint #{protocol_hint}" if protocol_hint
      text += "; candidate action #{action["kind"]} (#{action["confidence"]})" if action
      # A slot's `detail` can embed a raw source slice (e.g.
      # MIRLowering#lower's entire `case node ... end`). Collapse all
      # whitespace runs to single spaces and cap length so every
      # evidence bullet stays a single Markdown line.
      text = text.gsub(/\s+/, " ").strip
      text = "#{text[0, 240]} ..." if text.length > 240
      {
        "slot_kind" => slot_kind,
        "slot" => slot_name.to_s,
        "type" => type,
        "strength" => strength,
        "primary_reason" => primary,
        "evidence_count" => evidence_count.to_i,
        "example" => text,
      }
    end

    def append_signature_evidence_bucket_lines(lines, rows)
      if rows.empty?
        lines << "- none"
        return
      end
      rows.group_by { |row| row["primary_reason"] }
        .sort_by { |reason, list| [-list.size, reason] }
        .each do |reason, list|
          evidence_count = list.sum { |row| row["evidence_count"].to_i }
          weak = list.count { |row| row["strength"] == "weak" }
          untyped = list.count { |row| row["strength"] == "untyped" }
          lines << "- #{reason}: #{list.size} slot(s); weak #{weak}, untyped #{untyped}; evidence #{evidence_count}"
          list.sort_by { |row| [-row["evidence_count"].to_i, row["example"]] }.first(8).each do |row|
            lines << "  - #{row["example"]}; evidence #{row["evidence_count"]}"
          end
        end
    end

    def signature_action_lookup(evidence)
      Array(evidence["actions"]).each_with_object({}) do |action, lookup|
        case action["kind"]
        when "fix_sig_param", "narrow_generic_param"
          key = ["param", action["path"], action["line"].to_i, action.dig("data", "name").to_s]
        when "fix_sig_return", "narrow_generic_return"
          key = ["return", action["path"], action["line"].to_i, nil]
        else
          next
        end
        current = lookup[key]
        lookup[key] = action if current.nil? || signature_action_rank(action) < signature_action_rank(current)
      end
    end

    def signature_action_rank(action)
      return 0 if action["confidence"] == HIGH
      return 1 if action["confidence"] == REVIEW
      2
    end

    # Was O(slots x param_origins): every method-slot rescanned ALL
    # param_origins (thousands, whole-project) -> ~70% of the report
    # tail. callee is the exact first filter, so index by it ONCE
    # (memoized on the origins array, immutable during a report) and
    # filter only the tiny per-callee group. group_by preserves order,
    # so the per-callee group filtered by the slot predicate is exactly
    # (and in the same order as) the original combined select ->
    # byte-identical.
    def param_origins_by_callee(origins)
      (@param_origins_by_callee ||= {})[origins.object_id] ||=
        origins.group_by { |origin| origin["callee"].to_s }
    end

    def param_origins_for_slot(origins, method, name, idx)
      Array(param_origins_by_callee(origins)[method["method"].to_s]).select do |origin|
        origin["slot"].to_s == idx.to_s || origin["slot"].to_s == name.to_s
      end
    end

    def signature_slot_strength(type)
      inner = strip_nilable(type.to_s.strip)
      return "untyped" if untyped_type?(inner)
      return "weak" if weak_type?(inner)
      "strong"
    end

    def weak_signature_type_reason(type)
      inner = strip_nilable(type.to_s)
      if inner.include?("T.any(")
        "weak declared type: union"
      elsif inner.match?(/\AT::Array\b/)
        "weak declared type: array element evidence needed"
      elsif inner.match?(/\AT::Hash\b/)
        "weak declared type: hash key/value evidence needed"
      elsif inner.match?(/\AT::(?:Enumerable|Set)\b/)
        "weak declared type: collection element evidence needed"
      elsif inner.include?("T.untyped")
        "weak declared type: nested T.untyped"
      else
        "weak declared type"
      end
    end

    def param_slot_primary_reason(type, bucket, source_category, origins, action = nil)
      return weak_signature_type_reason(type) unless strip_nilable(type.to_s) == "T.untyped"
      return "candidate: static callsite backflow" if action&.dig("data", "source") == "static_param_backflow"
      return "candidate: runtime-only param observation" if bucket.include?("single observed type") || bucket.include?("boolean pair")
      return "blocked: no static callsite evidence" if origins.empty?
      return "blocked: unknown callsite expression" if source_category == "untyped unknown expression"
      return "blocked: forwarded return argument" if source_category == "untyped forwarded return"
      return "blocked: collection/hash argument evidence" if source_category == "untyped struct/array/collection value"
      return "blocked: runtime union policy" if bucket.include?("runtime union")
      bucket
    end

    def return_slot_primary_reason(type, bucket, source_category, origin)
      return weak_signature_type_reason(type) unless strip_nilable(type.to_s) == "T.untyped"
      return "candidate: void return" if bucket.start_with?("void candidate")
      return "candidate: runtime-only return observation" if bucket.include?("single observed type") || bucket.include?("boolean pair")
      source_kinds = Array(origin["sources"]).map { |source| source["kind"].to_s }.to_set
      return "blocked: forwarded return chain" if source_category == "untyped forwarded return"
      return "blocked: collection/field return evidence" if source_category == "untyped struct/array/collection value"
      return "blocked: instance variable return" if source_category == "untyped instance variable"
      return "blocked: unknown return expression" if source_kinds.include?("unknown") || source_category == "untyped unknown expression"
      return "blocked: runtime union policy" if bucket.include?("runtime union")
      bucket
    end

    def param_slot_detail(bucket, source_category, origins)
      origin_labels = origins.first(3).map { |origin| "#{origin["path"]}:#{origin["line"]} #{origin["code"]}" }
      origin_text = origin_labels.empty? ? "no static callsite origin" : origin_labels.join("; ")
      "#{bucket}; #{source_category}; #{origin_text}"
    end

    def return_slot_detail(bucket, source_category, origin)
      source_labels = Array(origin["sources"]).first(3).map { |source| [source["kind"], source["code"]].compact.join(" ") }
      source_text = source_labels.empty? ? "no static return origin" : source_labels.join("; ")
      "#{bucket}; #{source_category}; #{source_text}"
    end

    def extract_param_entries(sig)
      params = extract_call_args(sig, "params")
      return [] unless params
      split_top_level(params).filter_map do |entry|
        name, type = entry.split(/:\s*/, 2)
        next unless name && type
        [name.strip, type.strip]
      end
    end

    def untyped_param_bucket(method, name, classes, rec)
      classes = Array(classes).compact.uniq
      return "slot not observed: no matching runtime record" unless rec
      return "slot not observed: method was not hit" if rec["calls"].to_i.zero?
      if classes.empty?
        param = Array(method["params"]).find { |p| p["name"] == name }
        return "slot not observed: source index did not model this param shape" unless param
        return "slot not observed: defaultable param not observed" if param["nil_default"]
        return "slot not observed: block-like param not captured" if method["uses_yield"] && name.match?(/\A(block|blk|visitor|callback)\z/)
        return "slot not observed: method hit but runtime slot was empty"
      end
      non_nil = classes.reject { |klass| klass == "NilClass" }
      return "nil only observed" if non_nil.empty?
      return "single observed type; narrow candidate" if non_nil.size == 1
      return "boolean pair; T::Boolean candidate" if non_nil.sort == %w[FalseClass TrueClass]
      return "runtime union; kept T.untyped by policy" if non_nil.size > 1
      "unknown"
    end

    def untyped_return_bucket(method, rec, unused_return_names)
      return "void candidate; return value appears unused" if unused_return_names.include?(method["method"].to_sym)
      classes = Array(rec&.dig("returns")).compact.uniq
      return "slot not observed: no matching runtime record" unless rec
      return "slot not observed: method was not hit" if rec["calls"].to_i.zero?
      return "slot not observed: method hit but return was not captured" if classes.empty?
      non_nil = classes.reject { |klass| klass == "NilClass" }
      return "nil only observed" if non_nil.empty?
      return "single observed type; narrow candidate" if non_nil.size == 1
      return "boolean pair; T::Boolean candidate" if non_nil.sort == %w[FalseClass TrueClass]
      return "runtime union; kept T.untyped by policy" if non_nil.size > 1
      "unknown"
    end

    def append_untyped_param_source_categories(lines, methods, origins)
      buckets = Hash.new(0)
      examples = Hash.new { |hash, key| hash[key] = [] }
      methods.each do |method|
        params = Array(method["params"])
        extract_param_entries(method["sig"].to_s).each_with_index do |(name, type), idx|
          next unless type == "T.untyped"
          # Identical predicate to param_origins_for_slot -- route
          # through it so this shares the memoized by-callee index
          # (was the same O(slots x origins) rescan).
          slot_origins = param_origins_for_slot(origins, method, name, idx)
          bucket = untyped_param_source_category(slot_origins)
          buckets[bucket] += 1
          if examples[bucket].size < 8
            param = params.find { |p| p["name"] == name }
            labels = slot_origins.first(3).map { |origin| "#{origin["path"]}:#{origin["line"]} #{origin["code"]}" }
            details = labels.empty? ? "no static callsite origin" : labels.join("; ")
            details += "; param default nil" if param && param["nil_default"]
            examples[bucket] << "#{method["path"]}:#{method["line"]} #{method["class"]}##{method["method"]} #{name}; #{details}"
          end
        end
      end
      lines << ""
      lines << "### Param T.untyped Source Categories"
      append_bucket_lines(lines, buckets, examples)
    end

    def untyped_param_source_category(origins)
      origins = Array(origins)
      return "untyped unknown expression" if origins.empty?
      origin_kinds = origins.map { |origin| origin["origin_kind"].to_s }.to_set
      types = origins.filter_map { |origin| origin["type"].to_s if origin["type"] }
      codes = origins.map { |origin| origin["code"].to_s }
      if codes.any? { |code| code.match?(/\A@{1,2}[A-Za-z_]\w*\z/) || code.match?(/\A\$[A-Za-z_]\w*\z/) || code.include?("instance_variable_get") }
        "untyped instance variable"
      elsif origin_kinds.include?("untyped_return") || origin_kinds.include?("typed_return")
        "untyped forwarded return"
      elsif types.any? { |type| weak_collection_return_source?(type, []) } || codes.any? { |code| code.start_with?("[", "{") }
        "untyped struct/array/collection value"
      elsif origin_kinds.include?("static")
        "untyped literal/static expression"
      else
        "untyped unknown expression"
      end
    end

    def append_untyped_return_source_categories(lines, methods)
      buckets = Hash.new(0)
      examples = Hash.new { |hash, key| hash[key] = [] }
      methods.each do |method|
        next unless extract_return_type(method["sig"].to_s) == "T.untyped"
        bucket = untyped_return_source_category(method)
        buckets[bucket] += 1
        examples[bucket] << "#{method["path"]}:#{method["line"]} #{method["class"]}##{method["method"]}" if examples[bucket].size < 8
      end
      lines << ""
      lines << "### Return T.untyped Source Categories"
      append_bucket_lines(lines, buckets, examples)
    end

    def untyped_return_source_category(method)
      origin = method["return_origin"] || {}
      sources = Array(origin["sources"])
      source_kinds = sources.map { |source| source["kind"].to_s }.to_set
      candidate = origin["candidate_type"].to_s
      if source_kinds.include?("ivar_read")
        "untyped instance variable"
      elsif source_kinds.include?("call_untyped") || source_kinds.include?("setter_assignment_unknown")
        "untyped forwarded return"
      elsif weak_collection_return_source?(candidate, sources)
        "untyped struct/array/collection value"
      elsif source_kinds.any? { |kind| %w[static nil typed_call safe_call setter_assignment].include?(kind) }
        "untyped literal/static expression"
      else
        "untyped unknown expression"
      end
    end

    def weak_collection_return_source?(candidate, sources)
      return true if candidate.match?(/\AT::(?:Array|Hash|Enumerable|Set)\b/)
      sources.any? { |source| source["type"].to_s.match?(/\AT::(?:Array|Hash|Enumerable|Set)\b/) }
    end

    def append_unknown_expression_breakdowns(lines, methods, param_origins)
      untyped_param_slots = untyped_param_slot_keys(methods)
      param_buckets = Hash.new(0)
      param_examples = Hash.new { |hash, key| hash[key] = [] }
      param_origins.select { |origin| origin["origin_kind"] == "unknown" && untyped_param_origin?(origin, untyped_param_slots) }.each do |origin|
        bucket = unknown_expression_bucket(origin["unknown_reasons"])
        param_buckets[bucket] += 1
        param_examples[bucket] << "#{origin["path"]}:#{origin["line"]} #{origin["callee"]}(#{origin["slot"]}) #{origin["code"]}" if param_examples[bucket].size < 8
      end

      return_buckets = Hash.new(0)
      return_examples = Hash.new { |hash, key| hash[key] = [] }
      methods.each do |method|
        next unless extract_return_type(method["sig"].to_s) == "T.untyped"
        unknown_sources = Array(method.dig("return_origin", "sources")).select { |source| source["kind"] == "unknown" }
        unknown_sources.each do |source|
          bucket = unknown_expression_bucket(source["unknown_reasons"])
          return_buckets[bucket] += 1
          return_examples[bucket] << "#{method["path"]}:#{method["line"]} #{method["class"]}##{method["method"]} #{source["code"]}" if return_examples[bucket].size < 8
        end
      end

      lines << ""
      lines << "### Param Unknown Expression Causes"
      append_bucket_lines(lines, param_buckets, param_examples)
      lines << ""
      lines << "### Return Unknown Expression Causes"
      append_bucket_lines(lines, return_buckets, return_examples)
    end

    def untyped_param_slot_keys(methods)
      methods.each_with_object(Set.new) do |method, slots|
        extract_param_entries(method["sig"].to_s).each_with_index do |(name, type), idx|
          next unless type == "T.untyped"
          slots << [method["method"].to_s, idx.to_s]
          slots << [method["method"].to_s, name.to_s]
        end
      end
    end

    def untyped_param_origin?(origin, slots)
      slots.include?([origin["callee"].to_s, origin["slot"].to_s])
    end

    def unknown_expression_bucket(reasons)
      reasons = Array(reasons).map(&:to_s).reject(&:empty?)
      return "unknown expression with no nested cause" if reasons.empty?
      operations = reasons.select { |reason| reason.start_with?("operation ") }
      non_literals = reasons.reject { |reason| reason.start_with?("operation ") || reason.start_with?("literal/static expression ") }
      causes =
        if non_literals.any?
          non_literals
        elsif operations.any?
          operations
        else
          reasons
        end
      families = causes.map { |reason| unknown_reason_family(reason) }.uniq
      return "unknown expression with multiple unknown types" if families.size > 1
      unknown_reason_label(causes.first)
    end

    def unknown_reason_family(reason)
      case reason
      when /\Aforwarded return/ then "forwarded"
      when /\Ainstance variable/, /\Aclass variable/, /\Aglobal variable/ then "instance"
      when /\Astruct\/array\/collection value/ then "collection"
      when /\Aliteral\/static expression/ then "literal"
      when /\Alocal variable/ then "local"
      else "operation"
      end
    end

    def unknown_reason_label(reason)
      case reason
      when /\Aforwarded return (.+)\z/ then "unknown forwarded return #{$1}"
      when /\Ainstance variable (.+)\z/ then "unknown instance variable #{$1}"
      when /\Aclass variable (.+)\z/ then "unknown class variable #{$1}"
      when /\Aglobal variable (.+)\z/ then "unknown global variable #{$1}"
      when /\Astruct\/array\/collection value (.+)\z/ then "unknown struct/array/collection value #{$1}"
      when /\Aliteral\/static expression (.+)\z/ then "unknown literal/static expression #{$1}"
      when /\Alocal variable (.+)\z/ then "unknown local variable #{$1}"
      when /\Aoperation (.+)\z/ then "unknown operation #{$1}"
      else "unknown expression #{reason}"
      end
    end


    def append_bucket_lines(lines, buckets, examples = {})
      if buckets.empty?
        lines << "- none"
        return
      end
      buckets.sort_by { |_, count| -count }.each do |name, count|
        lines << "- #{name}: #{count}"
        bucket_examples(examples[name]).first(8).each do |example|
          # Examples can embed a raw source slice (a multi-line `case`
          # body etc.). Collapse whitespace runs and cap length so each
          # stays a single Markdown bullet.
          one_line = example.to_s.gsub(/\s+/, " ").strip
          one_line = "#{one_line[0, 240]} ..." if one_line.length > 240
          lines << "  - #{one_line}"
        end
      end
    end

    def record_bucket_example!(examples, key, text)
      current = examples[key] ||= { "count" => 0, "text" => text }
      current["count"] += 1
    end

    def bucket_examples(examples)
      case examples
      when Hash
        examples.values.sort_by { |example| [-example["count"].to_i, example["text"].to_s] }.map do |example|
          count = example["count"].to_i
          prefix = count == 1 ? "1 slot" : "#{count} slots"
          "#{prefix}: #{example["text"]}"
        end
      else
        Array(examples)
      end
    end

    def slot_example_key(method)
      [method["path"], method["line"], method["class"], method["method"]].join(":")
    end

    def slot_example(method, slot_name, classes, rec, protocol_hint: nil)
      observed = Array(classes).compact.uniq.sort
      observed_text = observed.empty? ? "no observed runtime type" : observed.first(8).join(", ")
      observed_text += ", ..." if observed.size > 8
      calls = rec ? rec["calls"].to_i : 0
      base = "#{method["path"]}:#{method["line"]} #{method["class"]}##{method["method"]} #{slot_name}; #{calls} call(s); observed #{observed_text}"
      protocol_hint ? "#{base}; #{protocol_hint}" : base
    end

    def protocol_hint(method, name, observed_classes, protocol_index)
      protocol = method.dig("protocols", name) || {}
      required = Array(protocol["methods"]).reject { |m| ignorable_protocol_method?(m) }.uniq.sort
      aliases = Array(protocol["aliases"])
      gaps = Array(protocol["gaps"])
      parts = []
      if required.empty?
        parts << "direct protocol: none observed"
      else
        observed = Array(observed_classes).reject { |klass| klass == "NilClass" || klass == "T.untyped" }.to_set
        strength = protocol_strength(required)
        candidates = []
        unless strength == "weak"
          candidates = protocol_index.filter_map do |klass, methods|
            next if observed.include?(klass)
            klass if required.all? { |method_name| methods.include?(method_name) }
          end.sort.first(8)
        end
        parts << "#{strength} direct protocol ##{required.join(", #")}"
        parts << "other potential options, not exhaustive: #{candidates.join(", ")}" unless candidates.empty?
      end
      parts << "analysis gaps: aliases seen #{aliases.first(4).join(", ")}" unless aliases.empty?
      parts << "analysis gaps: #{gaps.first(3).join("; ")}" unless gaps.empty?
      parts.join("; ")
    end

    def protocol_strength(methods)
      useful = Array(methods).reject { |name| generic_protocol_method?(name) }
      return "strong" if useful.size >= 2
      return "medium" if useful.size == 1
      "weak"
    end

    def generic_protocol_method?(name)
      %w[
        [] []= each each_pair each_value map flat_map select reject find detect any? all? none? one?
        include? key? keys values empty? size length first last to_a to_h to_s inspect hash eql? ==
      ].include?(name)
    end

    def ignorable_protocol_method?(name)
      %w[
        nil? class is_a? kind_of? instance_of? object_id respond_to?
        instance_variable_get instance_variable_set itself tap then yield_self
      ].include?(name)
    end

    def protocol_class_index(evidence)
      index = Hash.new { |h, k| h[k] = Set.new }
      all_methods = Array(evidence.dig("facts", "existing_sigs")) + Array(evidence.dig("facts", "unsigned_methods"))
      all_methods.each do |method|
        next unless method["kind"] == "instance" && !method["class"].to_s.empty?
        index[method["class"]] << method["method"]
      end
      Array(evidence.dig("facts", "struct_declarations")).each do |decl|
        Array(decl["fields"]).each { |field| index[decl["class"]] << field }
      end
      struct_rbi_types.each_key do |klass, field|
        index[klass] << field
      end
      index
    end

    def unused_return_method_names(evidence)
      unused_return_methods(evidence).map { |method| method["method"].to_sym }.to_set
    end

    def unused_return_methods_by_location
      unused_return_methods(@store.to_h).each_with_object({}) do |method, lookup|
        lookup[method_location_key(method)] = method
      end
    end

    def unused_return_methods(evidence)
      untyped_candidates = evidence["facts"]["existing_sigs"].select do |method|
        method["sig"].to_s.include?(".returns(T.untyped)")
      end
      untyped_candidates_by_name = untyped_candidates.group_by { |method| method["method"].to_sym }
      all_candidates_by_name = Array(evidence.dig("facts", "existing_sigs")).select do |method|
        sig = method["sig"].to_s
        sig.match?(/\bvoid\b/) || extract_return_type(sig)
      end.group_by { |method| method["method"].to_sym }
      candidate_names = all_candidates_by_name.select { |_name, methods| methods.size == 1 }.keys.to_set
      untyped_candidate_names = untyped_candidates_by_name.select { |name, methods| methods.size == 1 && candidate_names.include?(name) }.keys.to_set
      return [] if untyped_candidate_names.empty?
      method_return_types = unambiguous_method_return_types(evidence)

      used = Set.new
      return_edges = Hash.new { |hash, key| hash[key] = Set.new }
      if evidence.dig("facts")&.key?("return_usage_sites")
        apply_return_usage_sites(Array(evidence.dig("facts", "return_usage_sites")), candidate_names, method_return_types, used, return_edges)
        propagate_return_usage!(used, return_edges)
        return (untyped_candidate_names - used).filter_map { |name| untyped_candidates_by_name.fetch(name).first }
      end

      evidence_target_files(evidence).each do |path|
        parsed = NilKill.cached_parse_file(path)
        next unless parsed.success?
        mark_return_usage_graph(parsed.value, :statement, nil, candidate_names, method_return_types, used, return_edges)
      end
      propagate_return_usage!(used, return_edges)
      (untyped_candidate_names - used).filter_map { |name| untyped_candidates_by_name.fetch(name).first }
    end

    def apply_return_usage_sites(sites, candidate_names, method_return_types, used, return_edges)
      sites.each do |site|
        name = site["name"].to_s.to_sym
        next unless candidate_names.include?(name)
        context = site["context"].to_s
        current_method_name = site["current_method"].to_s
        current_method = current_method_name.empty? ? nil : current_method_name.to_sym
        if context == "return" && current_method && candidate_names.include?(current_method)
          if typed_value_return?(method_return_types[current_method])
            used << name
          else
            return_edges[current_method] << name
          end
        elsif context == "return" && method_return_types[current_method] != "void"
          used << name
        elsif context == "value"
          used << name
        end
      end
    end

    def unambiguous_method_return_types(evidence)
      by_name = Array(evidence.dig("facts", "existing_sigs")).group_by { |method| method["method"].to_sym }
      by_name.each_with_object({}) do |(name, methods), types|
        next unless methods.size == 1
        sig = methods.first["sig"].to_s
        types[name] = sig.include?("void") ? "void" : extract_return_type(sig)
      end
    end

    def propagate_return_usage!(used, return_edges)
      changed = true
      while changed
        changed = false
        return_edges.each do |caller, callees|
          next unless used.include?(caller)
          callees.each do |callee|
            next if used.include?(callee)
            used << callee
            changed = true
          end
        end
      end
    end

    def mark_return_usage_graph(node, context, current_method, candidate_names, method_return_types, used, return_edges)
      return unless node
      case node
      when Syntax::DefNode
        mark_return_usage_graph(node.body, :return, node.name, candidate_names, method_return_types, used, return_edges)
      when Syntax::BodyStatementNode, Syntax::BeginNode
        mark_return_usage_graph(node.statements, context, current_method, candidate_names, method_return_types, used, return_edges)
      when Syntax::StatementsNode
        body = node.body || []
        body.each_with_index do |child, idx|
          child_context = idx == body.length - 1 ? context : :statement
          mark_return_usage_graph(child, child_context, current_method, candidate_names, method_return_types, used, return_edges)
        end
      when Syntax::ReturnNode
        node.child_nodes.compact.each { |child| mark_return_usage_graph(child, :return, current_method, candidate_names, method_return_types, used, return_edges) }
      when Syntax::ArgumentsNode
        node.child_nodes.compact.each { |child| mark_return_usage_graph(child, context, current_method, candidate_names, method_return_types, used, return_edges) }
      when Syntax::IfNode
        mark_return_usage_graph(node.predicate, :value, current_method, candidate_names, method_return_types, used, return_edges) if node.respond_to?(:predicate)
        mark_return_usage_graph(node.statements, context, current_method, candidate_names, method_return_types, used, return_edges)
        mark_return_usage_graph(node.subsequent, context, current_method, candidate_names, method_return_types, used, return_edges)
      when Syntax::ElseNode
        mark_return_usage_graph(node.statements, context, current_method, candidate_names, method_return_types, used, return_edges)
      when Syntax::CallNode
        if candidate_names.include?(node.name)
          if context == :return && current_method && candidate_names.include?(current_method)
            if typed_value_return?(method_return_types[current_method])
              used << node.name
            else
              return_edges[current_method] << node.name
            end
          elsif context == :return && method_return_types[current_method] != "void"
            used << node.name
          elsif context == :value
            used << node.name
          end
        end
        node.child_nodes.compact.each { |child| mark_return_usage_graph(child, :value, current_method, candidate_names, method_return_types, used, return_edges) }
      else
        node.child_nodes.compact.each { |child| mark_return_usage_graph(child, :value, current_method, candidate_names, method_return_types, used, return_edges) } if node.respond_to?(:child_nodes)
      end
    end

    def typed_value_return?(return_type)
      return_type && return_type != "void" && return_type != "T.untyped"
    end

    def append_struct_report(lines, evidence)
      facts = evidence["facts"]
      runtime = Array(facts["struct_field_runtime"])
      static = Array(facts["struct_field_static"])
      declarations = Array(facts["struct_declarations"])
      lines << ""
      lines << "## Struct Shape Report"
      lines << "- Struct declarations: #{declarations.size}"
      lines << "- Runtime-observed struct field slots: #{runtime.map { |r| [r["class"], r["field"]] }.uniq.size}"
      lines << "- Static constructor field observations: #{static.size}"
      append_struct_field_breakdown(lines, declarations, runtime, static)
      append_struct_field_candidates(lines, runtime, static)
    end

    def append_struct_field_coverage(lines, declarations, accumulator: nil)
      rbi_types = struct_field_types(@evidence || {})
      counts = empty_type_counts.merge("missing" => 0)
      declarations.each do |decl|
        Array(decl["fields"]).each do |field|
          type = struct_declared_type(decl, field, rbi_types)
          if type
            classify_type!(counts, type)
          else
            counts["missing"] += 1
          end
        end
      end
      total_with_missing = counts["strong"] + counts["weak"] + counts["untyped"] + counts["missing"]
      lines << ""
      lines << "### Struct Field Slots"
      lines << "- Struct field slots: #{format_type_counts(counts, denominator: total_with_missing)}, missing field type #{counts["missing"]}#{total_with_missing.positive? ? " (#{percent(counts["missing"], total_with_missing)})" : ""}"
      lines << "  - of which weak primitive collection (T::Array[T.untyped] etc.): #{counts["weak_collection"]}" if counts["weak_collection"].to_i.positive?
      lines << "- Nilable struct field slots: #{counts["nilable"]}"
      accumulator&.add("struct_field", counts)
    end

    def append_struct_field_breakdown(lines, declarations, runtime, static)
      rbi_types = struct_field_types(@evidence || {})
      candidates = struct_field_candidates(runtime, static).each_with_object({}) { |c, h| h[[c["class"], c["field"]]] = c }
      buckets = Hash.new { |h, k| h[k] = [] }
      declarations.each do |decl|
        Array(decl["fields"]).each do |field|
          key = [decl["class"], field]
          type = struct_declared_type(decl, field, rbi_types)
          candidate = candidates[key]
          bucket =
            if type.nil?
              candidate ? "missing field type with candidate" : "missing field type with no candidate"
            elsif untyped_type?(strip_nilable(type))
              if candidate&.fetch("runtime_calls", 0).to_i.positive?
                "untyped with runtime candidate"
              elsif candidate
                "untyped with static candidate"
              else
                "untyped with no candidate"
              end
            elsif weak_type?(strip_nilable(type))
              "weak collection or union type"
            elsif nilable_type?(type)
              "typed but nilable"
            else
              "strongly typed"
            end
          buckets[bucket] << { "class" => decl["class"], "field" => field, "type" => type, "candidate" => candidate }
        end
      end
      lines << ""
      lines << "### Struct Field Slot Breakdown"
      order = ["missing field type with candidate", "missing field type with no candidate", "untyped with runtime candidate",
        "untyped with static candidate", "untyped with no candidate", "weak collection or union type",
        "typed but nilable", "strongly typed"]
      order.each do |bucket|
        list = buckets[bucket]
        next if list.empty?
        lines << "- #{bucket}: #{list.size}"
        list.first(8).each do |item|
          candidate = item["candidate"]
          candidate_text = candidate ? " -> #{candidate["type"]}#{candidate["runtime_calls"].to_i.positive? ? " (runtime #{candidate["runtime_calls"]})" : " (static)"}" : ""
          current = item["type"] ? " current #{item["type"]}" : ""
          lines << "  - #{item["class"]}.#{item["field"]}#{current}#{candidate_text}"
        end
        lines << "  - ... #{list.size - 8} more" if list.size > 8
      end
    end

    def struct_rbi_types
      StructFieldTypeIndex.from_rbi(ROOT)
    end

    def struct_field_types(evidence)
      source_types = SlotCoverage.new([]).resolved_struct_field_types(evidence)
      struct_rbi_types.merge(source_types) do |_slot, rbi_type, source_type|
        source_strength = type_strength(source_type)
        rbi_strength = type_strength(rbi_type)
        source_strength >= rbi_strength ? source_type : rbi_type
      end
    end

    def type_strength(type)
      inner = strip_nilable(type.to_s)
      return 0 if inner.empty? || untyped_type?(inner)
      return 1 if weak_type?(inner)

      2
    end

    # FactMine records all T.let sites, including locals and constants. Only
    # dependency roots classified as instance fields belong in the structural
    # field/ivar denominator. Root identity also deduplicates repeated writes
    # to the same ivar.
    def state_tlet_sites(evidence)
      sites = Array(evidence.dig("facts", "tlet_sites"))
      canonical = ->(path) { File.expand_path(path.to_s, ROOT) }
      by_location = sites.group_by { |site| [canonical.call(site["path"]), site["line"].to_i] }
      seen = Set.new
      Array(evidence.dig("facts", "type_dependencies")).filter_map do |dependency|
        next unless dependency["candidate"] && dependency["candidate_kind"] == "instance_field"
        next unless seen.add?(dependency["id"].to_s)

        site = Array(by_location[[canonical.call(dependency["file"]), dependency["line"].to_i]]).find { |candidate| candidate["tlet"] }
        next unless site

        site.merge("name" => dependency["name"], "owner" => dependency["owner"])
      end
    end

    # FactMine carries the field type beside each declaration. That is the
    # primary source of truth: generated accessor RBI is an optional fallback,
    # and can legitimately lag a newly indexed source declaration. Treating a
    # missing RBI accessor as an untyped source field made the hygiene report
    # disagree with both the trace plan and the evidence-gap invariant.
    def struct_declared_type(declaration, field, rbi_types = struct_rbi_types)
      field_types = declaration["field_types"] || {}
      direct = field_types[field.to_s] || field_types[field.to_sym]
      effective = rbi_types[[declaration["class"], field]]
      return effective if type_strength(effective) > type_strength(direct)
      return direct unless direct.to_s.empty?

      effective
    end

    def append_struct_field_candidates(lines, runtime, static)
      candidates = struct_field_candidates(runtime, static)
      lines << ""
      lines << "### Struct Field Type Candidates"
      if candidates.empty?
        lines << "- none"
        return
      end
      candidates.first(50).each do |candidate|
        source = candidate["runtime_calls"].positive? ? "runtime" : "static"
        parts = ["#{candidate["class"]}.#{candidate["field"]}", candidate["type"], "#{source}"]
        parts << "#{candidate["runtime_calls"]} call(s)" if candidate["runtime_calls"].positive?
        parts << "#{candidate["nil_count"]} nil observation(s)" if candidate["nil_count"].positive?
        lines << "- #{parts.join("; ")}"
      end
    end

    def struct_field_candidates(runtime, static)
      by_slot = Hash.new { |h, k| h[k] = { "class" => k[0], "field" => k[1], "classes" => [], "elem_classes" => [], "runtime_calls" => 0, "static_count" => 0, "has_unknown_static" => false } }
      runtime.each do |rec|
        key = [rec["class"], rec["field"]]
        slot = by_slot[key]
        slot["classes"] |= Array(rec["classes"])
        slot["elem_classes"] |= Array(rec["elem_classes"])
        slot["runtime_calls"] += rec["calls"].to_i
      end
      static.each do |rec|
        key = [rec["class"], rec["field"]]
        slot = by_slot[key]
        if rec["type"].to_s.empty?
          # Static record where the assigned local's type couldn't be inferred
          # (e.g., `Conflict.new(set_a: inner_op)` where inner_op is T.untyped).
          # Without this flag the slot's candidate set would silently drop
          # the unknown contributor, producing wrong narrowings (the
          # AST::ConcurrentOp.op -> AST::EachOp class of bug).
          slot["has_unknown_static"] = true
        else
          slot["classes"] |= [rec["type"]]
        end
        slot["static_count"] += 1
      end
      by_slot.values.filter_map do |slot|
        # Skip slots with any uninferrable constructor argument: the union is
        # under-determined and a narrow sig will mis-type the field.
        next if slot["has_unknown_static"] && slot["runtime_calls"].zero?
        type = struct_slot_type(slot)
        next unless type && type != "T.untyped"
        # Skip T.nilable candidates -- at any nesting level. Downstream callers
        # in src/ rarely nil-handle the field today, so adding a nilable sig
        # pushes nil-handling burden onto callers (or forces T.must / &.
        # additions -- exactly the pollution we want to delete, not add).
        # Also catches element-level T.nilable (e.g. T::Array[T.nilable(String)])
        # which has the same cascade through `.each { |x| x.method }`.
        # Re-enable when the proposer can verify callers already nil-handle.
        next if type.include?("T.nilable")
        # Skip weak-collection candidates (T::Array[T.untyped] / T::Hash[T.untyped,
        # T.untyped] / T::Set[T.untyped]). They add minimal type info (Sorbet
        # already knows it's some container) AND they trigger the same nil-
        # cascade via Array#[] / Array#first / Hash#[] returning T.nilable.
        # Element/key/value narrowings are the generic narrowers' job, not here.
        next if weak_collection_type?(type)
        slot.merge("type" => type, "nil_count" => slot["classes"].count("NilClass"))
      end.sort_by { |slot| [-slot["runtime_calls"], -slot["static_count"], slot["class"], slot["field"]] }
    end

    def struct_slot_type(slot)
      classes = Array(slot["classes"]).compact.reject(&:empty?)
      if classes == ["Array"] && !slot["elem_classes"].empty?
        elem = NilKill.sorbet_type(slot["elem_classes"], allow_nilable: true, collapse_nodes: false)
        return elem == "T.untyped" ? "T::Array[T.untyped]" : "T::Array[#{elem}]"
      end
      # A struct field is a semantic contract, not merely a telemetry
      # distribution. Collapsing two observed concrete variants to the broad
      # AST::Node/MIR::Node family loses the exact methods consumers rely on
      # and can make an otherwise valid RBI produce hundreds of Sorbet errors.
      # Preserve bounded concrete unions here; if the union exceeds policy,
      # leave the field unresolved for an explicit protocol/type alias.
      NilKill.sorbet_type(classes, allow_nilable: true, collapse_nodes: false)
    end

    def append_hash_shape_candidates(lines, shapes)
      grouped = Hash.new { |h, k| h[k] = { "count" => 0, "sites" => [] } }
      shapes.each do |shape|
        key = Array(shape["keys"]).sort.join(", ")
        grouped[key]["count"] += 1
        grouped[key]["sites"] << "#{shape["path"]}:#{shape["line"]}"
      end
      lines << ""
      lines << "### Hash Shapes That May Want Data/Struct"
      if grouped.empty?
        lines << "- none"
        return
      end
      grouped.sort_by { |_keys, data| -data["count"] }.first(30).each do |keys, data|
        lines << "- {#{keys}} appears #{data["count"]} time(s); first site #{data["sites"].first}"
      end
    end

    def append_collection_report(lines, evidence)
      lines << ""
      lines << "## Collection Type Report"
      slots = collection_signature_slots(evidence)
      append_collection_slot_coverage(lines, slots)
      append_hash_record_struct_candidates(lines, evidence)
      append_collection_slot_candidates(lines, evidence, slots)
      append_collection_blocker_pressure(lines, evidence, slots)
      append_hot_runtime_collection_slots(lines, evidence)
      append_runtime_collection_observations(lines, Array(evidence.dig("facts", "collection_runtime")))
      append_collection_index_lookup_report(lines, Array(evidence.dig("facts", "collection_index_lookups")))
    end

    def append_hash_record_struct_candidates(lines, evidence)
      rows = hash_record_struct_candidates(evidence)
      lines << ""
      lines << "### Hash Record Struct Candidates (Shapes + Pressure)"
      lines << "- literal shape: a statically observed hash literal instantiation site in this candidate cluster"
      lines << "- similar keyset: a distinct hash key set grouped into the same likely record, e.g. `{name, id}` with `{name, id, type}`"
      if rows.empty?
        lines << "- none"
        return
      end
      rows.first(30).each do |row|
        lines << "- #{row["struct_name"]}: #{row["shape_count"]} literal shape(s), #{row["keyset_count"]} similar keyset(s), total pressure #{row["total_pressure"]}"
        lines << "  - common keys: #{row["common_keys"].join(", ")}" unless row["common_keys"].empty?
        lines << "  - optional keys: #{row["optional_keys"].join(", ")}" unless row["optional_keys"].empty?
        unless row["read_counts"].empty?
          used = row["read_counts"].sort_by { |key, count| [-count, key] }.map { |key, count| "#{key}(#{count})" }
          lines << "  - read keys: #{used.join(", ")}"
        end
        lines << "  - accounts for: return #{row["return_slots"]}, param #{row["param_slots"]}, ivar #{row["ivar_slots"]}, collection #{row["collection_slots"]}"
        unless Array(row["related_records"]).empty?
          related = row["related_records"].first(5).map { |record| "#{record["label"]} (#{record["total_pressure"]})" }
          lines << "  - related pressure records: #{related.join("; ")}"
        end
        row["examples"].first(4).each { |example| lines << "  - #{example}" }
        lines << "  - suggested struct:"
        Array(row["nested_structs"]).each do |nested|
          lines << "    class #{nested["struct_name"]} < T::Struct"
          Array(nested["fields"]).each do |field|
            lines << "      #{field["optional"] ? "prop" : "const"} :#{field["name"]}, #{field["type"]}"
          end
          lines << "    end"
          lines << ""
        end
        lines << "    class #{row["struct_name"]} < T::Struct"
        row["fields"].each do |field|
          lines << "      #{field["optional"] ? "prop" : "const"} :#{field["name"]}, #{field["type"]}"
        end
        lines << "    end"
      end
    end

    def hash_record_struct_candidates(evidence)
      if evidence.equal?(@evidence) && defined?(@hash_record_struct_candidates_cache) && @hash_record_struct_candidates_cache
        return @hash_record_struct_candidates_cache
      end
      shape_clusters = clustered_hash_shapes(Array(evidence.dig("facts", "hash_shapes")))
      return [] if shape_clusters.empty?
      clusters_by_exact_key = {}
      shape_clusters.each do |cluster|
        cluster["keysets"].each { |keyset| clusters_by_exact_key[keyset.join("\0")] = cluster }
      end

      lookups = Array(evidence.dig("facts", "collection_index_lookups")).select { |lookup| hash_record_lookup_key(lookup) }
      blockers = Array(evidence.dig("facts", "hash_record_blockers"))
      member_calls = Array(evidence.dig("facts", "hash_record_member_calls"))
      param_origins = Array(evidence.dig("facts", "param_origins"))
      return_sources = Array(evidence.dig("facts", "return_origins")).flat_map { |origin| Array(origin["sources"]) }
      # Was O(lookups x param_origins) + O(lookups x return_sources):
      # every lookup rescanned ALL origins/sources with a per-element
      # .to_s compare (~54s of build_actions on a whole-project index).
      # Index by code ONCE -> O(1) per lookup. group_by preserves
      # order, so the per-code group is exactly (and in the same order
      # as) what `next unless code == lookup_code` yielded -> identical
      # Set contents -> byte-identical.
      param_origins_by_code = param_origins.group_by { |origin| origin["code"].to_s }
      return_sources_by_code = return_sources.group_by { |source| source["code"].to_s }

      lookups.each do |lookup|
        cluster = cluster_for_hash_lookup(lookup, clusters_by_exact_key)
        next unless cluster
        key = hash_record_lookup_key(lookup)
        cluster["read_counts"][key] += 1 if key
        cluster["collection_slot_ids"].add([lookup["path"], lookup["line"], lookup["code"]])
        cluster["ivar_slot_ids"].add([lookup["path"], lookup["line"], lookup["receiver"]]) if hash_record_ivar_lookup?(lookup)
        cluster["examples"] << "#{lookup["path"]}:#{lookup["line"]} #{lookup["code"]}; receiver #{lookup["receiver"]}" if cluster["examples"].size < 6
        cluster["consumers"] << { "path" => lookup["path"], "line" => lookup["line"], "code" => lookup["code"],
          "receiver" => lookup["receiver"], "index" => lookup["index"], "key" => key,
          "lookup_type" => lookup["lookup_type"], "status" => lookup["status"], "origin" => lookup["origin"] }

        lookup_code = lookup["code"].to_s
        Array(param_origins_by_code[lookup_code]).each do |origin|
          cluster["param_slot_ids"].add([origin["path"], origin["line"], origin["callee"], origin["slot"]])
        end
        Array(return_sources_by_code[lookup_code]).each do |source|
          cluster["return_slot_ids"].add([source["path"], source["line"], source["code"]])
        end
      end

      blockers.each do |blocker|
        cluster = cluster_for_hash_blocker(blocker, clusters_by_exact_key)
        next unless cluster
        cluster["blockers"] << blocker
      end

      member_calls.each do |call|
        cluster = cluster_for_hash_member_call(call, clusters_by_exact_key)
        next unless cluster
        field = call["field"].to_s
        cluster["field_member_calls"][field] << call["member"].to_s
        cluster["field_member_examples"][field] << "#{call["path"]}:#{call["line"]} #{call["code"]}" if cluster["field_member_examples"][field].size < 5
      end

      rows = shape_clusters.map do |cluster|
        finalize_hash_record_struct_candidate(cluster)
      end
      attach_related_hash_pressure_records(rows, hash_record_struct_pressure(evidence))
      rows = rows.sort_by { |row| [-row["total_pressure"], -row["shape_count"], row["struct_name"]] }
      @hash_record_struct_candidates_cache = rows if evidence.equal?(@evidence)
      rows
    end

    def attach_related_hash_pressure_records(candidates, pressure_rows)
      candidates.each do |candidate|
        related = pressure_rows.select { |row| pressure_matches_candidate?(row, candidate) }
          .sort_by { |row| [-row["total_pressure"].to_i, row["label"].to_s] }
        candidate["related_records"] = related
      end
    end

    def candidate_matches_pressure?(candidates, pressure_row)
      candidates.any? { |candidate| pressure_matches_candidate?(pressure_row, candidate) }
    end

    def pressure_matches_candidate?(pressure_row, candidate)
      keys = Array(pressure_row["keys"]).map(&:to_s).reject(&:empty?)
      return false if keys.empty?
      union = Array(candidate["union_keys"]).map(&:to_s).to_set
      return false if union.empty?
      intersection = (keys.to_set & union).size
      intersection == keys.size || (intersection.to_f / keys.size) >= 0.6
    end

    def clustered_hash_shapes(shapes)
      exact = {}
      shapes.each do |shape|
        keys = Array(shape["keys"]).map(&:to_s).sort
        next if keys.size < 2
        key = [keys.join("\0"), hash_record_shape_type_partition(shape, keys)].join("\1")
        data = exact[key] ||= {
          "keys" => keys,
          "count" => 0,
          "sites" => [],
          "producers" => [],
          "types" => Hash.new { |h, k| h[k] = [] },
          "value_hash_shapes" => {},
          "value_array_element_shapes" => {},
        }
        data["count"] += 1
        data["sites"] << "#{shape["path"]}:#{shape["line"]}"
        data["producers"] << { "path" => shape["path"], "line" => shape["line"], "code" => shape["code"], "keys" => keys }
        Array(shape["keys"]).zip(Array(shape["value_types"])).each do |field, type|
          data["types"][field.to_s] |= [type.to_s] if NilKill.useful_type?(type)
        end
        merge_cluster_nested_shapes!(data["value_hash_shapes"], shape["value_hash_shapes"])
        merge_cluster_nested_shapes!(data["value_array_element_shapes"], shape["value_array_element_shapes"])
      end

      clusters = []
      exact.values.sort_by { |data| [-data["count"], data["keys"].join(",")] }.each do |data|
        cluster = clusters.find do |candidate|
          similar_hash_keysets?(candidate["union_keys"], data["keys"]) &&
            hash_shape_cluster_type_compatible?(candidate, data)
        end
        unless cluster
          cluster = new_hash_shape_cluster(data["keys"])
          clusters << cluster
        end
        cluster["shape_count"] += data["count"]
        cluster["keysets"] << data["keys"]
        cluster["sites"].concat(data["sites"])
        cluster["producers"].concat(data["producers"])
        cluster["union_keys"] = (cluster["union_keys"] | data["keys"]).sort
        cluster["common_keys"] &= data["keys"]
        data["types"].each { |field, types| cluster["types"][field] |= types }
        merge_cluster_nested_shapes!(cluster["value_hash_shapes"], data["value_hash_shapes"])
        merge_cluster_nested_shapes!(cluster["value_array_element_shapes"], data["value_array_element_shapes"])
      end
      clusters
    end

    def hash_record_shape_type_partition(shape, keys)
      values = Array(shape["keys"]).zip(Array(shape["value_types"])).each_with_object({}) do |(key, type), index|
        index[key.to_s] ||= []
        index[key.to_s] << type.to_s
      end
      keys.filter_map do |field|
        families = hash_record_type_families(values[field])
        next if families.empty?
        "#{field}=#{families.sort.join("|")}"
      end.join(";")
    end

    def merge_cluster_nested_shapes!(target, source)
      Hash(source).each do |field, shape|
        next unless shape
        target[field.to_s] = target[field.to_s] ? merge_hash_record_shapes(target[field.to_s], shape) : dup_hash_shape(shape)
      end
    end

    def dup_hash_shape(shape)
      HashShapeOps.dup_shape(shape, stringify_keys: true)
    end

    def merge_hash_record_shapes(left, right)
      HashShapeOps.merge_shapes(left, right, stringify_keys: true)
    end

    def new_hash_shape_cluster(keys)
      {
        "shape_count" => 0,
        "keysets" => [],
        "union_keys" => keys,
        "common_keys" => keys,
        "sites" => [],
        "producers" => [],
        "consumers" => [],
        "blockers" => [],
        "field_member_calls" => Hash.new { |h, k| h[k] = [] },
        "field_member_examples" => Hash.new { |h, k| h[k] = [] },
        "types" => Hash.new { |h, k| h[k] = [] },
        "value_hash_shapes" => {},
        "value_array_element_shapes" => {},
        "read_counts" => Hash.new(0),
        "examples" => [],
        "collection_slot_ids" => Set.new,
        "param_slot_ids" => Set.new,
        "return_slot_ids" => Set.new,
        "ivar_slot_ids" => Set.new,
      }
    end

    def similar_hash_keysets?(left, right)
      left = Array(left).to_set
      right = Array(right).to_set
      return false if left.empty? || right.empty?
      intersection = (left & right).size
      smaller = [left.size, right.size].min
      union = (left | right).size
      intersection == smaller || (intersection.to_f / union) >= 0.6
    end

    def hash_shape_cluster_type_compatible?(cluster, data)
      shared = Array(cluster["union_keys"]) & Array(data["keys"])
      shared.all? do |field|
        compatible_hash_record_field_types?(cluster["types"][field], data["types"][field])
      end
    end

    def compatible_hash_record_field_types?(left, right)
      left_families = hash_record_type_families(left)
      right_families = hash_record_type_families(right)
      return true if left_families.empty? || right_families.empty?
      !(left_families & right_families).empty?
    end

    def hash_record_type_families(types)
      Array(types).filter_map do |type|
        raw = strip_nilable(type.to_s)
        case raw
        when "String" then "string"
        when "Symbol" then "symbol"
        when "Integer" then "integer"
        when "Float" then "float"
        when "T::Boolean", "TrueClass", "FalseClass" then "boolean"
        when /\A(?:Array|T::Array)\b/ then parameterized_hash_record_family(raw, "array")
        when /\A(?:Hash|T::Hash)\b/ then parameterized_hash_record_family(raw, "hash")
        when /\A[A-Z]\w*(?:::[A-Z]\w*)*\z/ then raw
        end
      end.uniq
    end

    def parameterized_hash_record_family(type, family)
      params = generic_type_params(type)
      return family if params.empty?
      "#{family}<#{params.map { |param| hash_record_type_families([param]).first || param }.join(",")}>"
    end

    def generic_type_params(type)
      start = type.index("[")
      return [] unless start && type.end_with?("]")
      split_top_level(type[(start + 1)...-1]).map(&:strip).reject(&:empty?)
    end

    def cluster_for_hash_lookup(lookup, clusters_by_exact_key)
      origin = lookup["origin"] || {}
      key = nil
      if origin["kind"] == "hash literal"
        key = hash_shape_site_key(origin["path"], origin["line"], origin["code"])
      elsif origin["kind"] == "local hash shape"
        key = Array(origin.dig("shape", "keys")&.keys || origin.dig("shape", "keys")).map(&:to_s).sort.join("\0")
      elsif origin["kind"] == "method parameter" && origin["shape"]
        key = Array(origin.dig("shape", "keys")&.keys || origin.dig("shape", "keys")).map(&:to_s).sort.join("\0")
      end
      return clusters_by_exact_key[key] if key && clusters_by_exact_key[key]
      nil
    end

    def cluster_for_hash_blocker(blocker, clusters_by_exact_key)
      origin = blocker["origin"] || {}
      if origin["kind"] == "hash literal"
        key = hash_shape_site_key(origin["path"], origin["line"], origin["code"])
        return clusters_by_exact_key[key] if key && clusters_by_exact_key[key]
      end
      nil
    end

    def cluster_for_hash_member_call(call, clusters_by_exact_key)
      cluster_for_hash_lookup({ "origin" => call["origin"] }, clusters_by_exact_key)
    end

    def hash_shape_site_key(path, line, code)
      shape = hash_shape_site_index[[path.to_s, line.to_i, code.to_s]]
      Array(shape.fetch("keys", nil)).map(&:to_s).sort.join("\0") unless shape.nil?
    end

    def hash_shape_site_index
      @hash_shape_site_index ||= Array(@evidence&.dig("facts", "hash_shapes")).each_with_object({}) do |shape, index|
        key = [shape["path"].to_s, shape["line"].to_i, shape["code"].to_s]
        index[key] ||= shape
      end
    end

    def finalize_hash_record_struct_candidate(cluster)
      collection_slots = cluster.delete("collection_slot_ids").size
      param_slots = cluster.delete("param_slot_ids").size
      return_slots = cluster.delete("return_slot_ids").size
      ivar_slots = cluster.delete("ivar_slot_ids").size
      common = Array(cluster["common_keys"]).sort
      union = Array(cluster["union_keys"]).sort
      optional = union - common
      fields = union.map do |field|
        type = hash_record_field_type(cluster, field)
        type = "T.untyped" unless NilKill.useful_type?(type)
        type = "T.nilable(#{type})" if optional.include?(field) && type != "T.untyped" && type != "NilClass" && !type.start_with?("T.nilable(")
        data = { "name" => field, "type" => type, "optional" => optional.include?(field) }
        if (nested = hash_record_nested_candidate_field(cluster, field))
          data.merge!(nested)
        end
        members = Array(cluster["field_member_calls"][field]).uniq.sort
        data["required_members"] = members unless members.empty?
        data
      end
      base_name = common.first || union.first || "record"
      struct_name = hash_record_struct_name(base_name)
      scope = hash_record_struct_scope(fields)
      type_name = (scope + [struct_name]).join("::")
      fields.each do |field|
        if (nested = field["nested"])
          nested["type_name"] = (scope + [nested["struct_name"]]).join("::")
          field["type"] = nested["kind"] == "array" ? "T::Array[#{nested["type_name"]}]" : nested["type_name"]
        end
      end
      cluster.merge(
        "struct_name" => struct_name,
        "type_name" => type_name,
        "scope" => scope,
        "struct_path" => hash_record_struct_path_for_scope(scope),
        "keyset_count" => cluster["keysets"].uniq.size,
        "common_keys" => common,
        "optional_keys" => optional,
        "fields" => fields,
        "nested_structs" => hash_record_nested_structs(fields),
        "collection_slots" => collection_slots,
        "param_slots" => param_slots,
        "return_slots" => return_slots,
        "ivar_slots" => ivar_slots,
        "total_pressure" => collection_slots + param_slots + return_slots + ivar_slots
      )
    end

    def hash_record_field_type(cluster, field)
      members = Array(cluster["field_member_calls"][field]).uniq.sort
      protocol_type = hash_record_protocol_type_for_members(members)
      return protocol_type if protocol_type
      return "Object" if hash_record_nested_shape_for_field(cluster, field)
      NilKill.static_sorbet_type(cluster["types"][field])
    end

    def hash_record_nested_candidate_field(cluster, field)
      nested = hash_record_nested_shape_for_field(cluster, field)
      return nil unless nested && nested["shape"] && !nested["shape"]["poisoned"]
      nested_fields = hash_record_fields_for_nested_shape(nested["shape"])
      return nil if nested_fields.empty? || nested_fields.any? { |candidate| NilKill.weak_type?(candidate["type"].to_s) || candidate["type"] == "T.untyped" }
      struct_name = hash_record_struct_name(field)
      { "nested" => nested.merge("struct_name" => struct_name, "fields" => nested_fields) }
    end

    def hash_record_nested_shape_for_field(cluster, field)
      arrays = Hash(cluster["value_array_element_shapes"])
      direct = Hash(cluster["value_hash_shapes"])
      if arrays[field]
        { "kind" => "array", "shape" => arrays[field] }
      elsif direct[field]
        { "kind" => "hash", "shape" => direct[field] }
      end
    end

    def hash_record_fields_for_nested_shape(shape)
      keys = Hash(shape["keys"]).keys.map(&:to_s).sort
      keys.filter_map do |field|
        type = NilKill.static_sorbet_type(shape.dig("keys", field))
        next unless field.match?(/\A[a-z_]\w*\z/) && NilKill.useful_type?(type)
        { "name" => field, "type" => type, "optional" => false }
      end
    end

    def hash_record_nested_structs(fields)
      Array(fields).flat_map do |field|
        nested = field["nested"]
        next [] unless nested
        hash_record_nested_structs(nested["fields"]) + [nested]
      end.uniq { |nested| nested["type_name"] || nested["struct_name"] }
    end

    def hash_record_protocol_type_for_members(members)
      set = members.to_set
      return "AST::Locatable" if %w[full_type token].any? { |member| set.include?(member) }
      nil
    end

    def hash_record_struct_scope(fields)
      namespaces = Array(fields).flat_map { |field| namespaces_in_type(field["type"]) }.uniq
      namespaces.size == 1 ? namespaces.first.split("::") : []
    end

    def namespaces_in_type(type)
      type.to_s.scan(/\b[A-Z]\w*(?:::[A-Z]\w*)+\b/).filter_map do |const|
        parts = const.split("::")
        next if parts.first == "T"
        parts[0...-1].join("::")
      end
    end

    def hash_record_struct_path_for_scope(scope)
      parts = Array(scope).map(&:to_s).reject(&:empty?)
      return nil if parts.empty?
      @hash_record_struct_path_cache ||= {}
      namespace = parts.join("::")
      return @hash_record_struct_path_cache[namespace] if @hash_record_struct_path_cache.key?(namespace)
      preferred = [
        File.join("src", *parts.map { |part| underscore_const(part) }, "#{underscore_const(parts.last)}.rb"),
        File.join("src", "#{underscore_const(parts.last)}.rb"),
      ]
      @hash_record_struct_path_cache[namespace] =
        preferred.find { |path| File.file?(File.join(ROOT, path)) } ||
        hash_record_struct_path_index[parts.last]
    end

    def hash_record_struct_path_index
      self.class.hash_record_struct_path_index
    end

    def self.hash_record_struct_path_index
      @hash_record_struct_path_index ||= Dir.glob(File.join(ROOT, "src/**/*.rb")).each_with_object({}) do |path, index|
        rel = NilKill.rel(path)
        File.foreach(path) do |line|
          next unless line =~ /^\s*(?:module|class)\s+([A-Z]\w*)\b/
          index[$1] ||= rel
        end
      rescue StandardError
        nil
      end
    end

    def underscore_const(name)
      name.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    def hash_record_struct_name(name)
      base = name.to_s.gsub(/[^A-Za-z0-9_]/, "_").split("_").reject(&:empty?).map(&:capitalize).join
      base = "Record" if base.empty?
      "#{base}Record"
    end

    def append_hash_record_struct_pressure(lines, evidence)
      rows = hash_record_struct_pressure(evidence)
      lines << ""
      lines << "### High-Pressure HashMaps Acting As Structs"
      if rows.empty?
        lines << "- none"
        return
      end
      rows.first(30).each do |row|
        lines << "- #{row["label"]}: total pressure #{row["total_pressure"]}; return #{row["return_slots"]}, param #{row["param_slots"]}, ivar #{row["ivar_slots"]}, collection #{row["collection_slots"]}"
        lines << "  - keys: #{row["keys"].join(", ")}" unless row["keys"].empty?
        row["examples"].first(3).each { |example| lines << "  - #{example}" }
      end
    end

    def hash_record_struct_pressure(evidence)
      if evidence.equal?(@evidence) && defined?(@hash_record_struct_pressure_cache) && @hash_record_struct_pressure_cache
        return @hash_record_struct_pressure_cache
      end
      graph = FlowGraph.new
      lookups = Array(evidence.dig("facts", "collection_index_lookups")).select { |lookup| hash_record_lookup?(lookup) }
      param_origins = Array(evidence.dig("facts", "param_origins"))
      return_sources = Array(evidence.dig("facts", "return_origins")).flat_map { |origin| Array(origin["sources"]) }
      # Was O(lookups x param_origins) + O(lookups x return_sources):
      # every lookup rescanned ALL origins/sources with a per-element
      # .to_s compare (~54s of build_actions on a whole-project index).
      # Index by code ONCE -> O(1) per lookup. group_by preserves
      # order, so the per-code group is exactly (and in the same order
      # as) what `next unless code == lookup_code` yielded -> identical
      # Set contents -> byte-identical.
      param_origins_by_code = param_origins.group_by { |origin| origin["code"].to_s }
      return_sources_by_code = return_sources.group_by { |source| source["code"].to_s }
      groups = Hash.new do |hash, key|
        hash[key] = { "label" => key, "keys" => Set.new, "examples" => [],
          "collection_slot_ids" => Set.new, "param_slot_ids" => Set.new, "return_slot_ids" => Set.new,
          "ivar_slot_ids" => Set.new }
      end

      lookups.each do |lookup|
        label = graph.hash_record_label_for_lookup(lookup)
        row = groups[label]
        key = hash_record_lookup_key(lookup)
        row["keys"].add(key) if key
        row["collection_slot_ids"].add([lookup["path"], lookup["line"], lookup["code"]])
        row["ivar_slot_ids"].add([lookup["path"], lookup["line"], lookup["receiver"]]) if hash_record_ivar_lookup?(lookup)
        row["examples"] << "#{lookup["path"]}:#{lookup["line"]} #{lookup["code"]}; receiver type #{lookup["receiver_type"] || "unknown"}" if row["examples"].size < 5

        lookup_code = lookup["code"].to_s
        Array(param_origins_by_code[lookup_code]).each do |origin|
          row["param_slot_ids"].add([origin["path"], origin["line"], origin["callee"], origin["slot"]])
        end
        Array(return_sources_by_code[lookup_code]).each do |source|
          row["return_slot_ids"].add([source["path"], source["line"], source["code"]])
        end
      end

      rows = groups.values.map do |row|
        collection_slots = row.delete("collection_slot_ids").size
        param_slots = row.delete("param_slot_ids").size
        return_slots = row.delete("return_slot_ids").size
        ivar_slots = row.delete("ivar_slot_ids").size
        row.merge(
          "keys" => row["keys"].to_a.sort,
          "collection_slots" => collection_slots,
          "param_slots" => param_slots,
          "return_slots" => return_slots,
          "ivar_slots" => ivar_slots,
          "total_pressure" => collection_slots + param_slots + return_slots + ivar_slots
        )
      end.sort_by { |row| [-row["total_pressure"], -row["collection_slots"], row["label"]] }
      @hash_record_struct_pressure_cache = rows if evidence.equal?(@evidence)
      rows
    end

    def flow_graph(evidence = @evidence)
      @flow_graph ||= FlowGraph.from_evidence(evidence)
    end

    def type_dependency_pressure(evidence = @evidence)
      if evidence.equal?(@evidence)
        @type_dependency_pressure ||= FlowGraph.dependencies_from_evidence(evidence).unlock_pressure
      else
        FlowGraph.dependencies_from_evidence(evidence).unlock_pressure
      end
    end

    def hash_record_lookup?(lookup)
      key = hash_record_lookup_key(lookup)
      return false unless key
      lookup_type = lookup["lookup_type"].to_s
      return false if NilKill.useful_type?(lookup_type) && !NilKill.weak_type?(lookup_type)
      status = lookup["status"].to_s
      status != "typed collection receiver" || lookup["receiver_type"].to_s.include?("T.untyped")
    end

    def hash_record_lookup_key(lookup)
      index = lookup["index"].to_s
      case index
      when /\A:([A-Za-z_]\w*[!?=]?)\z/
        Regexp.last_match(1)
      when /\A["']([^"']+)["']\z/
        Regexp.last_match(1)
      end
    end

    def hash_record_pressure_label(lookup)
      origin = lookup["origin"] || {}
      receiver = lookup["receiver"].to_s
      if origin["kind"].to_s.empty?
        receiver.empty? ? "unknown hash record" : "local hash record #{receiver}"
      elsif origin["kind"] == "method parameter"
        "method parameter hash record #{origin["name"]}"
      elsif origin["kind"] == "instance variable"
        "instance variable hash record #{origin["name"]}"
      elsif receiver.match?(/\A[A-Za-z_]\w*\z/)
        scope = lookup["enclosing_scope"].to_s
        loc = [lookup["path"], scope.empty? ? nil : scope].compact.join(" ")
        "local hash record #{receiver} at #{loc}"
      else
        collection_origin_label(origin)
      end
    end

    def hash_record_ivar_lookup?(lookup)
      lookup["receiver"].to_s.start_with?("@") || lookup.dig("origin", "kind") == "instance variable"
    end

    def collection_signature_slots(evidence)
      method_lookup = evidence["methods"].each_with_object({}) do |method, lookup|
        source = method["source"]
        lookup[[collection_runtime_path_key(source["path"]), source["line"]]] = method if source
      end
      Array(evidence.dig("facts", "existing_sigs")).flat_map do |method|
        rec = method_lookup[[collection_runtime_path_key(method["path"]), method["line"]]]
        entries = extract_param_entries(method["sig"].to_s).filter_map do |name, type|
          info = collection_type_info(type)
          next unless info
          { "slot_kind" => "param", "slot" => name, "type" => type, "info" => info, "method" => method, "runtime" => rec }
        end
        ret = extract_return_type(method["sig"].to_s)
        if (info = collection_type_info(ret))
          entries << { "slot_kind" => "return", "slot" => "return", "type" => ret, "info" => info, "method" => method, "runtime" => rec }
        end
        entries
      end
    end

    def collection_type_info(type)
      raw = strip_nilable(type.to_s.strip)
      return nil if raw.empty?
      case raw
      when /\A(?:Array|T::Array)(?:\[(.*)\])?\z/
        elem = $1
        weak = elem.nil? || elem.include?("T.untyped")
        { "kind" => "array", "element" => elem, "weak" => weak, "raw" => raw }
      when /\A(?:Hash|T::Hash)(?:\[(.*)\])?\z/
        args = $1 ? split_top_level($1) : []
        key = args[0]
        value = args[1]
        weak = key.nil? || value.nil? || key.include?("T.untyped") || value.include?("T.untyped")
        { "kind" => "hash", "key" => key, "value" => value, "weak" => weak, "raw" => raw }
      end
    end

    def append_collection_slot_coverage(lines, slots)
      counts = Hash.new { |h, k| h[k] = { "total" => 0, "strong" => 0, "weak" => 0, "nilable" => 0 } }
      slots.each do |slot|
        kind = slot.dig("info", "kind")
        counts[kind]["total"] += 1
        counts[kind][slot.dig("info", "weak") ? "weak" : "strong"] += 1
        counts[kind]["nilable"] += 1 if nilable_type?(slot["type"].to_s)
      end
      %w[array hash].each do |kind|
        data = counts[kind]
        lines << "- #{kind.capitalize} signature slots: #{data["total"]} total, #{data["strong"]} strong, #{data["weak"]} weak, #{data["nilable"]} nilable"
      end
    end

    def append_collection_slot_candidates(lines, evidence, slots)
      weak = slots.select { |slot| slot.dig("info", "weak") }
      lines << ""
      lines << "### Weak Collection Slots With Runtime Candidates"
      if weak.empty?
        lines << "- none"
        return
      end
      candidates = weak.filter_map { |slot| collection_slot_candidate(slot) }
      if candidates.empty?
        lines << "- none"
      else
        candidates.first(50).each do |candidate|
          method = candidate["method"]
          current = candidate["current"]
          lines << "- #{method["path"]}:#{method["line"]} #{method["class"]}##{method["method"]} #{candidate["slot_kind"]} #{candidate["slot"]}: #{current} -> #{candidate["candidate"]} (#{candidate["calls"]} call(s))"
        end
      end

      no_candidate = weak.reject { |slot| collection_slot_candidate(slot) }
      return if no_candidate.empty?
      lines << ""
      lines << "### Weak Collection Slots Without Candidate"
      no_candidate.first(30).each do |slot|
        method = slot["method"]
        reason = collection_slot_missing_candidate_reason(slot)
        lines << "- #{method["path"]}:#{method["line"]} #{method["class"]}##{method["method"]} #{slot["slot_kind"]} #{slot["slot"]}: #{slot["type"]}; #{reason}"
      end
      lines << "- ... #{no_candidate.size - 30} more" if no_candidate.size > 30
    end

    def collection_slot_candidate(slot)
      rec = slot["runtime"]
      return nil unless rec && rec["calls"].to_i.positive?
      info = slot["info"]
      candidate =
        if info["kind"] == "array"
          elem = slot["slot_kind"] == "return" ? rec["return_elem"] : rec.dig("param_elem", slot["slot"])
          elem_shapes = slot["slot_kind"] == "return" ? rec["return_elem_shapes"] : rec.dig("param_elem_shapes", slot["slot"])
          type = NilKill.shape_union_type(elem_shapes)
          type ||= NilKill.conservative_element_type(elem)
          candidate = type ? "T::Array[#{type}]" : nil
          candidate if candidate && NilKill.acceptable_shape_candidate?(candidate)
        else
          kv = slot["slot_kind"] == "return" ? rec["return_kv"] : rec.dig("param_kv", slot["slot"])
          kv_shapes = slot["slot_kind"] == "return" ? rec["return_kv_shapes"] : rec.dig("param_kv_shapes", slot["slot"])
          key = NilKill.shape_union_type(Array(kv_shapes)[0])
          value = NilKill.shape_union_type(Array(kv_shapes)[1])
          key ||= NilKill.conservative_element_type(Array(kv)[0])
          value ||= NilKill.conservative_element_type(Array(kv)[1])
          candidate = key && value ? "T::Hash[#{key}, #{value}]" : nil
          candidate if candidate && NilKill.acceptable_shape_candidate?(candidate)
        end
      return nil unless candidate && candidate != slot["type"]
      { "method" => slot["method"], "slot_kind" => slot["slot_kind"], "slot" => slot["slot"],
        "current" => slot["type"], "candidate" => candidate, "calls" => rec["calls"].to_i }
    end

    def collection_slot_missing_candidate_reason(slot)
      rec = slot["runtime"]
      return "method not observed at runtime" unless rec && rec["calls"].to_i.positive?
      info = slot["info"]
      if info["kind"] == "array"
        elems = slot["slot_kind"] == "return" ? rec["return_elem"] : rec.dig("param_elem", slot["slot"])
        return "no element observations" if Array(elems).empty?
        "element observations are heterogeneous or AST/MIR-specific: #{Array(elems).first(6).join(", ")}"
      else
        kv = slot["slot_kind"] == "return" ? rec["return_kv"] : rec.dig("param_kv", slot["slot"])
        keys = Array(Array(kv)[0])
        values = Array(Array(kv)[1])
        return "no key/value observations" if keys.empty? && values.empty?
        "key observations #{keys.first(4).join(", ")}; value observations #{values.first(4).join(", ")}"
      end
    end

    def append_collection_blocker_pressure(lines, evidence, slots)
      pressure = collection_blocker_pressure(evidence, slots)
      lines << ""
      lines << "### Collection Blocker Pressure"
      if pressure.empty?
        lines << "- none"
        return
      end
      pressure.first(30).each do |label, data|
        lines << "- #{label}: #{data["slots"].size} slot(s), #{data["calls"]} observation(s)"
        unless data["mutation_sites"].empty?
          top_sites = data["mutation_sites"].sort_by { |site, count| [-count, site] }.first(3)
          lines << "  - mutation sites: #{top_sites.map { |site, count| "#{site} (#{count})" }.join(", ")}"
        end
        data["examples"].first(3).each do |example|
          lines << "  - #{example}"
        end
      end
    end

    def collection_blocker_pressure(evidence, slots)
      runtime_owners = collection_runtime_owner_index(evidence)
      pressure = Hash.new { |h, k| h[k] = { "slots" => Set.new, "calls" => 0, "mutation_sites" => Hash.new(0), "examples" => [] } }
      slots.select { |slot| slot.dig("info", "weak") }.each do |slot|
        candidate = collection_slot_candidate(slot)
        next if candidate && !candidate["candidate"].include?("T.untyped")

        reason = candidate ? "candidate still contains T.untyped: #{candidate["candidate"]}" : collection_slot_missing_candidate_reason(slot)
        owners = collection_slot_runtime_owners(runtime_owners, slot)
        owners = [nil] if owners.empty?
        owners.each do |owner|
          label = collection_blocker_label(slot, owner, reason)
          data = pressure[label]
          data["slots"] << collection_slot_key(slot)
          data["calls"] += owner ? owner["calls"].to_i : slot.dig("runtime", "calls").to_i
          Array(owner && owner["mutation_sites"]).each do |site, count|
            data["mutation_sites"][site] += count.to_i
          end
          example = collection_slot_example(slot)
          data["examples"] << example unless data["examples"].include?(example)
        end
      end
      pressure.sort_by { |label, data| [-data["slots"].size, -data["calls"], label] }.to_h
    end

    def collection_runtime_owner_index(evidence)
      Array(evidence.dig("facts", "collection_runtime")).group_by do |rec|
        [rec["owner_kind"], rec["name"], collection_runtime_path_key(rec["path"]), rec["line"].to_i, rec["kind"]]
      end
    end

    def collection_slot_runtime_owners(index, slot)
      method = slot["method"]
      info = slot["info"]
      kind = info["kind"]
      owner_kind = slot["slot_kind"] == "return" ? "method_return" : "method_param"
      name = slot["slot_kind"] == "return" ? method["method"].to_s : slot["slot"].to_s
      index.fetch([owner_kind, name, collection_runtime_path_key(method["path"]), method["line"].to_i, kind], [])
    end

    def collection_runtime_path_key(path)
      NilKill.rel(File.expand_path(path.to_s, ROOT))
    end

    def collection_blocker_label(slot, owner, reason)
      if owner
        "#{owner["owner_kind"]} #{owner["name"]} #{owner["kind"]} at #{collection_runtime_path_key(owner["path"])}:#{owner["line"]}; #{reason}"
      else
        method = slot["method"]
        "#{method["path"]}:#{method["line"]} #{method["class"]}##{method["method"]} #{slot["slot_kind"]} #{slot["slot"]}; #{reason}"
      end
    end

    def collection_slot_key(slot)
      method = slot["method"]
      [method["path"], method["line"], method["class"], method["method"], slot["slot_kind"], slot["slot"]].join(":")
    end

    def collection_slot_example(slot)
      method = slot["method"]
      "#{method["path"]}:#{method["line"]} #{method["class"]}##{method["method"]} #{slot["slot_kind"]} #{slot["slot"]}: #{slot["type"]}"
    end

    def append_collection_index_lookup_report(lines, lookups)
      lines << ""
      lines << "### Collection Index Lookup Provenance"
      lines << "- provenance: the inferred origin of the collection receiver being indexed with `[]`, `fetch`, or similar lookup syntax"
      lines << "- receiver origin: the parameter, literal, forwarded return, instance variable, or local record that produced the indexed receiver"
      lines << "- weak index lookup: an index lookup where the receiver is unknown, `T.untyped`, or a weak collection type"
      if lookups.empty?
        lines << "- none"
        return
      end
      status_counts = lookups.each_with_object(Hash.new(0)) { |lookup, counts| counts[lookup["status"]] += 1 }
      status_counts.sort_by { |status, count| [-count, status] }.each do |status, count|
        lines << "- #{status}: #{count}"
      end
      weak = lookups.select { |lookup| lookup["status"] != "typed collection receiver" }
      graph = FlowGraph.new
      grouped = weak.each_with_object(Hash.new { |h, k| h[k] = { "count" => 0, "examples" => [] } }) do |lookup, groups|
        label = hash_record_lookup_key(lookup) ? graph.hash_record_label_for_lookup(lookup) : collection_origin_label(lookup["origin"])
        groups[label]["count"] += 1
        groups[label]["examples"] << lookup if groups[label]["examples"].size < 5
      end
      return if grouped.empty?
      lines << ""
      lines << "### Unknown Or Weak Index Lookups By Receiver Origin"
      grouped.sort_by { |label, data| [-data["count"], label] }.first(40).each do |label, data|
        lines << "- #{label}: #{data["count"]}"
        data["examples"].each do |lookup|
          lines << "  - #{lookup["path"]}:#{lookup["line"]} #{lookup["code"]}; receiver #{lookup["receiver"]}; index #{lookup["index"]}; receiver type #{lookup["receiver_type"] || "unknown"}"
        end
      end
    end

    def append_runtime_collection_observations(lines, collections)
      lines << ""
      lines << "### Runtime Collection Mutation Observations"
      if collections.empty?
        lines << "- none"
        return
      end
      grouped = collections.group_by { |rec| rec["owner_kind"] }
      grouped.sort_by { |kind, recs| [-recs.size, kind] }.each do |kind, recs|
        lines << "- #{kind}: #{recs.size} slot(s)"
      end
      collections.sort_by { |rec| [-rec["calls"].to_i, rec["path"], rec["line"].to_i, rec["name"].to_s] }.first(40).each do |rec|
        type =
          case rec["kind"]
          when "hash"
            key = NilKill.conservative_element_type(rec["key_classes"])
            value = NilKill.conservative_element_type(rec["value_classes"])
            key && value ? "T::Hash[#{key}, #{value}]" : "T::Hash[T.untyped, T.untyped]"
          when "set"
            elem = NilKill.conservative_element_type(rec["elem_classes"])
            elem ? "T::Set[#{elem}]" : "T::Set[T.untyped]"
          else
            elem = NilKill.conservative_element_type(rec["elem_classes"])
            elem ? "T::Array[#{elem}]" : "T::Array[T.untyped]"
          end
        lines << "  - #{rec["path"]}:#{rec["line"]} #{rec["owner_kind"]} #{rec["name"]}; #{rec["kind"]}; #{type}; #{rec["calls"]} observation(s)"
      end
    end

    # Collection tracing already records call counts plus the bounded shapes
    # it inspected. Weighting calls by those shapes approximates sampler work
    # without adding a timer, hook, or counter to the traced workload.
    def append_hot_runtime_collection_slots(lines, evidence)
      lines << ""
      lines << "### Hot Runtime Collection Slots"
      lines << "- estimated from existing collection observations and sampled shape complexity; this adds no runtime tracing"
      rows = hot_runtime_collection_slots(evidence)
      if rows.empty?
        lines << "- none"
        return
      end

      rows.first(30).each do |row|
        lines << "- #{row["path"]}:#{row["line"]} #{row["owner_kind"]} #{row["name"]}; #{row["kind"]}; #{row["sampling_pressure"]} sampling-pressure score, #{row["calls"]} total observation(s), #{row["max_process_calls"]} max in one process"
        unless row["mutation_sites"].empty?
          top = row["mutation_sites"].sort_by { |site, count| [-count, site] }.first(3)
          lines << "  - mutation sites: #{top.map { |site, count| "#{site} (#{count})" }.join(", ")}"
        end
      end
    end

    def hot_runtime_collection_slots(evidence)
      grouped = Array(evidence.dig("facts", "collection_runtime")).group_by do |row|
        [
          collection_runtime_path_key(row["path"]),
          row["line"].to_i,
          row["owner_kind"].to_s,
          row["name"].to_s,
          row["kind"].to_s,
        ]
      end
      grouped.map do |(path, line, owner_kind, name, kind), rows|
        mutation_sites = Hash.new(0)
        rows.each do |row|
          Hash(row["mutation_sites"]).each { |site, count| mutation_sites[site] += count.to_i }
        end
        process_work = rows.map do |row|
          row["calls"].to_i * collection_shape_work_per_observation(row)
        end
        {
          "path" => path,
          "line" => line,
          "owner_kind" => owner_kind,
          "name" => name,
          "kind" => kind,
          "calls" => rows.sum { |row| row["calls"].to_i },
          "max_process_calls" => rows.map { |row| row["calls"].to_i }.max.to_i,
          "sampling_pressure" => process_work.sum,
          "max_process_sampling_pressure" => process_work.max.to_i,
          "processes" => rows.size,
          "mutation_sites" => mutation_sites,
        }
      end.sort_by do |row|
        [-row["sampling_pressure"], -row["calls"], -row["max_process_sampling_pressure"], row["path"], row["line"], row["name"]]
      end
    end

    def collection_shape_work_per_observation(row)
      scalar_classes = %w[elem_classes key_classes value_classes].sum do |key|
        Array(row[key]).size
      end
      nested_shapes = %w[elem_shapes key_shapes value_shapes].sum do |key|
        Array(row[key]).sum { |shape| collection_shape_complexity(shape) }
      end
      1 + scalar_classes + nested_shapes
    end

    def collection_shape_complexity(shape)
      shape = Hash(shape)
      case shape["kind"]
      when "array", "set"
        1 + Array(shape["elements"]).sum { |child| collection_shape_complexity(child) }
      when "hash"
        1 + Array(shape["keys"]).sum { |child| collection_shape_complexity(child) } +
          Array(shape["values"]).sum { |child| collection_shape_complexity(child) }
      else
        1
      end
    end

    def collection_origin_label(origin)
      origin ||= {}
      case origin["kind"]
      when "method parameter"
        "method parameter #{origin["name"]}#{origin["type"] ? " (#{origin["type"]})" : ""} at #{origin["path"]}:#{origin["line"]}"
      when "array literal", "hash literal"
        "#{origin["kind"]} #{origin["name"]} at #{origin["path"]}:#{origin["line"]}"
      when "forwarded return"
        "forwarded return #{origin["callee"] || origin["code"]} at #{origin["path"]}:#{origin["line"]}"
      when "instance variable"
        "unresolved instance/global variable #{origin["name"]}"
      else
        [origin["kind"], origin["name"] || origin["code"]].compact.join(" ")
      end
    end

    def append_tuple_report(lines, evidence)
      tuples = Array(evidence["facts"]["tuple_arrays"])
      runtime_tuples = Array(evidence["facts"]["tuple_runtime"])
      grouped = Hash.new { |h, k| h[k] = { "count" => 0, "sites" => [], "confidence" => "review" } }
      tuples.each do |tuple|
        key = Array(tuple["types"]).join(", ")
        grouped[key]["count"] += 1
        grouped[key]["sites"] << "#{tuple["path"]}:#{tuple["line"]}"
        grouped[key]["confidence"] = "high" if tuple["confidence"] == "high"
      end
      lines << ""
      lines << "## Tuple-Like Array Report"
      lines << "- tuple-like array: an array literal whose position-specific element types look meaningful enough to model as a tuple/record"
      lines << "- confidence: `high` means the static shape is regular enough for a likely-safe tuple type; `review` means the shape is useful but needs human inspection"
      lines << "- Tuple-like array literals: #{tuples.size}"
      lines << "- Runtime-observed tuple-like array slots: #{runtime_tuples.map { |tuple| [tuple["kind"], tuple["path"], tuple["line"], tuple["slot"]] }.uniq.size}"
      append_runtime_tuple_list(lines, runtime_tuples)
      if grouped.empty?
        lines << "- none"
        return
      end
      grouped.sort_by { |_types, data| [-data["count"], data["confidence"] == "high" ? 0 : 1] }.first(50).each do |types, data|
        lines << "- [#{types}] appears #{data["count"]} time(s), confidence #{data["confidence"]}; first site #{data["sites"].first}"
      end
    end

    def append_runtime_tuple_list(lines, runtime_tuples)
      lines << ""
      lines << "### Runtime Tuple-Like Array Slots"
      if runtime_tuples.empty?
        lines << "- none"
        return
      end
      runtime_tuples.sort_by { |tuple| [-tuple["calls"].to_i, tuple["path"], tuple["line"].to_i] }.first(30).each do |tuple|
        labels = []
        labels << "complete" if tuple["complete"]
        labels << "mixed" if tuple["mixed"]
        labels << "size #{tuple["size"]}"
        lines << "- #{NilKill.rel(tuple["path"])}:#{tuple["line"]} #{tuple["kind"]} #{tuple["slot"]}; [#{Array(tuple["types"]).join(", ")}]; #{tuple["calls"]} call(s); #{labels.join(", ")}"
      end
    end

    # Accumulator that lets per-section coverage emitters hand their counts
    # back so we can roll up a cross-section primitive-collection summary at
    # the end of the hygiene overview.
    class HygieneCountsAcc
      attr_reader :sections
      def initialize
        @sections = {}
      end
      def add(kind, counts)
        @sections[kind] = counts
      end
    end

    def append_primitive_collection_summary(lines, accumulator)
      sections = accumulator.sections
      return if sections.empty?
      total = sections.values.sum { |c| c["weak_collection"].to_i }
      return if total.zero?
      lines << ""
      lines << "### Primitive Collection Slots (T::Array[T.untyped] / T::Hash[T.untyped, T.untyped] / T::Set[T.untyped])"
      lines << "- Total weak-collection slots across all categories: #{total}"
      [%w[param Param], %w[return Return], %w[struct_field Struct\ field], %w[tlet T.let\ assignment]].each do |key, label|
        c = sections[key]
        next unless c && c["weak_collection"].to_i.positive?
        lines << "  - #{label}: #{c["weak_collection"]}"
      end
    end

    def empty_type_counts
      { "strong" => 0, "weak" => 0, "untyped" => 0, "nilable" => 0, "weak_collection" => 0 }
    end

    def classify_type!(counts, type)
      type = type.to_s.strip
      return if type.empty?
      counts["nilable"] += 1 if nilable_type?(type)
      inner = strip_nilable(type)
      if untyped_type?(inner)
        counts["untyped"] += 1
      elsif weak_type?(inner)
        counts["weak"] += 1
        counts["weak_collection"] += 1 if weak_collection_type?(inner)
      else
        counts["strong"] += 1
      end
    end

    def format_type_counts(counts, denominator: nil)
      total = denominator || (counts["strong"] + counts["weak"] + counts["untyped"])
      return "strong #{counts["strong"]}, weak #{counts["weak"]}, untyped #{counts["untyped"]}" if total.zero?
      "strong #{counts["strong"]} (#{percent(counts["strong"], total)}), " \
        "weak #{counts["weak"]} (#{percent(counts["weak"], total)}), " \
        "untyped #{counts["untyped"]} (#{percent(counts["untyped"], total)})"
    end

    def percent(part, total)
      "%.1f%%" % (100.0 * part / total)
    end

    # `T::Array[T.untyped]` and friends -- container shape known, element type
    # unknown. Counted in "weak" already; this sub-bucket lets us report the
    # primitive-collection-with-untyped-element pressure across all slot kinds.
    def weak_collection_type?(type)
      type.to_s.match?(/\AT::(?:Array|Hash|Enumerable|Set)\b.*T\.untyped/)
    end

    def extract_param_types(sig)
      params = extract_call_args(sig, "params")
      return [] unless params
      split_top_level(params).filter_map do |entry|
        _name, type = entry.split(/:\s*/, 2)
        type&.strip
      end
    end

    def extract_return_type(sig)
      extract_call_args(sig, "returns")
    end

    def extract_call_args(source, name)
      idx = source.index("#{name}(")
      return nil unless idx
      start = idx + name.length + 1
      depth = 1
      i = start
      while i < source.length
        case source[i]
        when "(" then depth += 1
        when ")"
          depth -= 1
          return source[start...i] if depth.zero?
        end
        i += 1
      end
      nil
    end

    def split_top_level(source)
      parts = []
      start = 0
      depth = 0
      source.each_char.with_index do |char, idx|
        case char
        when "(", "[", "{"
          depth += 1
        when ")", "]", "}"
          depth -= 1 if depth.positive?
        when ","
          if depth.zero?
            parts << source[start...idx].strip
            start = idx + 1
          end
        end
      end
      parts << source[start..].to_s.strip
      parts.reject(&:empty?)
    end

    def nilable_type?(type)
      type.start_with?("T.nilable(") || type == "NilClass"
    end

    def strip_nilable(type)
      return type unless type.start_with?("T.nilable(")
      extract_call_args(type, "T.nilable") || type
    end

    def untyped_type?(type)
      type == "T.untyped"
    end

    def weak_type?(type)
      type.include?("T.any(") ||
        type.include?("T.untyped") ||
        type.match?(/\AT::(?:Array|Hash|Enumerable|Set)\b.*\[T\.untyped/)
    end

    def callsite_pressure(actions, kind)
      pressure = Hash.new { |h, k| h[k] = { "slots" => Set.new, "calls" => 0, "actions" => [] } }
      actions.select { |a| a["kind"] == kind }.each do |action|
        next unless pressure_action_unresolved?(action)

        slot = "#{action["path"]}:#{action["line"]}:#{action.dig("data", "name")}"
        (action.dig("data", "callsites") || {}).each do |site, count|
          root = site.sub(/:[^:]+\z/, "")
          pressure[root]["slots"] << slot
          pressure[root]["calls"] += count.to_i
          pressure[root]["actions"] << action.merge("root_calls" => count.to_i)
        end
      end
      pressure
    end

    def pressure_action_unresolved?(action)
      param = method_param_for_action(action)
      return true unless param

      type = param["type"].to_s
      case action["kind"]
      when "nil_param_observed"
        !nilable_type?(type)
      when "union_observed", "bad_input_type_candidate"
        weak_untyped_type?(type)
      else
        true
      end
    end

    def method_param_for_action(action)
      name = action.dig("data", "name").to_s
      return nil if name.empty?

      method = method_at(action["path"], action["line"])
      Array(method && method["params"]).find { |param| param["name"].to_s == name }
    end

    def nilable_type?(type)
      type.include?("T.nilable(") || type == "NilClass"
    end

    def weak_untyped_type?(type)
      type == "T.untyped" || type.include?("[T.untyped") || type.include?(", T.untyped") || type.include?("T.untyped]")
    end

    def merge_pressure(*groups)
      merged = Hash.new { |h, k| h[k] = { "slots" => Set.new, "calls" => 0, "actions" => [] } }
      groups.each do |group|
        group.each do |site, data|
          merged[site]["slots"].merge(data["slots"])
          merged[site]["calls"] += data["calls"].to_i
          merged[site]["actions"].concat(Array(data["actions"]))
        end
      end
      merged
    end

    def append_pressure_list(lines, pressure, label)
      if pressure.empty?
        lines << "- none"
        return
      end
      pressure.sort_by { |_site, data| pressure_sort_key(data) }.first(50).each do |site, data|
        slots = data["slots"].size
        calls = data["calls"].to_i
        score = pressure_priority(slots, calls)
        lines << "- #{site} priority #{format("%.2f", score)}; affects #{label} in #{slots} signature slot(s), #{calls} observed call(s)"
        Array(data["actions"]).uniq { |action| [action["kind"], action["path"], action["line"], action.dig("data", "name")] }.first(5).each do |action|
          lines << "  - #{action["path"]}:#{action["line"]} #{action.dig("data", "name")}#{pressure_action_hint(action)}"
        end
      end
    end

    def pressure_action_hint(action)
      data = action["data"] || {}
      case action["kind"]
      when "nil_param_observed"
        candidate = data["candidate_type"]
        default = default_for_type(candidate)
        parts = []
        parts << "candidate #{candidate}" if NilKill.useful_type?(candidate)
        parts << "default #{default}" if default
        parts.empty? ? "" : " (#{parts.join("; ")})"
      when "union_observed"
        classes = Array(data["classes"])
        text = classes.first(5).join(", ")
        text += ", ..." if classes.size > 5
        " (observed #{text})"
      when "bad_input_type_candidate"
        " (normal calls suggest #{data["candidate_type"]}; raised-only #{Array(data["raised_only_classes"]).join(", ")})"
      else
        ""
      end
    end

    def pressure_sort_key(data)
      slots = data["slots"].size
      calls = data["calls"].to_i
      case ENV.fetch("NIL_KILL_PRESSURE_SORT", "priority")
      when "slots"
        [-slots, -calls]
      when "hotness", "calls"
        [-calls, -slots]
      else
        [-pressure_priority(slots, calls), -slots, -calls]
      end
    end

    def pressure_priority(slots, calls)
      Math.sqrt([slots, 1].max) * (Math.log10([calls, 0].max + 1) + 1.0)
    end
  end
end
