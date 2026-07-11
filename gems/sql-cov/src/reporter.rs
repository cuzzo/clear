use crate::model::SourceFileCoverage;
use anyhow::Result;
use std::collections::BTreeMap;

pub fn json(coverage: &SourceFileCoverage) -> Result<String> {
    Ok(serde_json::to_string_pretty(coverage)?)
}

pub fn lcov(coverage: &SourceFileCoverage) -> String {
    let mut out = format!("TN:sql-cov\nSF:{}\n", coverage.file_path);
    let mut lines = BTreeMap::<usize, u64>::new();
    for statement in &coverage.statements {
        for line in statement.start_line..=statement.end_line {
            lines
                .entry(line)
                .and_modify(|hits| *hits = (*hits).max(statement.hit_count))
                .or_insert(statement.hit_count);
        }
    }
    let mut branch_found = 0;
    let mut branch_hit = 0;
    for metric in coverage.metrics.iter().filter(|metric| metric.measurable) {
        let states = [
            metric.hit_true_count,
            metric.hit_false_count,
            metric.hit_unknown_count,
        ];
        let branch_count = metric.branch_count();
        for (branch, count) in states.into_iter().take(branch_count).enumerate() {
            let taken = if count == 0 {
                "-".to_string()
            } else {
                count.to_string()
            };
            out.push_str(&format!(
                "BRDA:{},{},{},{}\n",
                metric.span.start_line, metric.span.id, branch, taken
            ));
            branch_found += 1;
            branch_hit += usize::from(count > 0);
        }
    }
    for (line, hits) in &lines {
        out.push_str(&format!("DA:{line},{hits}\n"));
    }
    out.push_str(&format!(
        "LF:{}\nLH:{}\nBRF:{branch_found}\nBRH:{branch_hit}\nend_of_record\n",
        lines.len(),
        lines.values().filter(|hits| **hits > 0).count()
    ));
    out
}

pub fn html(coverage: &SourceFileCoverage) -> String {
    let total = coverage.total_branches();
    let covered = coverage.covered_branches();
    let percent = if total == 0 {
        100.0
    } else {
        covered as f64 * 100.0 / total as f64
    };
    let mut rows = String::new();
    for metric in &coverage.metrics {
        let class = if !metric.measurable {
            "unsupported"
        } else if metric.is_uncovered() {
            "uncovered"
        } else if metric.is_fully_covered() {
            "covered"
        } else {
            "partial"
        };
        rows.push_str(&format!(
            "<tr class=\"{class}\"><td>{}</td><td><code>{}</code></td><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>",
            metric.span.start_line,
            html_escape::encode_text(&metric.span.raw_expression),
            metric.hit_true_count,
            metric.hit_false_count,
            metric.hit_unknown_count,
            class
        ));
    }
    format!(
        r#"<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>SQL-COV {}</title><style>
body{{font:14px/1.45 system-ui;margin:2rem;color:#172033}} header{{display:flex;justify-content:space-between;align-items:end}} pre{{padding:1rem;background:#f5f7fa;overflow:auto;white-space:pre-wrap}} table{{width:100%;border-collapse:collapse}} th,td{{padding:.55rem;border-bottom:1px solid #d8dee8;text-align:left}} .covered{{background:#dcfce7}} .partial{{background:#fef3c7}} .uncovered{{background:#fee2e2}} tr.unsupported{{background:#f3f4f6;color:#5b6472}} mark{{color:inherit;border-radius:2px}} mark.covered{{background:#86efac}} mark.partial{{background:#fde047}} mark.uncovered{{background:#fca5a5}} mark.unsupported{{background:#d1d5db}} code{{font-family:ui-monospace,monospace}} div.unsupported{{border-left:4px solid #d97706;padding:.75rem;background:#fffbeb}}
</style></head><body><header><div><h1>SQL expression coverage</h1><p>{}</p></div><strong>{covered}/{total} branches ({percent:.1}%)</strong></header>{}<h2>Source</h2><pre>{}</pre><h2>Expressions</h2><table><thead><tr><th>Line</th><th>Expression</th><th>TRUE</th><th>FALSE</th><th>UNKNOWN</th><th>Status</th></tr></thead><tbody>{rows}</tbody></table></body></html>"#,
        html_escape::encode_text(&coverage.file_path),
        html_escape::encode_text(&coverage.file_path),
        if coverage.unsupported.is_empty() {
            String::new()
        } else {
            format!(
                "<div class=\"unsupported\"><strong>Instrumentation gaps</strong><ul>{}</ul></div>",
                coverage
                    .unsupported
                    .iter()
                    .map(|row| format!("<li>{}</li>", html_escape::encode_text(row)))
                    .collect::<String>()
            )
        },
        highlighted_source(coverage)
    )
}

fn highlighted_source(coverage: &SourceFileCoverage) -> String {
    let mut states = vec![0_u8; coverage.raw_source.len()];
    for metric in &coverage.metrics {
        let state = if !metric.measurable {
            1
        } else if metric.is_uncovered() {
            4
        } else if metric.is_fully_covered() {
            2
        } else {
            3
        };
        let end = metric.span.end_offset.min(states.len());
        for byte in metric.span.start_offset.min(end)..end {
            states[byte] = states[byte].max(state);
        }
    }

    let mut output = String::new();
    let mut segment_start = 0;
    let mut current = states.first().copied().unwrap_or(0);
    for (offset, _) in coverage.raw_source.char_indices().skip(1) {
        let state = states.get(offset).copied().unwrap_or(0);
        if state != current {
            push_source_segment(
                &mut output,
                &coverage.raw_source[segment_start..offset],
                current,
            );
            segment_start = offset;
            current = state;
        }
    }
    push_source_segment(&mut output, &coverage.raw_source[segment_start..], current);
    output
}

fn push_source_segment(output: &mut String, source: &str, state: u8) {
    let escaped = html_escape::encode_text(source);
    let class = match state {
        1 => "unsupported",
        2 => "covered",
        3 => "partial",
        4 => "uncovered",
        _ => {
            output.push_str(&escaped);
            return;
        }
    };
    output.push_str(&format!("<mark class=\"{class}\">{escaped}</mark>"));
}
