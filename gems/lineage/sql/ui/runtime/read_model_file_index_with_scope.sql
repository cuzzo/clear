-- query-id: ui.runtime.read_model_file_index_with_scope.v1
SELECT path,
               units,
               hazards,
               evidence_covered_hazards,
               covered_hazards,
               distinct_tests,
               mutant_killed_tests,
               tracked_lines,
               covered_lines,
               partial_lines,
               line_coverage,
               mutant_coverage,
               mutant_verified_covered_lines,
               mutant_killed_covered_lines,
               stochastic_mutant_verified_covered_lines,
               stochastic_mutant_killed_covered_lines,
               invariant_mutant_verified_covered_lines,
               invariant_mutant_killed_covered_lines,
               multi_type_covered_lines
        FROM ui_file_summaries
        ORDER BY hazards DESC, mutant_killed_tests DESC, distinct_tests DESC, path
