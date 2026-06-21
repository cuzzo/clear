# frozen_string_literal: true

class SourceFactSequenceCallEdges
  def assertion_argument_calls(result)
    assert_equal "uri", result.dig("locations", 0, "physicalLocation", "artifactLocation", "uri")
  end

  def assertion_single_call_argument(coverage, file, dir, v, path)
    with_env("DECOMPLEX_PARSER", "tree_sitter") do
      assert_empty C.classify_file(coverage, file, root: dir)
      assert_nil SlopCop::DecomplexVerdict.lookup(v, path, "plain", 2)
    end
  end

  def symbol_proc_maps(arms, rsf, f)
    arms.map(&:category)
    C.classify_file(rsf.path, f.path).map(&:category)
    C.classify_file(rsf.path, f.path,
                    diagnostic_mids: [:report_invalid_input!]).map(&:category)
  end

  def chained_multiline(files, resultset, repo, ffi_boundary, diagnostic_mids)
    arms = Array(files).flat_map do |file|
      rel = repo_relative(file, repo)
      abs = File.expand_path(rel, repo)
      next [] unless File.file?(abs)

      Classifier.classify_file(
        resultset,
        abs,
        root: repo,
        ffi_boundary: ffi_boundary,
        diagnostic_mids: diagnostic_mids
      ).map { |arm| overlay_arm(arm, repo) }
    end.compact.sort_by do |arm|
      [arm["file"], arm["line"].to_i, arm["method"].to_s, arm["arm_category"].to_s]
    end
    arms
  end
end
