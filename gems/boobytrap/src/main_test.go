package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "update golden files")

func ptr(v int) *int {
	return &v
}

func TestRelpath(t *testing.T) {
	tests := []struct {
		abs  string
		root string
		want string
	}{
		{"/a/b/c", "/a/b", "c"},
		{"/a/b", "/a/b", ""},
		{"/x/y", "/a/b", "../../x/y"}, // non-relative fallback
		{"c", "/a/b", "c"},            // relative vs absolute error case
	}
	for _, tc := range tests {
		got := relpath(tc.abs, tc.root)
		if got != tc.want {
			t.Errorf("relpath(%q, %q) = %q; want %q", tc.abs, tc.root, got, tc.want)
		}
	}
}

func TestMergeLines(t *testing.T) {
	v1 := 1
	v2 := 2
	target := []*int{nil, &v1, &v2}
	source := []interface{}{1.0, nil, 3.0, 4.0}

	res := mergeLines(target, source)
	if len(res) != 4 {
		t.Fatalf("expected length 4, got %d", len(res))
	}
	if res[0] == nil || *res[0] != 1 {
		t.Errorf("res[0] = %v; want 1", res[0])
	}
	if res[1] == nil || *res[1] != 1 {
		t.Errorf("res[1] = %v; want 1", res[1])
	}
	if res[2] == nil || *res[2] != 5 {
		t.Errorf("res[2] = %v; want 5", res[2])
	}
	if res[3] == nil || *res[3] != 4 {
		t.Errorf("res[3] = %v; want 4", res[3])
	}
}

func TestMergeBranches(t *testing.T) {
	target := map[string]map[string]int{
		"cond1": {"then": 1, "else": 0},
	}
	source := map[string]interface{}{
		"cond1": map[string]interface{}{
			"then": 2.0,
			"else": 1.0,
		},
		"cond2": map[string]interface{}{
			"then": 1.0,
		},
		"invalid": "string", // should be skipped gracefully
	}

	res := mergeBranches(target, source)
	if res["cond1"]["then"] != 3 {
		t.Errorf("cond1.then = %d; want 3", res["cond1"]["then"])
	}
	if res["cond1"]["else"] != 1 {
		t.Errorf("cond1.else = %d; want 1", res["cond1"]["else"])
	}
	if res["cond2"]["then"] != 1 {
		t.Errorf("cond2.then = %d; want 1", res["cond2"]["then"])
	}
}

func TestComputeBugspots(t *testing.T) {
	// Empty case
	s, b := computeBugspots(nil)
	if len(s) != 0 || len(b) != 0 {
		t.Errorf("empty computeBugspots returned non-empty: %v, %v", s, b)
	}

	// Single event (span = 0)
	events := []Event{
		{Time: 1000, Subject: "fix bug", Files: []string{"a.go", "b.go"}},
	}
	s, b = computeBugspots(events)
	if math.Abs(s["a.go"]-0.5) > 1e-9 {
		t.Errorf("single event score: %f; want 0.5", s["a.go"])
	}
	if len(b) != 2 {
		t.Fatalf("expected 2 blast rows, got %d", len(b))
	}
	// Verify sorting and roundings
	if b[0].File != "a.go" && b[0].File != "b.go" {
		t.Errorf("blast file incorrect: %v", b[0])
	}

	// Multiple events
	events = []Event{
		{Time: 1000, Subject: "fix 1", Files: []string{"a.go"}},
		{Time: 2000, Subject: "fix 2", Files: []string{"a.go", "b.go"}},
	}
	s, b = computeBugspots(events)
	if s["a.go"] <= s["b.go"] {
		t.Errorf("expected score of a.go > b.go, got %f vs %f", s["a.go"], s["b.go"])
	}
}

func TestGetGitEventsAndCoverage(t *testing.T) {
	// 1. Setup temp Git repo
	dir := t.TempDir()
	runCmd(t, dir, "git", "init", "-q")
	runCmd(t, dir, "git", "config", "user.email", "test@test.com")
	runCmd(t, dir, "git", "config", "user.name", "test")

	// Commit 1: non-fix
	writeTempFile(t, dir, "a.go", "package main\n")
	runCmd(t, dir, "git", "add", "a.go")
	runCmd(t, dir, "git", "commit", "-qm", "Initial commit")

	// Commit 2: fix
	writeTempFile(t, dir, "a.go", "package main\n// fix comment\n")
	runCmd(t, dir, "git", "add", "a.go")
	runCmd(t, dir, "git", "commit", "-qm", "Fix issue #123")

	fixRe := regexp.MustCompile(`(?i)\b(fix)\b`)
	events, err := getGitEvents(dir, fixRe)
	if err != nil {
		t.Fatalf("getGitEvents failed: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("expected 1 fix event, got %d", len(events))
	}
	if events[0].Files[0] != "a.go" {
		t.Errorf("expected file a.go, got %q", events[0].Files[0])
	}

	// 2. Setup mock SimpleCov coverage json
	covData := map[string]interface{}{
		"RSpec": map[string]interface{}{
			"coverage": map[string]interface{}{
				filepath.Join(dir, "a.go"): map[string]interface{}{
					"lines": []interface{}{1.0, nil, 0.0},
					"branches": map[string]interface{}{
						"[:if,0,1,0,1,9]": map[string]interface{}{
							"[:then,1,1,0,1,4]": 0.0,
							"[:else,2,1,5,1,9]": 1.0,
						},
					},
				},
				"non_existent.go": map[string]interface{}{
					"lines": []interface{}{1.0},
				},
				"invalid_entry": "not a map",
			},
		},
		"invalid_entry": "not a map",
	}
	covBytes, _ := json.Marshal(covData)
	covFile := filepath.Join(dir, "coverage.json")
	if err := os.WriteFile(covFile, covBytes, 0644); err != nil {
		t.Fatalf("failed to write coverage json: %v", err)
	}

	dataset, gaps, err := processCoverage(covFile, dir)
	if err != nil {
		t.Fatalf("processCoverage failed: %v", err)
	}
	if len(dataset.Files) != 2 {
		t.Errorf("expected 2 coverage files, got %d", len(dataset.Files))
	}
	gap, ok := gaps["a.go"]
	if !ok {
		t.Errorf("expected gap for a.go")
	}
	if gap.Total != 2 || gap.Uncovered != 1 || gap.Gap != 0.5 {
		t.Errorf("unexpected gap info: %+v", gap)
	}
}

func TestGetGitEventsErrors(t *testing.T) {
	_, err := getGitEvents("/non-existent-directory", regexp.MustCompile("fix"))
	if err == nil {
		t.Errorf("expected error for non-existent repo")
	}
}

func TestProcessCoverageErrors(t *testing.T) {
	_, _, err := processCoverage("/non-existent-file", "/repo")
	if err == nil {
		t.Errorf("expected error for non-existent file")
	}

	// Invalid json file
	dir := t.TempDir()
	f := filepath.Join(dir, "bad.json")
	os.WriteFile(f, []byte("{invalid"), 0644)
	_, _, err = processCoverage(f, dir)
	if err == nil {
		t.Errorf("expected error for invalid json")
	}
}

func TestProcessCoverageMultiple(t *testing.T) {
	dir := t.TempDir()
	f1 := filepath.Join(dir, "cov1.json")
	f2 := filepath.Join(dir, "cov2.json")

	covData1 := map[string]interface{}{
		"RSpec": map[string]interface{}{
			"coverage": map[string]interface{}{
				filepath.Join(dir, "a.go"): map[string]interface{}{
					"lines": []interface{}{1.0, nil, 0.0},
					"branches": map[string]interface{}{
						"[:if,0,3,1,3,9]": map[string]interface{}{
							"[:then,1,3,1,3,4]": 0.0,
						},
					},
				},
			},
		},
	}
	covBytes1, _ := json.Marshal(covData1)
	os.WriteFile(f1, covBytes1, 0644)

	covData2 := map[string]interface{}{
		"RSpec": map[string]interface{}{
			"coverage": map[string]interface{}{
				filepath.Join(dir, "a.go"): map[string]interface{}{
					"lines": []interface{}{nil, 2.0, 1.0},
					"branches": map[string]interface{}{
						"[:if,0,3,1,3,9]": map[string]interface{}{
							"[:then,1,3,1,3,4]": 1.0,
							"[:else,2,3,5,3,9]": 0.0,
						},
					},
				},
			},
		},
	}
	covBytes2, _ := json.Marshal(covData2)
	os.WriteFile(f2, covBytes2, 0644)

	covList := f1 + string(filepath.ListSeparator) + f2
	dataset, gaps, err := processCoverage(covList, dir)
	if err != nil {
		t.Fatalf("failed to process multiple coverage files: %v", err)
	}

	fc, ok := dataset.Files[filepath.Join(dir, "a.go")]
	if !ok {
		t.Fatalf("expected file coverage for a.go")
	}

	if len(fc.Lines) != 3 || *fc.Lines[0] != 1 || *fc.Lines[1] != 2 || *fc.Lines[2] != 1 {
		t.Errorf("line coverage mismatch: %+v", fc.Lines)
	}

	if fc.Branches["[:if,0,3,1,3,9]"]["[:then,1,3,1,3,4]"] != 1 {
		t.Errorf("branch then mismatch: %v", fc.Branches)
	}
	if fc.Branches["[:if,0,3,1,3,9]"]["[:else,2,3,5,3,9]"] != 0 {
		t.Errorf("branch else mismatch: %v", fc.Branches)
	}

	gap, ok := gaps["a.go"]
	if !ok || gap.Total != 2 || gap.Uncovered != 1 {
		t.Errorf("gap mismatch: %+v", gap)
	}
}

func TestProcessCoverageXML(t *testing.T) {
	dir := t.TempDir()
	xmlFile := filepath.Join(dir, "cobertura.xml")

	xmlContent := `<?xml version="1.0" ?>
<coverage>
  <sources>
    <source>src</source>
  </sources>
  <packages>
    <package name="main">
      <classes>
        <class filename="a.go" name="main">
          <lines>
            <line hits="1" number="1" />
            <line hits="0" number="2" />
            <line hits="5" number="3" />
          </lines>
        </class>
      </classes>
    </package>
  </packages>
</coverage>`
	os.WriteFile(xmlFile, []byte(xmlContent), 0644)

	os.MkdirAll(filepath.Join(dir, "src"), 0755)
	os.WriteFile(filepath.Join(dir, "src", "a.go"), []byte("package main\n"), 0644)

	dataset, _, err := processCoverage(xmlFile, dir)
	if err != nil {
		t.Fatalf("failed to process xml coverage: %v", err)
	}

	fc, ok := dataset.Files[filepath.Clean(filepath.Join(dir, "src", "a.go"))]
	if !ok {
		t.Fatalf("expected file coverage for src/a.go")
	}

	if len(fc.Lines) != 3 || *fc.Lines[0] != 1 || *fc.Lines[1] != 0 || *fc.Lines[2] != 5 {
		t.Errorf("line coverage mismatch: %+v", fc.Lines)
	}
}

func TestProcessCoverageNilKillJsonlMergesRuntimeLines(t *testing.T) {
	dir := t.TempDir()
	writeTempFile(t, dir, "src/demo.rb", "def call\n  maybe\nend\n")
	covFile := filepath.Join(dir, "runtime.jsonl")
	body := strings.Join([]string{
		`{"path":"src/demo.rb","lines":[1,3]}`,
		`{"path":"src/demo.rb","lines":{"2":0,"3":2,"bogus":7}}`,
		`{"path":"","lines":[10]}`,
		"",
	}, "\n")
	if err := os.WriteFile(covFile, []byte(body), 0644); err != nil {
		t.Fatalf("failed to write nil-kill jsonl: %v", err)
	}

	dataset, gaps, err := processCoverage(covFile, dir)
	if err != nil {
		t.Fatalf("processCoverage failed for nil-kill jsonl: %v", err)
	}
	fc := mustCoverageFile(t, dataset, filepath.Join(dir, "src/demo.rb"))
	assertLineHits(t, fc.Lines, []int{1, 0, 3})
	if fc.Format != "nil_kill_jsonl" {
		t.Fatalf("format = %q; want nil_kill_jsonl", fc.Format)
	}
	if fc.Language != "ruby" {
		t.Fatalf("language = %q; want ruby", fc.Language)
	}
	if len(gaps) != 0 {
		t.Fatalf("jsonl line coverage should not synthesize branch gaps: %+v", gaps)
	}
}

func TestProcessCoverageNilKillBranchCoverageNormalizesPathsAndArms(t *testing.T) {
	dir := t.TempDir()
	writeTempFile(t, dir, "src/alpha.rb", "if value\n  one\nelse\n  two\nend\n")
	covFile := filepath.Join(dir, "branch.json")
	body := `{
		"format": "nil-kill.branch-coverage",
		"root": "src",
		"files": [
			{
				"path": "alpha.rb",
				"lines": {"1": 1, "3": 0},
				"arms": [
					{
						"branch_id": "b1",
						"arm_id": "then",
						"kind": "if",
						"label": "then",
						"decision_span": [1, 1, 5, 4],
						"arm_span": [2, 3, 2, 5],
						"hits": 4
					},
					{
						"branch_id": "b1",
						"arm_id": "else",
						"arm": "else",
						"decision_span": [1, 1, 5, 4],
						"span": [4, 3, 4, 5],
						"count": 0
					},
					{
						"branch_id": "bad",
						"arm_id": "skip",
						"decision_span": [1, 1],
						"arm_span": [4, 3, 4, 5],
						"sample_count": 9
					}
				]
			},
			{"filename": "", "lines": [99]}
		]
	}`
	if err := os.WriteFile(covFile, []byte(body), 0644); err != nil {
		t.Fatalf("failed to write nil-kill branch coverage: %v", err)
	}

	dataset, gaps, err := processCoverage(covFile, dir)
	if err != nil {
		t.Fatalf("processCoverage failed for nil-kill branch coverage: %v", err)
	}
	fc := mustCoverageFile(t, dataset, filepath.Join(dir, "src/alpha.rb"))
	assertLineHits(t, fc.Lines, []int{1, -1, 0})
	if fc.Format != "nil_kill_branch" {
		t.Fatalf("format = %q; want nil_kill_branch", fc.Format)
	}
	if fc.Language != "ruby" {
		t.Fatalf("language = %q; want ruby", fc.Language)
	}
	if len(fc.BranchArms) != 2 {
		t.Fatalf("branch arms = %+v; want 2 valid arms", fc.BranchArms)
	}
	if fc.BranchArms[0].Kind != "if" || fc.BranchArms[0].Member != "then" || fc.BranchArms[0].Hits != 4 {
		t.Fatalf("then arm mismatch: %+v", fc.BranchArms[0])
	}
	if fc.BranchArms[1].Kind != "branch" || fc.BranchArms[1].Member != "else" || fc.BranchArms[1].Hits != 0 {
		t.Fatalf("else arm mismatch: %+v", fc.BranchArms[1])
	}
	gap, ok := gaps["src/alpha.rb"]
	if !ok {
		t.Fatalf("missing branch gap for src/alpha.rb: %+v", gaps)
	}
	if gap.Total != 2 || gap.Uncovered != 1 || gap.Gap != 0.5 {
		t.Fatalf("gap = %+v; want one miss out of two", gap)
	}
}

func TestProcessCoverageKcovCodecovMergesHits(t *testing.T) {
	dir := t.TempDir()
	writeTempFile(t, dir, "src/covered.zig", "pub fn main() void {}\n")
	covFile := filepath.Join(dir, "codecov.json")
	body := `{
		"coverage": {
			"src/covered.zig": {"1": 2, "2": 0, "bad": 9},
			"/does/not/exist.zig": {"1": 1}
		}
	}`
	if err := os.WriteFile(covFile, []byte(body), 0644); err != nil {
		t.Fatalf("failed to write kcov codecov JSON: %v", err)
	}

	dataset, _, err := processCoverage(covFile, dir)
	if err != nil {
		t.Fatalf("processCoverage failed for kcov codecov JSON: %v", err)
	}
	fc := mustCoverageFile(t, dataset, filepath.Join(dir, "src/covered.zig"))
	assertLineHits(t, fc.Lines, []int{2, 0})
	if fc.Format != "kcov_codecov" {
		t.Fatalf("format = %q; want kcov_codecov", fc.Format)
	}
	if fc.Language != "zig" {
		t.Fatalf("language = %q; want zig", fc.Language)
	}
}

func TestProcessCoveragePythonCoverageJsonMapsArcsThroughSyntaxFacts(t *testing.T) {
	dir := t.TempDir()
	writeTempFile(t, dir, "pkg/sample.py", "if ready:\n    one()\nelse:\n    two()\n")
	decomplex := filepath.Join(dir, "fake-decomplex")
	script := `#!/bin/sh
cat <<'JSON'
{"documents":[{"branch_arms":[
{"branch_id":"if:1","arm_id":"then","kind":"if","member":"then","decision_line":1,"decision_span":[1,1,4,8],"line":2,"span":[2,1,2,12]},
{"branch_id":"if:1","arm_id":"else","kind":"if","member":"else","decision_line":1,"decision_span":[1,1,4,8],"line":4,"span":[4,1,4,12]},
{"branch_id":"if:2","arm_id":"unrelated","kind":"if","member":"then","decision_line":9,"decision_span":[9,1,10,8],"line":10,"span":[10,1,10,12]}
]}]}
JSON
`
	if err := os.WriteFile(decomplex, []byte(script), 0755); err != nil {
		t.Fatalf("failed to write fake decomplex: %v", err)
	}
	t.Setenv("DECOMPLEX_RUST_BINARY", decomplex)

	covFile := filepath.Join(dir, "coverage-py.json")
	body := `{
		"files": {
			"pkg/sample.py": {
				"executed_lines": [1, 2, 0],
				"missing_lines": [3, 4, -1],
				"executed_branches": [[1, 2], [0, 9], [1]],
				"missing_branches": [[1, 4]]
			},
			"pkg/missing.py": {
				"executed_lines": [1],
				"missing_lines": [],
				"executed_branches": [],
				"missing_branches": []
			}
		}
	}`
	if err := os.WriteFile(covFile, []byte(body), 0644); err != nil {
		t.Fatalf("failed to write coverage.py JSON: %v", err)
	}

	dataset, gaps, err := processCoverage(covFile, dir)
	if err != nil {
		t.Fatalf("processCoverage failed for coverage.py JSON: %v", err)
	}
	fc := mustCoverageFile(t, dataset, filepath.Join(dir, "pkg/sample.py"))
	assertLineHits(t, fc.Lines, []int{1, 1, 0, 0})
	if fc.Format != "coverage_py" {
		t.Fatalf("format = %q; want coverage_py", fc.Format)
	}
	if len(fc.BranchArms) != 2 {
		t.Fatalf("branch arms = %+v; want mapped then/else arms", fc.BranchArms)
	}
	if fc.BranchArms[0].ArmID != "then" || fc.BranchArms[0].Hits != 1 {
		t.Fatalf("then arm mismatch: %+v", fc.BranchArms[0])
	}
	if fc.BranchArms[1].ArmID != "else" || fc.BranchArms[1].Hits != 0 {
		t.Fatalf("else arm mismatch: %+v", fc.BranchArms[1])
	}
	gap := gaps["pkg/sample.py"]
	if gap.Total != 2 || gap.Uncovered != 1 || gap.Gap != 0.5 {
		t.Fatalf("gap = %+v; want one missing Python branch arm", gap)
	}
	if _, ok := dataset.Files[filepath.Join(dir, "pkg/missing.py")]; ok {
		t.Fatalf("coverage for non-existent Python source should be ignored")
	}
}

func TestCoverageParsersRejectMalformedInputsAndSkipInvalidShapes(t *testing.T) {
	dir := t.TempDir()
	if err := parseNilKillJsonl([]byte("{not-json}\n"), dir, map[string]FileCoverage{}); err == nil {
		t.Fatalf("malformed nil-kill jsonl should fail")
	}
	if err := parseKcovCodecov([]byte("{not-json}"), dir, map[string]FileCoverage{}); err == nil {
		t.Fatalf("malformed kcov codecov JSON should fail")
	}
	if err := parseNilKillBranchCoverage([]byte("{not-json}"), dir, map[string]FileCoverage{}); err == nil {
		t.Fatalf("malformed nil-kill branch coverage should fail")
	}
	if err := parsePythonCoverageJson([]byte("{not-json}"), dir, map[string]FileCoverage{}); err == nil {
		t.Fatalf("malformed coverage.py JSON should fail")
	}

	badXML := filepath.Join(dir, "bad.xml")
	if err := os.WriteFile(badXML, []byte("<coverage>"), 0644); err != nil {
		t.Fatalf("failed to write bad xml: %v", err)
	}
	if _, _, err := processCoverage(badXML, dir); err == nil {
		t.Fatalf("malformed cobertura XML should fail")
	}

	xmlFile := filepath.Join(dir, "fallback.xml")
	xmlContent := `<?xml version="1.0" ?>
<coverage>
  <packages>
    <package name="main">
      <classes>
        <class filename="" name="skip">
          <lines><line hits="1" number="1" /></lines>
        </class>
        <class filename="ghost.py" name="ghost">
          <lines>
            <line hits="9" number="0" />
            <line hits="2" number="2" />
            <line hits="3" number="2" />
          </lines>
        </class>
      </classes>
    </package>
  </packages>
</coverage>`
	if err := os.WriteFile(xmlFile, []byte(xmlContent), 0644); err != nil {
		t.Fatalf("failed to write fallback xml: %v", err)
	}
	dataset, _, err := processCoverage(string(filepath.ListSeparator)+xmlFile, dir)
	if err != nil {
		t.Fatalf("fallback XML coverage failed: %v", err)
	}
	fc := mustCoverageFile(t, dataset, filepath.Join(dir, "ghost.py"))
	assertLineHits(t, fc.Lines, []int{-1, 5})
	if fc.SourcePath != "ghost.py" || fc.Language != "python" {
		t.Fatalf("fallback XML metadata mismatch: %+v", fc)
	}

	writeTempFile(t, dir, "simple.rb", "def call\nend\n")
	simpleCov := filepath.Join(dir, "simplecov.json")
	body := `{
		"bad-entry": "skip",
		"missing-coverage": {},
		"bad-coverage": {"coverage": "skip"},
		"RSpec": {
			"coverage": {
				"bad-file": "skip",
				"simple.rb": {
					"lines": [1, null],
					"branches": {"bad": "skip"}
				}
			}
		}
	}`
	if err := os.WriteFile(simpleCov, []byte(body), 0644); err != nil {
		t.Fatalf("failed to write simplecov JSON: %v", err)
	}
	dataset, _, err = processCoverage(simpleCov, dir)
	if err != nil {
		t.Fatalf("simplecov edge coverage failed: %v", err)
	}
	fc = mustCoverageFile(t, dataset, filepath.Join(dir, "simple.rb"))
	assertLineHits(t, fc.Lines, []int{1, -1})
	if fc.Format != "simplecov" || fc.Language != "ruby" {
		t.Fatalf("simplecov metadata mismatch: %+v", fc)
	}

	merged := mergeBranches(nil, map[string]interface{}{
		"branch": map[string]interface{}{"arm": 2.0, "bad": "skip"},
		"skip":   "not arms",
	})
	if merged["branch"]["arm"] != 2 {
		t.Fatalf("mergeBranches nil target mismatch: %+v", merged)
	}
}

func TestCoverageFormatDetectorsAndLanguageHelpers(t *testing.T) {
	for _, tc := range []struct {
		path string
		want string
	}{
		{"app.rb", "ruby"},
		{"script.PY", "python"},
		{"view.jsx", "javascript"},
		{"worker.cjs", "javascript"},
		{"types.tsx", "typescript"},
		{"main.go", "go"},
		{"lib.rs", "rust"},
		{"kernel.zig", "zig"},
		{"api.h", "c"},
		{"api.hxx", "cpp"},
		{"Program.cs", "csharp"},
		{"Thing.java", "java"},
		{"build.kts", "kotlin"},
		{"ios.swift", "swift"},
		{"index.php", "php"},
		{"mod.lua", "lua"},
		{"README", ""},
	} {
		if got := detectLanguage(tc.path); got != tc.want {
			t.Fatalf("detectLanguage(%q) = %q; want %q", tc.path, got, tc.want)
		}
	}

	for _, tc := range []struct {
		file string
		want string
	}{
		{"main.rb", "ruby"},
		{"tool.py", "python"},
		{"app.js", "javascript"},
		{"types.ts", "typescript"},
		{"main.go", "go"},
		{"lib.rs", "rust"},
		{"mod.zig", "zig"},
		{"core.c", "c"},
		{"core.cpp", "cpp"},
		{"Program.cs", "csharp"},
		{"build.kt", "kotlin"},
		{"README", "generic"},
	} {
		if got := languageFor(tc.file); got != tc.want {
			t.Fatalf("languageFor(%q) = %q; want %q", tc.file, got, tc.want)
		}
	}

	pythonCoverage := map[string]interface{}{
		"files": map[string]interface{}{
			"sample.py": map[string]interface{}{"missing_branches": []interface{}{}},
		},
	}
	if !isPythonCoverageJson(pythonCoverage) {
		t.Fatalf("coverage.py shape was not detected")
	}
	for _, raw := range []map[string]interface{}{
		{},
		{"files": "not a map"},
		{"files": map[string]interface{}{"sample.py": "not a file entry"}},
		{"files": map[string]interface{}{"sample.py": map[string]interface{}{"summary": 1}}},
	} {
		if isPythonCoverageJson(raw) {
			t.Fatalf("non coverage.py shape detected as coverage.py: %+v", raw)
		}
	}
}

func TestMainFunction(t *testing.T) {
	dir := t.TempDir()
	runCmd(t, dir, "git", "init", "-q")
	runCmd(t, dir, "git", "config", "user.email", "test@test.com")
	runCmd(t, dir, "git", "config", "user.name", "test")
	writeTempFile(t, dir, "a.go", "package main\n")
	runCmd(t, dir, "git", "add", "a.go")
	runCmd(t, dir, "git", "commit", "-qm", "Fix issue")

	covData := map[string]interface{}{
		"RSpec": map[string]interface{}{
			"coverage": map[string]interface{}{
				filepath.Join(dir, "a.go"): map[string]interface{}{
					"lines": []interface{}{1.0},
				},
			},
		},
	}
	covBytes, _ := json.Marshal(covData)
	covFile := filepath.Join(dir, "coverage.json")
	if err := os.WriteFile(covFile, covBytes, 0644); err != nil {
		t.Fatalf("failed to write coverage json: %v", err)
	}

	oldArgs := os.Args
	defer func() { os.Args = oldArgs }()

	os.Args = []string{"cmd", "--repo", dir, "--coverage", covFile}
	flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ContinueOnError)

	main()
}

func TestMainFunctionExits(t *testing.T) {
	if os.Getenv("BE_CRASHER") == "1" {
		os.Args = []string{"cmd"}
		caseType := os.Getenv("CRASHER_CASE")
		if caseType == "invalid-regex" {
			os.Args = []string{"cmd", "--repo=.", "--fix-re=(?"}
		} else if caseType == "invalid-repo" {
			os.Args = []string{"cmd", "--repo=/non-existent-dir"}
		} else if caseType == "invalid-coverage" {
			os.Args = []string{"cmd", "--repo=.", "--coverage=/non-existent-file"}
		}
		flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
		main()
		return
	}

	cases := []string{"missing-repo", "invalid-regex", "invalid-repo", "invalid-coverage"}
	for _, c := range cases {
		cmd := exec.Command(os.Args[0], "-test.run=TestMainFunctionExits")
		cmd.Env = append(os.Environ(), "BE_CRASHER=1", "CRASHER_CASE="+c)
		err := cmd.Run()
		if e, ok := err.(*exec.ExitError); ok && !e.Success() {
			// Success: it exited with non-zero
		} else {
			t.Errorf("case %s: process ran with err %v, want exit status 1", c, err)
		}
	}
}

func TestMainFunctionParseCoverageOnlyAndHelp(t *testing.T) {
	if os.Getenv("BE_PARSE_COVERAGE_ONLY") == "1" {
		caseType := os.Getenv("PARSE_COVERAGE_CASE")
		switch caseType {
		case "success":
			os.Args = []string{
				"cmd",
				"--repo=" + os.Getenv("TEST_REPO"),
				"--coverage=" + os.Getenv("TEST_COVERAGE"),
				"--parse-coverage-only",
			}
		case "missing-coverage":
			os.Args = []string{
				"cmd",
				"--repo=" + os.Getenv("TEST_REPO"),
				"--parse-coverage-only",
			}
		case "invalid-coverage":
			os.Args = []string{
				"cmd",
				"--repo=" + os.Getenv("TEST_REPO"),
				"--coverage=" + filepath.Join(os.Getenv("TEST_REPO"), "missing.json"),
				"--parse-coverage-only",
			}
		case "help":
			os.Args = []string{"cmd", "--help"}
		}
		flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
		main()
		return
	}

	dir := t.TempDir()
	writeTempFile(t, dir, "a.go", "package main\n")
	covData := map[string]interface{}{
		"RSpec": map[string]interface{}{
			"coverage": map[string]interface{}{
				filepath.Join(dir, "a.go"): map[string]interface{}{
					"lines": []interface{}{1.0},
				},
			},
		},
	}
	covBytes, _ := json.Marshal(covData)
	covFile := filepath.Join(dir, "coverage.json")
	if err := os.WriteFile(covFile, covBytes, 0644); err != nil {
		t.Fatalf("failed to write coverage json: %v", err)
	}

	success := exec.Command(os.Args[0], "-test.run=TestMainFunctionParseCoverageOnlyAndHelp")
	success.Env = append(os.Environ(),
		"BE_PARSE_COVERAGE_ONLY=1",
		"PARSE_COVERAGE_CASE=success",
		"TEST_REPO="+dir,
		"TEST_COVERAGE="+covFile,
	)
	out, err := success.CombinedOutput()
	if err != nil {
		t.Fatalf("parse coverage only failed: %v, output: %s", err, string(out))
	}
	if !strings.Contains(string(out), `"source_path":"a.go"`) {
		t.Fatalf("parse coverage output did not include normalized source path: %s", string(out))
	}

	for _, caseType := range []string{"missing-coverage", "invalid-coverage"} {
		cmd := exec.Command(os.Args[0], "-test.run=TestMainFunctionParseCoverageOnlyAndHelp")
		cmd.Env = append(os.Environ(),
			"BE_PARSE_COVERAGE_ONLY=1",
			"PARSE_COVERAGE_CASE="+caseType,
			"TEST_REPO="+dir,
			"TEST_COVERAGE="+covFile,
		)
		err := cmd.Run()
		if e, ok := err.(*exec.ExitError); ok && !e.Success() {
			continue
		}
		t.Fatalf("case %s ran with err %v; want non-zero exit", caseType, err)
	}

	help := exec.Command(os.Args[0], "-test.run=TestMainFunctionParseCoverageOnlyAndHelp")
	help.Env = append(os.Environ(),
		"BE_PARSE_COVERAGE_ONLY=1",
		"PARSE_COVERAGE_CASE=help",
	)
	helpOut, err := help.CombinedOutput()
	if err != nil {
		t.Fatalf("help command failed: %v, output: %s", err, string(helpOut))
	}
	if !strings.Contains(string(helpOut), "Usage: boobytrap report [options]") {
		t.Fatalf("help output mismatch: %s", string(helpOut))
	}
}

func TestMainFunctionInputAndReportWriteErrorsExit(t *testing.T) {
	if os.Getenv("BE_INPUT_ERROR") == "1" {
		repo := os.Getenv("TEST_REPO")
		caseType := os.Getenv("INPUT_ERROR_CASE")
		switch caseType {
		case "invalid-decomplex":
			os.Args = []string{"cmd", "--repo=" + repo, "--decomplex-facts=" + filepath.Join(repo, "missing-decomplex.json")}
		case "invalid-mutation":
			os.Args = []string{"cmd", "--repo=" + repo, "--mutation=" + filepath.Join(repo, "missing-mutation.json")}
		case "invalid-test-exposure":
			os.Args = []string{"cmd", "--repo=" + repo, "--test-exposure=" + filepath.Join(repo, "missing-exposure.json")}
		case "invalid-static":
			os.Args = []string{"cmd", "--repo=" + repo, "--static-files-file=" + filepath.Join(repo, "missing-static.json")}
		case "report-source-scan-error":
			os.Args = []string{"cmd", "report", "--repo=" + repo, "--coverage=", "--output=" + filepath.Join(repo, "report.md")}
		case "report-output-error":
			os.Args = []string{"cmd", "report", "--repo=" + repo, "--coverage=", "--output=" + repo}
		case "report-json-error":
			os.Args = []string{"cmd", "report", "--repo=" + repo, "--coverage=", "--json=" + repo}
		}
		flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
		main()
		return
	}

	dir := t.TempDir()
	runCmd(t, dir, "git", "init", "-q")
	runCmd(t, dir, "git", "config", "user.email", "test@test.com")
	runCmd(t, dir, "git", "config", "user.name", "test")
	writeTempFile(t, dir, "a.go", "package main\nfunc a() int { return 1 }\n")
	runCmd(t, dir, "git", "add", "a.go")
	runCmd(t, dir, "git", "commit", "-qm", "Fix issue")

	for _, caseType := range []string{
		"invalid-decomplex",
		"invalid-mutation",
		"invalid-test-exposure",
		"invalid-static",
		"report-source-scan-error",
		"report-output-error",
		"report-json-error",
	} {
		cmd := exec.Command(os.Args[0], "-test.run=TestMainFunctionInputAndReportWriteErrorsExit")
		env := append(os.Environ(),
			"BE_INPUT_ERROR=1",
			"INPUT_ERROR_CASE="+caseType,
			"TEST_REPO="+dir,
		)
		if caseType == "report-source-scan-error" {
			env = append(env, "BUNDLE_GEMFILE="+filepath.Join(dir, "missing-Gemfile"))
		}
		cmd.Env = env
		err := cmd.Run()
		if e, ok := err.(*exec.ExitError); ok && !e.Success() {
			continue
		}
		t.Fatalf("case %s ran with err %v; want non-zero exit", caseType, err)
	}
}

func runCmd(t *testing.T, dir string, name string, args ...string) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	if err := cmd.Run(); err != nil {
		t.Fatalf("command failed: %s %v: %v", name, args, err)
	}
}

func writeTempFile(t *testing.T, dir, filename, content string) {
	path := filepath.Join(dir, filename)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatalf("failed to create temp file directory: %v", err)
	}
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}
}

func mustCoverageFile(t *testing.T, dataset *CoverageDataset, path string) FileCoverage {
	t.Helper()
	fc, ok := dataset.Files[filepath.Clean(path)]
	if !ok {
		t.Fatalf("missing coverage for %s; files=%v", path, dataset.Files)
	}
	return fc
}

func assertLineHits(t *testing.T, got []*int, want []int) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("line count = %d; want %d; got %+v", len(got), len(want), got)
	}
	for idx, expected := range want {
		if expected < 0 {
			if got[idx] != nil {
				t.Fatalf("line %d = %d; want nil", idx+1, *got[idx])
			}
			continue
		}
		if got[idx] == nil {
			t.Fatalf("line %d is nil; want %d", idx+1, expected)
		}
		if *got[idx] != expected {
			t.Fatalf("line %d = %d; want %d", idx+1, *got[idx], expected)
		}
	}
}

func TestParseHelperEdgeCases(t *testing.T) {
	if got := parseInt(nil); got != 0 {
		t.Fatalf("parseInt(nil) = %d; want 0", got)
	}
	if got := parseInt("7"); got != 0 {
		t.Fatalf("parseInt(non-number) = %d; want 0", got)
	}
	if got := parseInt(3.9); got != 3 {
		t.Fatalf("parseInt(float) = %d; want truncation to 3", got)
	}
	if got := parseIntList("not a list"); got != nil {
		t.Fatalf("parseIntList(non-list) = %+v; want nil", got)
	}
	if got := parseIntList([]interface{}{1.0, "skip", 3.0}); len(got) != 2 || got[0] != 1 || got[1] != 3 {
		t.Fatalf("parseIntList mixed values = %+v; want [1 3]", got)
	}
	if got := parseNilKillLines("bad"); got != nil {
		t.Fatalf("parseNilKillLines(non-shape) = %+v; want nil", got)
	}
	if lineInSpan(2, []int{1, 2}) {
		t.Fatalf("short span should not match")
	}
}

func TestFindDecomplexBinaryPrefersConfiguredAndLocalBuilds(t *testing.T) {
	dir := t.TempDir()
	t.Run("env", func(t *testing.T) {
		t.Setenv("DECOMPLEX_RUST_BINARY", filepath.Join(dir, "custom-decomplex"))
		if got := findDecomplexBinary(dir); got != filepath.Join(dir, "custom-decomplex") {
			t.Fatalf("env decomplex = %q", got)
		}
	})
	t.Run("release", func(t *testing.T) {
		t.Setenv("DECOMPLEX_RUST_BINARY", "")
		release := filepath.Join(dir, "release-root/gems/decomplex/target/release/decomplex-rust")
		writeTempFile(t, filepath.Join(dir, "release-root"), "gems/decomplex/target/release/decomplex-rust", "")
		if got := findDecomplexBinary(filepath.Join(dir, "release-root")); got != release {
			t.Fatalf("release decomplex = %q; want %q", got, release)
		}
	})
	t.Run("debug", func(t *testing.T) {
		t.Setenv("DECOMPLEX_RUST_BINARY", "")
		debugRoot := filepath.Join(dir, "debug-root")
		debug := filepath.Join(debugRoot, "gems/decomplex/target/debug/decomplex-rust")
		writeTempFile(t, debugRoot, "gems/decomplex/target/debug/decomplex-rust", "")
		if got := findDecomplexBinary(debugRoot); got != debug {
			t.Fatalf("debug decomplex = %q; want %q", got, debug)
		}
	})
	t.Run("fallback", func(t *testing.T) {
		t.Setenv("DECOMPLEX_RUST_BINARY", "")
		if got := findDecomplexBinary(filepath.Join(dir, "missing-root")); got != "decomplex-rust" {
			t.Fatalf("fallback decomplex = %q; want decomplex-rust", got)
		}
	})
}

func TestMutationPoliciesClassifyVerificationRisk(t *testing.T) {
	weakRate := 55.0
	moderateRate := 75.0
	strongRate := 95.0
	if !isMutationWeak(nil, "") || !isMutationWeak(&weakRate, "required") || !isMutationWeak(&strongRate, "advisory") {
		t.Fatalf("weak mutation policy did not classify nil, low rate, and advisory gate as weak")
	}
	if isMutationWeak(&moderateRate, "required") {
		t.Fatalf("moderate enforced mutation result should not be weak")
	}
	if !isMutationStrong(&strongRate, "hard-gated") || isMutationStrong(&moderateRate, "hard") || isMutationStrong(nil, "hard") {
		t.Fatalf("strong mutation policy did not require both high kill rate and enforced gate")
	}

	strong := &MutationFact{KillRate: &strongRate, GateStatus: "required"}
	moderate := &MutationFact{KillRate: &moderateRate, GateStatus: "required"}
	weak := &MutationFact{KillRate: &weakRate, GateStatus: "advisory"}
	if got := mutationRiskMultiplier(strong, true, 3, 0.1, 0.2); got != 0.75 {
		t.Fatalf("strong low-risk multiplier = %.2f; want 0.75", got)
	}
	if got := mutationRiskMultiplier(strong, true, 7, 0.8, 0.2); got != 0.9 {
		t.Fatalf("strong high-history multiplier = %.2f; want 0.90", got)
	}
	if got := mutationRiskMultiplier(moderate, true, 3, 0.1, 0.2); got != 1.1 {
		t.Fatalf("moderate multiplier = %.2f; want 1.10", got)
	}
	if got := mutationRiskMultiplier(weak, true, 7, 0.8, 0.9); got != 1.9 {
		t.Fatalf("weak high-risk multiplier = %.2f; want 1.90", got)
	}
	if got := mutationRiskMultiplier(weak, true, 7, 0.1, 0.1); got != 1.45 {
		t.Fatalf("weak high-complexity multiplier = %.2f; want 1.45", got)
	}
	if got := mutationRiskMultiplier(weak, true, 2, 0.1, 0.1); got != 1.25 {
		t.Fatalf("weak low-risk multiplier = %.2f; want 1.25", got)
	}
	if got := mutationRiskMultiplier(weak, false, 7, 0.8, 0.9); got != 1.0 {
		t.Fatalf("inactive mutation multiplier = %.2f; want 1.0", got)
	}

	for _, tc := range []struct {
		fact       *MutationFact
		complexity float64
		history    float64
		gap        float64
		want       string
	}{
		{weak, 7, 0.8, 0.9, "lurking disaster"},
		{strong, 7, 0.1, 0.1, "hardened veteran"},
		{weak, 3, 0.8, 0.1, "fragile newcomer"},
		{weak, 3, 0.1, 0.1, "weak verification"},
		{moderate, 3, 0.1, 0.1, "partial verification"},
		{strong, 3, 0.1, 0.1, "load-bearing tests"},
	} {
		if got := mutationProfile(tc.fact, true, tc.complexity, tc.history, tc.gap); got != tc.want {
			t.Fatalf("mutationProfile(%+v) = %q; want %q", tc.fact, got, tc.want)
		}
	}
	if got := mutationProfile(weak, false, 7, 0.8, 0.9); got != "" {
		t.Fatalf("inactive mutation profile = %q; want empty", got)
	}

	facts := map[MethodKey]MutationFact{
		{File: "src/a.rb", Method: "call"}:               {Method: "call"},
		{File: "src/b.rb", Method: "*"}:                  {Method: "*"},
		{File: "\x00global", Method: "shared"}:           {Method: "shared"},
		{File: "\x00global", Method: "Namespace::build"}: {Method: "Namespace::build"},
	}
	if got := lookupMutationFact(facts, "./src/a.rb", "Owner#call"); got == nil || got.Method != "call" {
		t.Fatalf("alias lookup failed: %+v", got)
	}
	if got := lookupMutationFact(facts, "src/b.rb", "missing"); got == nil || got.Method != "*" {
		t.Fatalf("file default lookup failed: %+v", got)
	}
	if got := lookupMutationFact(facts, "src/c.rb", "Owner.shared"); got == nil || got.Method != "shared" {
		t.Fatalf("global alias lookup failed: %+v", got)
	}
	if got := lookupMutationFact(facts, "src/c.rb", "absent"); got != nil {
		t.Fatalf("missing mutation fact = %+v; want nil", got)
	}
}

func TestTestExposurePoliciesAggregateNamedCoverage(t *testing.T) {
	payload := &TestExposurePayload{
		MethodHits: []MethodHitEntry{
			{File: "src/a.rb", Method: "call", Hit: Hit{TestID: "t1", TestType: "spec", MutationStatus: "killed", Line: 1}},
			{File: "src/other.rb", Method: "call", Hit: Hit{TestID: "skip", TestType: "spec", MutationStatus: "killed", Line: 1}},
		},
		LineHits: []LineHitEntry{
			{File: "src/a.rb", Line: 2, Hit: Hit{TestID: "t2", TestType: "unit", MutationStatus: "survived", Line: 2}},
			{File: "src/a.rb", Line: 9, Hit: Hit{TestID: "outside", TestType: "unit", MutationStatus: "survived", Line: 9}},
		},
		BranchHits: []BranchHitEntry{
			{File: "src/a.rb", BranchID: "if:1", Line: 3, Hit: Hit{TestID: "t3", TestType: "spec", MutationStatus: "unverified", Line: 3, BranchID: "if:1"}},
			{File: "src/a.rb", BranchID: "", Line: 4, Hit: Hit{TestID: "t4", TestType: "", MutationStatus: "failed", Line: 4}},
		},
	}
	agg := buildTestExposureAggregated(payload, "./src/a.rb", "Owner#call", 1, 5)
	if len(agg.FunctionTests) != 1 || len(agg.LineTests[2]) != 1 || len(agg.LineTests[9]) != 0 {
		t.Fatalf("aggregate method/line hits mismatch: %+v", agg)
	}
	if len(agg.BranchTests["if:1"]) != 1 || len(agg.BranchTests["line:4"]) != 1 {
		t.Fatalf("aggregate branch hits mismatch: %+v", agg.BranchTests)
	}
	if got := testExposureSummary(agg); got != "4 tests; spec=2/unit=1/unknown=1; mutant killed 1/3; lines=1; branches=2" {
		t.Fatalf("testExposureSummary = %q", got)
	}
	if got := testExposureMultiplier(agg, true, 1, 0, 0); got != 0.70 {
		t.Fatalf("killed exposure multiplier = %.2f; want 0.70", got)
	}
	if got := testExposureProfile(agg, true); got != "mutation-killed exposure" {
		t.Fatalf("killed exposure profile = %q", got)
	}

	empty := &TestExposureAggregated{LineTests: map[int][]TestExposureHit{}, BranchTests: map[string][]TestExposureHit{}}
	if got := testExposureSummary(empty); got != "no named tests" {
		t.Fatalf("empty summary = %q", got)
	}
	if got := testExposureMultiplier(empty, true, 6, 0, 0); got != 1.15 {
		t.Fatalf("empty high-risk multiplier = %.2f; want 1.15", got)
	}
	if got := testExposureMultiplier(empty, true, 1, 0, 0); got != 1.05 {
		t.Fatalf("empty low-risk multiplier = %.2f; want 1.05", got)
	}
	if got := testExposureMultiplier(empty, false, 6, 0, 0); got != 1.0 {
		t.Fatalf("inactive exposure multiplier = %.2f; want 1.0", got)
	}
	if got := testExposureProfile(empty, true); got != "unobserved by named tests" {
		t.Fatalf("empty profile = %q", got)
	}
	if got := testExposureProfile(empty, false); got != "" {
		t.Fatalf("inactive profile = %q; want empty", got)
	}

	diverse := &TestExposureAggregated{
		FunctionTests: []TestExposureHit{
			{TestID: "a", TestType: "spec"},
			{TestID: "b", TestType: "unit"},
			{TestID: "c", TestType: "integration"},
			{TestID: "d", TestType: "spec"},
			{TestID: "e", TestType: "unit"},
		},
		LineTests:   map[int][]TestExposureHit{},
		BranchTests: map[string][]TestExposureHit{},
	}
	if got := testExposureMultiplier(diverse, true, 1, 0, 0); got != 0.80 {
		t.Fatalf("diverse multiplier = %.2f; want 0.80", got)
	}
	if got := testExposureProfile(diverse, true); got != "diverse named coverage" {
		t.Fatalf("diverse profile = %q", got)
	}

	named := &TestExposureAggregated{
		FunctionTests: []TestExposureHit{{TestID: "a", TestType: "spec"}, {TestID: "b", TestType: "spec"}},
		LineTests:     map[int][]TestExposureHit{},
		BranchTests:   map[string][]TestExposureHit{},
	}
	if got := testExposureMultiplier(named, true, 1, 0, 0); got != 0.90 {
		t.Fatalf("named multiplier = %.2f; want 0.90", got)
	}
	if got := testExposureProfile(named, true); got != "named coverage" {
		t.Fatalf("named profile = %q", got)
	}

	thin := &TestExposureAggregated{
		FunctionTests: []TestExposureHit{{TestID: "a", TestType: "spec"}},
		LineTests:     map[int][]TestExposureHit{},
		BranchTests:   map[string][]TestExposureHit{},
	}
	if got := testExposureMultiplier(thin, true, 1, 0, 0); got != 0.98 {
		t.Fatalf("thin multiplier = %.2f; want 0.98", got)
	}
	if got := testExposureProfile(thin, true); got != "thin named coverage" {
		t.Fatalf("thin profile = %q", got)
	}
}

func TestLineageExposurePoliciesRewardFreshHardening(t *testing.T) {
	types := parseTestTypes("unit,spec,unit, integration ")
	if strings.Join(types, ",") != "integration,spec,unit" {
		t.Fatalf("parseTestTypes = %+v", types)
	}
	if got := lineageTestExposureStatus(LineageUnit{}); got != "" {
		t.Fatalf("lineage status without tests = %q; want empty", got)
	}
	stale := LineageUnit{CurrentDistinctTests: 2, CurrentTestTypes: "spec", CurrentMutantVerifiedTests: 1, CurrentMutantKilledTests: 0, FixesAfterTestExposure: 3}
	if got := lineageTestExposureStatus(stale); !strings.Contains(got, "ignored: 3 later fix(es)") {
		t.Fatalf("stale lineage status = %q", got)
	}
	hardened := LineageUnit{CurrentDistinctTests: 2, CurrentTestTypes: "spec,unit", CurrentMutantVerifiedTests: 2, CurrentMutantKilledTests: 1, LatestFixAt: 10, LastTestExposureAt: 12}
	if got := lineageTestExposureStatus(hardened); !strings.Contains(got, "hardened after latest fix") {
		t.Fatalf("hardened lineage status = %q", got)
	}

	for _, tc := range []struct {
		unit LineageUnit
		want string
	}{
		{LineageUnit{}, ""},
		{stale, "stale lineage exposure ignored"},
		{LineageUnit{CurrentDistinctTests: 1, CurrentMutantKilledTests: 1}, "mutation-killed exposure (lineage)"},
		{LineageUnit{CurrentDistinctTests: 2, CurrentTestTypes: "spec,unit"}, "diverse named coverage (lineage)"},
		{LineageUnit{CurrentDistinctTests: 2, CurrentTestTypes: "spec"}, "named coverage (lineage)"},
		{LineageUnit{CurrentDistinctTests: 1, CurrentTestTypes: "spec"}, "thin named coverage (lineage)"},
	} {
		if got := lineageExposureProfile(tc.unit); got != tc.want {
			t.Fatalf("lineageExposureProfile(%+v) = %q; want %q", tc.unit, got, tc.want)
		}
	}

	base := LineageUnit{CurrentDistinctTests: 1, LatestFixAt: 10, LastTestExposureAt: 11}
	if got := lineageExposureMultiplier(base, false, 10, 1, 1); got != 1.0 {
		t.Fatalf("inactive lineage multiplier = %.2f; want 1.0", got)
	}
	if got := lineageExposureMultiplier(LineageUnit{}, true, 10, 1, 1); got != 1.0 {
		t.Fatalf("lineage without tests multiplier = %.2f; want 1.0", got)
	}
	if got := lineageExposureMultiplier(stale, true, 10, 1, 1); got != 1.0 {
		t.Fatalf("stale lineage multiplier = %.2f; want 1.0", got)
	}
	notHardened := LineageUnit{CurrentDistinctTests: 2, LatestFixAt: 10, LastTestExposureAt: 9}
	if got := lineageExposureMultiplier(notHardened, true, 10, 1, 1); got != 1.0 {
		t.Fatalf("not-hardened lineage multiplier = %.2f; want 1.0", got)
	}
	for _, tc := range []struct {
		unit       LineageUnit
		complexity float64
		history    float64
		gap        float64
		want       float64
	}{
		{LineageUnit{CurrentDistinctTests: 3, CurrentMutantKilledTests: 3, LatestFixAt: 10, LastTestExposureAt: 12}, 1, 0, 0, 0.45},
		{LineageUnit{CurrentDistinctTests: 3, CurrentMutantKilledTests: 1, LatestFixAt: 10, LastTestExposureAt: 12}, 1, 0, 0, 0.60},
		{LineageUnit{CurrentDistinctTests: 5, CurrentTestTypes: "spec,unit", LatestFixAt: 10, LastTestExposureAt: 12}, 1, 0, 0, 0.75},
		{LineageUnit{CurrentDistinctTests: 2, CurrentTestTypes: "spec", LatestFixAt: 10, LastTestExposureAt: 12}, 1, 0, 0, 0.88},
		{LineageUnit{CurrentDistinctTests: 1, CurrentTestTypes: "spec", LatestFixAt: 10, LastTestExposureAt: 12}, 7, 0, 0, 0.97},
		{LineageUnit{CurrentDistinctTests: 1, CurrentTestTypes: "spec", LatestFixAt: 10, LastTestExposureAt: 12}, 1, 0, 0, 1.0},
	} {
		if got := lineageExposureMultiplier(tc.unit, true, tc.complexity, tc.history, tc.gap); got != tc.want {
			t.Fatalf("lineageExposureMultiplier(%+v) = %.2f; want %.2f", tc.unit, got, tc.want)
		}
	}
}

func TestReportFormattingPolicyHelpers(t *testing.T) {
	if got := scopeLabel(nil, nil); got != "whole repo" {
		t.Fatalf("whole repo scope = %q", got)
	}
	if got := scopeLabel([]string{"src", "lib"}, nil); got != "`src/`, `lib/`" {
		t.Fatalf("only scope = %q", got)
	}
	if got := scopeLabel(nil, []string{"a.go", "b.go"}); got != "`a.go`, `b.go`" {
		t.Fatalf("files scope = %q", got)
	}
	for _, tc := range []struct {
		hasCoverage bool
		label       string
		static      bool
		hasGaps     bool
		want        string
	}{
		{true, "coverage.xml", true, true, "coverage.xml + tree-sitter static fallback"},
		{false, "", true, true, "tree-sitter static fallback"},
		{true, "coverage.xml", false, true, "coverage.xml"},
		{false, "", false, false, "absent"},
		{false, "", false, true, "unknown"},
	} {
		if got := coverageMode(tc.hasCoverage, tc.label, tc.static, tc.hasGaps); got != tc.want {
			t.Fatalf("coverageMode(%+v) = %q; want %q", tc, got, tc.want)
		}
	}
	if got := testExposureLabel(false, "facts.json"); got != "not supplied" {
		t.Fatalf("inactive exposure label = %q", got)
	}
	if got := testExposureLabel(true, "facts.json"); got != "facts.json" {
		t.Fatalf("named exposure label = %q", got)
	}
	if got := testExposureLabel(true, ""); got != "active" {
		t.Fatalf("active exposure label = %q", got)
	}
	row := MethodGapRow{RiskProfile: "weak verification", TestExposureProfile: "weak verification"}
	if got := empiricalProfile(row); got != "weak verification" {
		t.Fatalf("deduplicated empirical profile = %q", got)
	}
	row.TestExposureProfile = "named coverage"
	if got := empiricalProfile(row); got != "weak verification; named coverage" {
		t.Fatalf("combined empirical profile = %q", got)
	}
	if got := empiricalProfile(MethodGapRow{}); got != "not supplied" {
		t.Fatalf("empty empirical profile = %q", got)
	}
	if got := lineageCell(MethodGapRow{}); got != "0" {
		t.Fatalf("empty lineage cell = %q", got)
	}
	lineage := MethodGapRow{LineageScore: 12.25, LineageFixes: 2, LineageChanges: 3, LineageMoves: 1}
	if got := lineageCell(lineage); got != "12.2 (f2/c3/m1)" {
		t.Fatalf("lineage cell = %q", got)
	}
	if got := formatFindings(nil); got != "[]" {
		t.Fatalf("empty findings = %q", got)
	}
	if got := formatFindings([]Finding{{Type: "state"}, {Type: "branch"}}); got != `[{"type"=>"state"}, {"type"=>"branch"}]` {
		t.Fatalf("findings = %q", got)
	}
	if got := coverageMode(false, "", false, false); got != "absent" {
		t.Fatalf("coverageMode absent = %q", got)
	}
	if got := formatFloat(2.0, 1); got != "2.0" {
		t.Fatalf("integer-ish formatFloat = %q", got)
	}
	if got := formatFloat(2.25, 1); got != "2.25" {
		t.Fatalf("fractional formatFloat = %q", got)
	}
}

func TestSourceRangeAndRankingHelpersHandleEdgeCases(t *testing.T) {
	ranges := fallbackFunctionRanges([]string{
		"noise",
		"function lonely",
		"def indented",
		"  call",
		"",
		"done",
	})
	if len(ranges) != 2 {
		t.Fatalf("fallback ranges = %+v; want lonely and indented", ranges)
	}
	if ranges[0].Name != "lonely" || ranges[0].FirstLine != 2 || ranges[0].LastLine != 2 {
		t.Fatalf("lonely range should collapse to declaration line: %+v", ranges[0])
	}
	if ranges[1].Name != "indented" || ranges[1].LastLine != 4 {
		t.Fatalf("indented range mismatch: %+v", ranges[1])
	}
	for _, line := range []string{"", "  # comment", "// comment", "/* comment", "* comment", "end", "}", "{", ")", "("} {
		if executableSourceLine(line) {
			t.Fatalf("line %q should not be executable", line)
		}
	}
	if !executableSourceLine("return value") {
		t.Fatalf("normal statement should be executable")
	}
	if got := stateWriteCount([]string{"@count += 1", "@user.name = 'x'", "config.value << 1", "local = 1"}); got != 3 {
		t.Fatalf("stateWriteCount = %d; want 3", got)
	}
	if aliases := methodAliases("Namespace::Owner.build"); strings.Join(aliases, ",") != "Namespace::Owner.build,build,Owner.build" {
		t.Fatalf("methodAliases = %+v", aliases)
	}
	if got := parseBranchArmLine("not-a-simplecov-arm"); got != 0 {
		t.Fatalf("invalid branch arm line = %d; want 0", got)
	}
	if !isHitSurvived(TestExposureHit{MutationStatus: "timedout"}) || isHitSurvived(TestExposureHit{MutationStatus: "killed"}) {
		t.Fatalf("survived mutation classifier mismatch")
	}

	ranked, unmeasured := rankHotspots(
		map[string]float64{"b.rb": 2.0, "a.rb": 2.0, "missing-high.rb": 3.0, "missing-low.rb": 1.0},
		map[string]FileGap{
			"b.rb": {Total: 4, Uncovered: 2, Gap: 0.5},
			"a.rb": {Total: 4, Uncovered: 2, Gap: 0.5},
		},
	)
	if len(ranked) != 2 || ranked[0].File != "a.rb" || ranked[1].File != "b.rb" {
		t.Fatalf("ranked hotspot tie sort mismatch: %+v", ranked)
	}
	if len(unmeasured) != 2 || unmeasured[0].File != "missing-high.rb" || unmeasured[1].File != "missing-low.rb" {
		t.Fatalf("unmeasured sort mismatch: %+v", unmeasured)
	}
}

func TestDecomplexAndMutationInputNormalizationEdges(t *testing.T) {
	dir := t.TempDir()
	writeTempFile(t, dir, "src/a.rb", "def call\nend\n")
	badDecomplex := filepath.Join(dir, "bad-decomplex.json")
	if err := os.WriteFile(badDecomplex, []byte("{not-json}"), 0644); err != nil {
		t.Fatalf("failed to write bad decomplex: %v", err)
	}
	if _, _, err := processDecomplexFacts(badDecomplex, dir); err == nil {
		t.Fatalf("malformed decomplex facts should fail")
	}
	decomplex := filepath.Join(dir, "decomplex.json")
	absSite := filepath.Join(dir, "src/a.rb") + ":call:12"
	body := fmt.Sprintf(`{
		"detectors": {
			"z_detector": {"nested": [{"sites": ["bad", %q, 7]}]},
			"a_detector": [{"sites": [%q]}],
			"state_branch_density": [
				"skip",
				{"file": %q, "method": "call", "score": 2.5, "decisions": 3, "state_refs": ["@x", 7], "predicate": "@x"}
			]
		}
	}`, absSite, absSite, filepath.Join(dir, "src/a.rb"))
	if err := os.WriteFile(decomplex, []byte(body), 0644); err != nil {
		t.Fatalf("failed to write decomplex facts: %v", err)
	}
	scores, density, err := processDecomplexFacts(decomplex, dir)
	if err != nil {
		t.Fatalf("processDecomplexFacts failed: %v", err)
	}
	if len(scores) != 1 || scores[0].File != "src/a.rb" || scores[0].Method != "call" || scores[0].Score != 2 {
		t.Fatalf("decomplex scores mismatch: %+v", scores)
	}
	if strings.Join(scores[0].Detectors, ",") != "a_detector,z_detector" || len(scores[0].Findings) != 2 {
		t.Fatalf("decomplex detector aggregation mismatch: %+v", scores[0])
	}
	if len(density) != 1 || density[0].File != "src/a.rb" || density[0].Decisions != 3 || len(density[0].StateRefs) != 1 {
		t.Fatalf("density rows mismatch: %+v", density)
	}

	if parseKillRate(nil) != nil || parseKillRate("not-a-rate") != nil {
		t.Fatalf("nil and malformed kill rates should normalize to nil")
	}
	if rate := parseKillRate(0.42); rate == nil || *rate != 42.0 {
		t.Fatalf("fractional kill rate = %v; want 42.0", rate)
	}
	if got := normalizeFile("", dir); got != "" {
		t.Fatalf("empty normalizeFile = %q; want empty", got)
	}
	if got := normalizeFile(filepath.Join(dir, "src/a.rb"), dir); got != "src/a.rb" {
		t.Fatalf("absolute normalizeFile = %q; want src/a.rb", got)
	}

	badMutation := filepath.Join(dir, "bad-mutation.json")
	if err := os.WriteFile(badMutation, []byte("{not-json}"), 0644); err != nil {
		t.Fatalf("failed to write bad mutation facts: %v", err)
	}
	if _, err := processMutationFacts(badMutation, dir); err == nil {
		t.Fatalf("malformed mutation facts should fail")
	}
	emptyMutation := filepath.Join(dir, "empty-mutation.json")
	if err := os.WriteFile(emptyMutation, []byte(`{"subjects":"not an array"}`), 0644); err != nil {
		t.Fatalf("failed to write empty mutation facts: %v", err)
	}
	out, err := processMutationFacts(emptyMutation, dir)
	if err != nil {
		t.Fatalf("empty mutation facts failed: %v", err)
	}
	if !out.Active || len(out.Subjects) != 0 {
		t.Fatalf("empty mutation facts mismatch: %+v", out)
	}
}

func TestLoadLineageHandlesAbsentInvalidAndCommandBackedIndexes(t *testing.T) {
	dir := t.TempDir()
	if got := loadLineage("", dir, nil, 10, ""); got.Status != "absent" {
		t.Fatalf("empty lineage db status = %+v", got)
	}
	if got := loadLineage(filepath.Join(dir, "missing.sqlite3"), dir, nil, 10, ""); got.Status != "absent" {
		t.Fatalf("missing lineage db status = %+v", got)
	}
	db := filepath.Join(dir, "lineage.sqlite3")
	if err := os.WriteFile(db, []byte("not actually sqlite"), 0644); err != nil {
		t.Fatalf("failed to write db marker: %v", err)
	}
	badJSON := filepath.Join(dir, "bad-lineage")
	writeTempFile(t, dir, "bad-lineage", "#!/bin/sh\necho not-json\n")
	if err := os.Chmod(badJSON, 0755); err != nil {
		t.Fatalf("chmod bad lineage: %v", err)
	}
	if got := loadLineage(db, dir, []string{"src"}, 5, badJSON); got.Status != "absent" {
		t.Fatalf("invalid lineage JSON status = %+v", got)
	}
	writeTempFile(t, dir, "src/a.rb", "def call\nend\n")
	good := filepath.Join(dir, "good-lineage")
	writeTempFile(t, dir, "good-lineage", `#!/bin/sh
echo '[{"current_path":"src/a.rb","name":"call","risk_score":0,"fixes":1,"changes":2,"moves":0,"current_distinct_tests":1}]'
`)
	if err := os.Chmod(good, 0755); err != nil {
		t.Fatalf("chmod good lineage: %v", err)
	}
	index := loadLineage(db, dir, []string{"src"}, 5, good)
	if index.Status != "ok" || !index.HasTestExposure || index.Label != "lineage.sqlite3" {
		t.Fatalf("lineage index metadata mismatch: %+v", index)
	}
	if len(index.Units) != 1 || index.Index[MethodKey{File: "src/a.rb", Method: "call"}].Name != "call" {
		t.Fatalf("lineage units/index mismatch: %+v", index)
	}
}

func TestReportRenderingCoversAllRiskSectionsAndLimits(t *testing.T) {
	ranked := []HotspotRow{
		{File: "src/high.rb", FixNorm: 1, Gap: 0.9, Hotspot: 0.9, TotalBranches: 10, Uncovered: 9},
		{File: "src/low.rb", FixNorm: 0.5, Gap: 0.8, Hotspot: 0.4, TotalBranches: 5, Uncovered: 4},
	}
	unmeasured := []UnmeasuredEntry{
		{File: "src/missing.rb", FixNorm: 0.75},
		{File: "src/other_missing.rb", FixNorm: 0.25},
	}
	methods := []MethodGapRow{
		{
			File:                "src/high.rb",
			Name:                "danger",
			FirstLine:           10,
			LastLine:            20,
			ExecutableLines:     10,
			CoveredLines:        0,
			MissedLines:         10,
			LineGap:             1.0,
			Risk:                12.5,
			FixNorm:             1.0,
			DecomplexScore:      2,
			StateWrites:         1,
			UncoveredBranches:   2,
			TestExposureStatus:  "",
			TestExposureProfile: "named coverage",
			VerificationStatus:  "",
			DecomplexFindings:   []Finding{{Type: "state_branch_density"}},
			LineageScore:        4.2,
			LineageFixes:        1,
			LineageChanges:      2,
			LineageMoves:        0,
		},
		{
			File:              "src/aaa.rb",
			Name:              "tie",
			FirstLine:         5,
			LastLine:          8,
			ExecutableLines:   5,
			CoveredLines:      1,
			MissedLines:       4,
			LineGap:           0.8,
			Risk:              12.5,
			FixNorm:           0.5,
			DecomplexScore:    1,
			StateWrites:       0,
			UncoveredBranches: 0,
		},
	}
	stateRows := []StateBranchHotspotRow{
		{File: "src/high.rb", Method: "danger", Risk: 7.5, Decisions: 4, At: "src/high.rb:11", StateRefs: []string{"@a", "@b", "@c", "@d", "@e", "@f"}, FixNorm: 1, BranchGap: 0.9, LineGap: 1.0, DarkBranches: 2},
		{File: "src/low.rb", Method: "calm", Risk: 1.0, Decisions: 1, At: 27},
	}
	blast := []BlastRow{
		{File: "src/high.rb", Score: 1.25, Fixes: 3, AvgTouched: 2.5, MaxTouched: 4, Partners: [][2]interface{}{{"src/peer.rb", 2}}},
		{File: "src/low.rb", Score: 0.5, Fixes: 1, AvgTouched: 1, MaxTouched: 1},
	}
	lineage := LineageIndex{
		Status:          "ok",
		Label:           "lineage.sqlite3",
		HasTestExposure: true,
		Units: []LineageUnit{
			{File: "src/high.rb", Name: "danger", RiskScore: 4.2, Fixes: 2, Changes: 3, Moves: 1, TotalEvents: 6},
			{File: "src/low.rb", Name: "calm", RiskScore: 1.2, Fixes: 1, Changes: 1, Moves: 0, TotalEvents: 2},
		},
	}

	md := generateMarkdown(
		"/repo",
		[]string{"src"},
		nil,
		5,
		ranked,
		unmeasured,
		methods,
		stateRows,
		blast,
		lineage,
		false,
		"",
		true,
		"mutation.json",
		true,
		"exposure.json",
		1,
	)
	for _, want := range []string{
		"NoCoverageWarning",
		"WARNING: no branch-coverage resultset supplied",
		"Highest state-based branch hotspot",
		"Highest multi-file fix blast radius",
		"Highest empirical method risk",
		"Highest lineage unit risk",
		"not supplied | not supplied | named coverage",
		"...(+1 more)",
		"ABSENT (fix-churn only)",
		"mutation.json",
		"exposure.json",
		"lineage.sqlite3",
	} {
		if want == "NoCoverageWarning" {
			continue
		}
		if !strings.Contains(md, want) {
			t.Fatalf("markdown missing %q:\n%s", want, md)
		}
	}
	if strings.Contains(md, "@f") {
		t.Fatalf("state refs should be limited to five entries:\n%s", md)
	}

	sarifJSON := generateSarif(
		"/repo",
		nil,
		[]string{"src/high.rb"},
		5,
		ranked,
		unmeasured,
		methods,
		stateRows,
		blast,
		lineage,
		true,
		"coverage.xml",
		true,
		"mutation.json",
		true,
		"exposure.json",
		2,
	)
	var doc SarifDoc
	if err := json.Unmarshal([]byte(sarifJSON), &doc); err != nil {
		t.Fatalf("failed to parse sarif: %v\n%s", err, sarifJSON)
	}
	if len(doc.Runs) != 1 {
		t.Fatalf("sarif runs = %d; want 1", len(doc.Runs))
	}
	results := doc.Runs[0].Results
	if len(results) != 12 {
		t.Fatalf("sarif results = %d; want all six sections with two rows each: %+v", len(results), results)
	}
	seen := make(map[string]int)
	for _, result := range results {
		seen[result.RuleID]++
	}
	for _, ruleID := range []string{
		"boobytrap.file-hotspot",
		"boobytrap.dark-method",
		"boobytrap.state-branch-hotspot",
		"boobytrap.fix-blast-radius",
		"boobytrap.lineage-unit-risk",
		"boobytrap.fixed-unmeasured",
	} {
		if seen[ruleID] != 2 {
			t.Fatalf("sarif rule %s count = %d; want 2", ruleID, seen[ruleID])
		}
	}
}

func TestMethodGapComputationCombinesCoverageBranchesAndEvidence(t *testing.T) {
	dir := t.TempDir()
	source := strings.Join([]string{
		"func risky() {",
		"  config.Value = 1",
		"  if flag {",
		"    return 1",
		"  }",
		"  return 0",
		"}",
		"func covered() {",
		"  a := 1",
		"  b := 2",
		"  c := 3",
		"  return a + b + c",
		"}",
		"",
	}, "\n")
	writeTempFile(t, dir, "subject.go", source)
	file := filepath.Join(dir, "subject.go")
	dataset := &CoverageDataset{Files: map[string]FileCoverage{
		file: {
			Lines: []*int{
				ptr(1), ptr(0), ptr(0), ptr(1), nil, ptr(0), nil,
				ptr(1), ptr(1), ptr(1), ptr(1), ptr(1), nil,
			},
			Branches: map[string]map[string]int{
				"[:if,0,3,1,3,9]": {
					"[:then,1,3,1,3,4]": 0,
					"[:else,2,3,5,3,9]": 1,
				},
			},
			SourcePath: "subject.go",
			Format:     "simplecov",
			Language:   "go",
		},
		filepath.Join(dir, "missing.go"): {
			Lines:    []*int{ptr(0)},
			Branches: map[string]map[string]int{},
		},
	}}
	evidence := map[MethodKey]DecomplexScoreEntry{
		{File: "subject.go", Method: "risky"}: {
			File:      "subject.go",
			Method:    "risky",
			Score:     2,
			Findings:  []Finding{{Type: "state_branch_density"}},
			Detectors: []string{"state_branch_density", "unused_return"},
		},
	}

	rows := computeMethodGapsFromCoverage(dataset, dir, evidence)
	if len(rows) != 1 {
		t.Fatalf("method gap rows = %+v; want only risky row", rows)
	}
	row := rows[0]
	if row.File != "subject.go" || row.Name != "risky" {
		t.Fatalf("unexpected method row identity: %+v", row)
	}
	if row.ExecutableLines != 5 || row.CoveredLines != 2 || row.MissedLines != 3 {
		t.Fatalf("line accounting mismatch: %+v", row)
	}
	if row.LineGap != 0.6 || row.StateWrites != 1 || row.UncoveredBranches != 1 {
		t.Fatalf("risk inputs mismatch: %+v", row)
	}
	if row.DecomplexScore != 2 || len(row.DecomplexFindings) != 1 || len(row.DecomplexDetectors) != 2 {
		t.Fatalf("decomplex evidence mismatch: %+v", row)
	}
	if math.Abs(row.Risk-6.3) > 0.0001 {
		t.Fatalf("risk = %.4f; want 6.3", row.Risk)
	}
}

func TestStaticMethodGapComputationUsesSyntaxBranchFacts(t *testing.T) {
	dir := t.TempDir()
	source := strings.Join([]string{
		"def risky",
		"  @state = 1",
		"  if cond",
		"    true",
		"  else",
		"    false",
		"  end",
		"end",
		"",
	}, "\n")
	writeTempFile(t, dir, "subject.rb", source)
	armOne := json.RawMessage(`{"line":3}`)
	armTwo := json.RawMessage(`{"line":6}`)
	evidence := map[MethodKey]DecomplexScoreEntry{
		{File: "subject.rb", Method: "risky"}: {
			Score:     1,
			Findings:  []Finding{{Type: "unused_return"}},
			Detectors: []string{"unused_return"},
		},
	}

	rows := computeMethodGapsFromStatic(
		[]string{"subject.rb", filepath.Join(dir, "missing.rb")},
		dir,
		evidence,
		[]FactMineDoc{{
			File:       filepath.Join(dir, "subject.rb"),
			BranchArms: []json.RawMessage{armOne, armTwo, json.RawMessage(`{"not_line":99}`)},
		}},
	)
	if len(rows) != 1 {
		t.Fatalf("static method gap rows = %+v; want risky row", rows)
	}
	row := rows[0]
	if row.File != "subject.rb" || row.Name != "risky" {
		t.Fatalf("unexpected static row identity: %+v", row)
	}
	if row.ExecutableLines != 6 || row.MissedLines != 6 || row.CoveredLines != 0 || row.LineGap != 1.0 {
		t.Fatalf("static line accounting mismatch: %+v", row)
	}
	if row.StateWrites != 1 || row.UncoveredBranches != 2 || row.DecomplexScore != 1 {
		t.Fatalf("static risk inputs mismatch: %+v", row)
	}
	if math.Abs(row.Risk-9.5) > 0.0001 {
		t.Fatalf("static risk = %.4f; want 9.5", row.Risk)
	}
}

func TestStateBranchHotspotsUseMethodAndCoverageRiskInputs(t *testing.T) {
	rows := buildStateBranchHotspots(
		[]StateBranchDensityRow{
			{File: "b.rb", Method: "tie", Score: 2, Decisions: 5, At: "b.rb:10", StateRefs: []string{"@x"}, Predicate: "x?"},
			{File: "a.rb", Method: "winner", Score: 3, Decisions: 2, At: "a.rb:3"},
			{File: "c.rb", Method: "fallback", Score: 1, Decisions: 10},
		},
		[]MethodGapRow{
			{File: "a.rb", Name: "winner", LineGap: 0.5, UncoveredBranches: 2, TestExposureMultiplier: 0.5},
			{File: "b.rb", Name: "tie", LineGap: 0.1, UncoveredBranches: 0, TestExposureMultiplier: 1.0},
		},
		map[string]float64{"a.rb": 2, "b.rb": 1},
		2,
		map[string]FileGap{"a.rb": {Gap: 0.25}},
	)
	if len(rows) != 3 {
		t.Fatalf("state branch hotspot rows = %+v", rows)
	}
	if rows[0].File != "a.rb" || rows[0].Method != "winner" {
		t.Fatalf("winner row did not rank first: %+v", rows)
	}
	if rows[0].FixNorm != 1.0 || rows[0].BranchGap != 0.25 || rows[0].LineGap != 0.5 || rows[0].DarkBranches != 2 {
		t.Fatalf("winner row inputs mismatch: %+v", rows[0])
	}
	if rows[2].File != "c.rb" || rows[2].FixNorm != 0 || rows[2].LineGap != 0 {
		t.Fatalf("fallback row inputs mismatch: %+v", rows[2])
	}
}

func TestReportSortTieBreakersAreStable(t *testing.T) {
	stateRows := buildStateBranchHotspots(
		[]StateBranchDensityRow{
			{File: "b.rb", Method: "m", Score: 1, Decisions: 1},
			{File: "a.rb", Method: "z", Score: 1, Decisions: 1},
			{File: "a.rb", Method: "a", Score: 1, Decisions: 1},
			{File: "c.rb", Method: "d", Score: 1, Decisions: 2},
		},
		nil,
		nil,
		0,
		nil,
	)
	gotStateOrder := []string{
		stateRows[0].File + ":" + stateRows[0].Method,
		stateRows[1].File + ":" + stateRows[1].Method,
		stateRows[2].File + ":" + stateRows[2].Method,
		stateRows[3].File + ":" + stateRows[3].Method,
	}
	if strings.Join(gotStateOrder, ",") != "c.rb:d,a.rb:a,a.rb:z,b.rb:m" {
		t.Fatalf("state tie order = %+v", gotStateOrder)
	}

	methods := []MethodGapRow{
		{File: "z.rb", Name: "highest", FirstLine: 1, LastLine: 2, LineGap: 1, Risk: 6, MissedLines: 1, ExecutableLines: 2},
		{File: "b.rb", Name: "missed", FirstLine: 1, LastLine: 2, LineGap: 1, Risk: 5, MissedLines: 3, ExecutableLines: 4},
		{File: "a.rb", Name: "file", FirstLine: 2, LastLine: 3, LineGap: 1, Risk: 5, MissedLines: 2, ExecutableLines: 3},
		{File: "a.rb", Name: "line", FirstLine: 1, LastLine: 2, LineGap: 1, Risk: 5, MissedLines: 2, ExecutableLines: 3},
	}
	md := generateMarkdown(
		"/repo",
		nil,
		nil,
		0,
		nil,
		nil,
		methods,
		nil,
		nil,
		LineageIndex{Status: "absent"},
		true,
		"coverage.xml",
		false,
		"",
		false,
		"",
		10,
	)
	first := strings.Index(md, "`z.rb:1` `highest`")
	second := strings.Index(md, "`b.rb:1` `missed`")
	third := strings.Index(md, "`a.rb:1` `line`")
	fourth := strings.Index(md, "`a.rb:2` `file`")
	if !(first >= 0 && second > first && third > second && fourth > third) {
		t.Fatalf("dark method markdown sort order unexpected:\n%s", md)
	}

	sarifJSON := generateSarif(
		"/repo",
		nil,
		nil,
		0,
		nil,
		nil,
		methods,
		nil,
		nil,
		LineageIndex{Status: "absent"},
		true,
		"coverage.xml",
		false,
		"",
		false,
		"",
		10,
	)
	var sarif SarifDoc
	if err := json.Unmarshal([]byte(sarifJSON), &sarif); err != nil {
		t.Fatalf("failed to parse sarif: %v", err)
	}
	var dark []SarifResult
	for _, result := range sarif.Runs[0].Results {
		if result.RuleID == "boobytrap.dark-method" {
			dark = append(dark, result)
		}
	}
	if len(dark) != 4 || dark[0].Locations[0].PhysicalLocation.ArtifactLocation.URI != "z.rb" ||
		dark[1].Locations[0].PhysicalLocation.ArtifactLocation.URI != "b.rb" ||
		dark[2].Locations[0].PhysicalLocation.Region.StartLine != 1 ||
		dark[3].Locations[0].PhysicalLocation.Region.StartLine != 2 {
		t.Fatalf("dark method SARIF sort order mismatch: %+v", dark)
	}
}

func TestProcessMutationFacts(t *testing.T) {
	tmp, err := os.MkdirTemp("", "boobytrap-mutation-test")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmp)

	content := `{
		"schema": "mutant-facts/v1",
		"subjects": [
			{ "file": "src/x.rb", "method": "Owner#call", "kill_rate": "82.4%", "gate_status": "advisory" },
			{ "file": "src/y.rb", "method": "User#name", "kill_rate": 0.5, "gate_status": "hard" }
		]
	}`
	writeTempFile(t, tmp, "mutation.json", content)

	out, err := processMutationFacts(filepath.Join(tmp, "mutation.json"), tmp)
	if err != nil {
		t.Fatalf("processMutationFacts failed: %v", err)
	}

	if !out.Active {
		t.Errorf("expected Active to be true")
	}
	if len(out.Subjects) != 2 {
		t.Fatalf("expected 2 subjects, got %d", len(out.Subjects))
	}

	if out.Subjects[0].File != "src/x.rb" || out.Subjects[0].Method != "Owner#call" || *out.Subjects[0].KillRate != 82.4 || out.Subjects[0].GateStatus != "advisory" {
		t.Errorf("subject 0 mismatch: %+v", out.Subjects[0])
	}
	if out.Subjects[1].File != "src/y.rb" || out.Subjects[1].Method != "User#name" || *out.Subjects[1].KillRate != 50.0 || out.Subjects[1].GateStatus != "hard" {
		t.Errorf("subject 1 mismatch: %+v", out.Subjects[1])
	}
}

func TestProcessTestExposureFacts(t *testing.T) {
	tmp, err := os.MkdirTemp("", "boobytrap-exposure-test")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmp)

	content := `{
		"hits": [
			{ "file": "src/a.rb", "function": "foo", "id": "t1", "type": "spec", "mutation": "killed", "line": 10 }
		],
		"files": [
			{
				"file": "src/b.rb",
				"functions": [
					{
						"name": "bar",
						"tests": [
							{ "id": "t2", "type": "spec", "mutation": "survived" }
						]
					}
				],
				"lines": [
					{
						"line": 20,
						"tests": [
							{ "id": "t3", "type": "spec", "mutation": "none" }
						]
					}
				],
				"branches": [
					{
						"branch_id": "b1",
						"line": 30,
						"tests": [
							{ "id": "t4", "type": "spec", "mutation": "killed" }
						]
					}
				]
			}
		]
	}`
	writeTempFile(t, tmp, "exposure.json", content)

	out, err := processTestExposureFacts(filepath.Join(tmp, "exposure.json"), tmp)
	if err != nil {
		t.Fatalf("processTestExposureFacts failed: %v", err)
	}

	if len(out.MethodHits) != 2 {
		t.Errorf("expected 2 method hits, got %d", len(out.MethodHits))
	}
	if len(out.LineHits) != 2 {
		t.Errorf("expected 2 line hits, got %d", len(out.LineHits))
	}
	if len(out.BranchHits) != 2 {
		t.Errorf("expected 2 branch hits, got %d", len(out.BranchHits))
	}
}

func TestProcessStaticGaps(t *testing.T) {
	tmp, err := os.MkdirTemp("", "boobytrap-static-test")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmp)

	// Create a mock list of files
	content := `["src/x.rb", "src/y.py"]`
	writeTempFile(t, tmp, "static.json", content)

	// Mock covDataset where src/x.rb is covered, src/y.py is not
	covDataset := &CoverageDataset{
		Files: map[string]FileCoverage{
			filepath.Join(tmp, "src/x.rb"): {},
		},
	}

	// Test findFactMineRustBinary fallback behavior when binary is missing
	gaps, _, err := processStaticGaps(filepath.Join(tmp, "static.json"), tmp, covDataset)
	if err != nil {
		t.Fatalf("processStaticGaps failed: %v", err)
	}
	if len(gaps) != 0 {
		t.Errorf("expected 0 gaps (binary missing), got %d", len(gaps))
	}
}

func TestReportSubcommand(t *testing.T) {
	if os.Getenv("BE_REPORT_TEST") == "1" {
		os.Args = []string{
			"cmd",
			"report",
			"--repo=" + os.Getenv("TEST_REPO"),
			"--coverage=" + os.Getenv("TEST_COVERAGE"),
			"--output=" + os.Getenv("TEST_OUTPUT"),
			"--json=" + os.Getenv("TEST_JSON"),
			"--decomplex-facts=" + os.Getenv("TEST_DECOMPLEX"),
			"--mutation=" + os.Getenv("TEST_MUTATION"),
			"--test-exposure=" + os.Getenv("TEST_EXPOSURE"),
			"--lineage-db=" + os.Getenv("TEST_LINEAGE_DB"),
			"--lineage-command=" + os.Getenv("TEST_LINEAGE_COMMAND"),
			"--only=a.go",
		}
		flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
		main()
		return
	}

	dir := t.TempDir()
	runCmd(t, dir, "git", "init", "-q")
	runCmd(t, dir, "git", "config", "user.email", "test@test.com")
	runCmd(t, dir, "git", "config", "user.name", "test")

	// 1. Create mock source file
	srcFileContent := `package main

func testFunc() {
	x := 1
	y := 2
	z := 3
	a := 4
	b := 5
}
`
	writeTempFile(t, dir, "a.go", srcFileContent)
	runCmd(t, dir, "git", "add", "a.go")
	runCmd(t, dir, "git", "commit", "-qm", "Fix issue")

	// 2. Create mock coverage.json with lines and branches
	covData := map[string]interface{}{
		"RSpec": map[string]interface{}{
			"coverage": map[string]interface{}{
				filepath.Join(dir, "a.go"): map[string]interface{}{
					"lines": []interface{}{1.0, nil, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 1.0},
					"branches": map[string]interface{}{
						"[:if,0,3,1,3,9]": map[string]interface{}{
							"[:then,1,3,1,3,4]": 0.0,
							"[:else,2,3,5,3,9]": 1.0,
						},
					},
				},
			},
		},
	}
	covBytes, _ := json.Marshal(covData)
	covFile := filepath.Join(dir, "coverage.json")
	if err := os.WriteFile(covFile, covBytes, 0644); err != nil {
		t.Fatalf("failed to write coverage json: %v", err)
	}

	// 3. Create mock decomplex.json
	decomplexContent := fmt.Sprintf(`{
		"detectors": {
			"unused_return": [
				{
					"sites": ["%s:testFunc:3"]
				}
			],
			"state_branch_density": [
				{
					"file": "%s",
					"method": "testFunc",
					"score": 2.5,
					"decisions": 4,
					"state_refs": ["x", "y"],
					"predicate": "cond",
					"at": "%s:testFunc:3"
				}
			]
		}
	}`, filepath.Join(dir, "a.go"), filepath.Join(dir, "a.go"), filepath.Join(dir, "a.go"))
	decomplexFile := filepath.Join(dir, "decomplex.json")
	os.WriteFile(decomplexFile, []byte(decomplexContent), 0644)

	// 4. Create mock mutation.json
	mutationContent := `{
		"schema": "mutant-facts/v1",
		"subjects": [
			{ "file": "a.go", "method": "testFunc", "kill_rate": "82.4%", "gate_status": "advisory" }
		]
	}`
	mutationFile := filepath.Join(dir, "mutation.json")
	os.WriteFile(mutationFile, []byte(mutationContent), 0644)

	// 5. Create mock exposure.json
	exposureContent := `{
		"hits": [
			{ "file": "a.go", "function": "testFunc", "id": "t1", "type": "spec", "mutation": "killed", "line": 3 }
		],
		"files": [
			{
				"file": "a.go",
				"functions": [
					{
						"name": "testFunc",
						"tests": [
							{ "id": "t2", "type": "spec", "mutation": "survived" }
						]
					}
				]
			}
		]
	}`
	exposureFile := filepath.Join(dir, "exposure.json")
	os.WriteFile(exposureFile, []byte(exposureContent), 0644)

	// 6. Output and SARIF file destinations
	markdownFile := filepath.Join(dir, "report.md")
	sarifFile := filepath.Join(dir, "report.sarif")

	mockLineagePath := filepath.Join(dir, "mock-lineage")
	mockLineageContent := `#!/bin/sh
echo '[{"current_path":"a.go","name":"testFunc","risk_score":10.5,"fixes":2,"changes":5,"moves":1,"current_distinct_tests":3,"current_mutant_verified_tests":2,"current_mutant_killed_tests":1}]'`
	if err := os.WriteFile(mockLineagePath, []byte(mockLineageContent), 0755); err != nil {
		t.Fatalf("failed to write mock lineage: %v", err)
	}
	lineageCommand := mockLineagePath

	cmd := exec.Command(os.Args[0], "-test.run=TestReportSubcommand")
	cmd.Env = append(os.Environ(),
		"BE_REPORT_TEST=1",
		"TEST_REPO="+dir,
		"TEST_COVERAGE="+covFile,
		"TEST_OUTPUT="+markdownFile,
		"TEST_JSON="+sarifFile,
		"TEST_DECOMPLEX="+decomplexFile,
		"TEST_MUTATION="+mutationFile,
		"TEST_EXPOSURE="+exposureFile,
		"TEST_LINEAGE_DB="+covFile,
		"TEST_LINEAGE_COMMAND="+lineageCommand,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("report subcommand failed: %v, output: %s", err, string(out))
	}

	// Verify markdown file was written
	mdContent, err := os.ReadFile(markdownFile)
	if err != nil {
		t.Fatalf("failed to read markdown file: %v", err)
	}
	if !regexp.MustCompile(`# Boobytrap Report`).Match(mdContent) {
		t.Errorf("markdown report missing header, got: %s", string(mdContent))
	}

	// Verify sarif file was written
	sarifContent, err := os.ReadFile(sarifFile)
	if err != nil {
		t.Fatalf("failed to read sarif file: %v", err)
	}
	var doc SarifDoc
	if err := json.Unmarshal(sarifContent, &doc); err != nil {
		t.Fatalf("failed to unmarshal sarif content: %v, content: %s", err, string(sarifContent))
	}
	if doc.Version != "2.1.0" {
		t.Errorf("unexpected sarif version: %s", doc.Version)
	}
}

func TestReportSubcommandMinimal(t *testing.T) {
	if os.Getenv("BE_REPORT_MINIMAL_TEST") == "1" {
		os.Args = []string{
			"cmd",
			"report",
			"--repo=" + os.Getenv("TEST_REPO"),
			"--coverage=",
			"--output=" + os.Getenv("TEST_OUTPUT"),
			"--json=" + os.Getenv("TEST_JSON"),
			"--decomplex-facts=" + os.Getenv("TEST_DECOMPLEX"),
			"--static-files-file=" + os.Getenv("TEST_STATIC_FILES"),
			"--lineage-db=" + os.Getenv("TEST_LINEAGE_DB"),
			"--lineage-command=" + os.Getenv("TEST_LINEAGE_COMMAND"),
			"--files=b.py",
		}
		flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
		main()
		return
	}

	dir := t.TempDir()
	runCmd(t, dir, "git", "init", "-q")
	runCmd(t, dir, "git", "config", "user.email", "test@test.com")
	runCmd(t, dir, "git", "config", "user.name", "test")

	// 1. Create mock Python and other source files
	srcFileContent := `def testFunc():
    x = 1
    y = 2
    z = 3
    a = 4
    b = 5
`
	writeTempFile(t, dir, "b.py", srcFileContent)
	writeTempFile(t, dir, "c.rb", "def foo\n  x = 1\nend\n")
	writeTempFile(t, dir, "d.go", "package main\n")
	runCmd(t, dir, "git", "add", "b.py", "c.rb", "d.go")
	runCmd(t, dir, "git", "commit", "-qm", "Fix issue")

	// 2. Create static-files JSON containing our files
	staticFilesContent := `["b.py", "c.rb", "d.go"]`
	staticFilesFile := filepath.Join(dir, "static.json")
	os.WriteFile(staticFilesFile, []byte(staticFilesContent), 0644)

	// 3. Create mock decomplex.json
	decomplexContent := fmt.Sprintf(`{
		"detectors": {
			"unused_return": [
				{
					"sites": ["%s:testFunc:1"]
				}
			],
			"state_branch_density": [
				{
					"file": "%s",
					"method": "testFunc",
					"score": 2.5,
					"decisions": 4,
					"state_refs": ["x", "y"],
					"predicate": "cond",
					"at": "%s:testFunc:1"
				}
			]
		}
	}`, filepath.Join(dir, "b.py"), filepath.Join(dir, "b.py"), filepath.Join(dir, "b.py"))
	decomplexFile := filepath.Join(dir, "decomplex.json")
	os.WriteFile(decomplexFile, []byte(decomplexContent), 0644)

	// 4. Output and SARIF file destinations
	markdownFile := filepath.Join(dir, "report.md")
	sarifFile := filepath.Join(dir, "report.sarif")

	mockLineagePath := filepath.Join(dir, "mock-lineage")
	mockLineageContent := `#!/bin/sh
echo '[{"current_path":"b.py","name":"testFunc","risk_score":10.5,"fixes":2,"changes":5,"moves":1,"current_distinct_tests":3,"current_mutant_verified_tests":2,"current_mutant_killed_tests":1,"current_test_types":"spec;unit"}]'`
	if err := os.WriteFile(mockLineagePath, []byte(mockLineageContent), 0755); err != nil {
		t.Fatalf("failed to write mock lineage: %v", err)
	}
	lineageCommand := mockLineagePath

	// 5. Create mock fact-mine script to mock fact-mine-rust binary output
	mockFactMinePath := filepath.Join(dir, "mock-fact-mine")
	mockFactMineContent := fmt.Sprintf(`#!/bin/sh
echo '{"documents":[{"file":"%s","branch_arms":[{"line":3,"span":[3,1,3,10],"decision_line":2}]},{"file":"%s","branch_arms":[{"line":2,"span":[2,1,2,10],"decision_line":1}]}]}'`,
		filepath.Join(dir, "b.py"), filepath.Join(dir, "c.rb"))
	if err := os.WriteFile(mockFactMinePath, []byte(mockFactMineContent), 0755); err != nil {
		t.Fatalf("failed to write mock fact-mine: %v", err)
	}

	cmd := exec.Command(os.Args[0], "-test.run=TestReportSubcommandMinimal")
	cmd.Env = append(os.Environ(),
		"BE_REPORT_MINIMAL_TEST=1",
		"TEST_REPO="+dir,
		"TEST_OUTPUT="+markdownFile,
		"TEST_JSON="+sarifFile,
		"TEST_DECOMPLEX="+decomplexFile,
		"TEST_STATIC_FILES="+staticFilesFile,
		"TEST_LINEAGE_DB="+decomplexFile,
		"TEST_LINEAGE_COMMAND="+lineageCommand,
		"FACT_MINE_RUST_BINARY="+mockFactMinePath,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("report subcommand minimal failed: %v, output: %s", err, string(out))
	}

	// Verify markdown file was written
	mdContent, err := os.ReadFile(markdownFile)
	if err != nil {
		t.Fatalf("failed to read markdown file: %v", err)
	}
	if !regexp.MustCompile(`# Boobytrap Report`).Match(mdContent) {
		t.Errorf("markdown report missing header, got: %s", string(mdContent))
	}
}

func TestReportSubcommandSimple(t *testing.T) {
	if os.Getenv("BE_REPORT_SIMPLE_TEST") == "1" {
		os.Args = []string{
			"cmd",
			"report",
			"--repo=" + os.Getenv("TEST_REPO"),
			"--coverage=",
			"--output=" + os.Getenv("TEST_OUTPUT"),
			"--json=" + os.Getenv("TEST_JSON"),
			"--decomplex-facts=" + os.Getenv("TEST_DECOMPLEX"),
		}
		flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
		main()
		return
	}

	dir := t.TempDir()
	runCmd(t, dir, "git", "init", "-q")
	runCmd(t, dir, "git", "config", "user.email", "test@test.com")
	runCmd(t, dir, "git", "config", "user.name", "test")

	srcFileContent := `func simple() {
	x := 1
	y := 2
	z := 3
	a := 4
	b := 5
}
`
	writeTempFile(t, dir, "a.go", srcFileContent)
	runCmd(t, dir, "git", "add", "a.go")
	runCmd(t, dir, "git", "commit", "-qm", "Init")

	decomplexContent := fmt.Sprintf(`{
		"detectors": {
			"unused_return": [
				{
					"sites": ["%s:simple:1"]
				}
			]
		}
	}`, filepath.Join(dir, "a.go"))
	decomplexFile := filepath.Join(dir, "decomplex.json")
	os.WriteFile(decomplexFile, []byte(decomplexContent), 0644)

	markdownFile := filepath.Join(dir, "report.md")
	sarifFile := filepath.Join(dir, "report.sarif")

	cmd := exec.Command(os.Args[0], "-test.run=TestReportSubcommandSimple")
	cmd.Env = append(os.Environ(),
		"BE_REPORT_SIMPLE_TEST=1",
		"TEST_REPO="+dir,
		"TEST_OUTPUT="+markdownFile,
		"TEST_JSON="+sarifFile,
		"TEST_DECOMPLEX="+decomplexFile,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("report subcommand simple failed: %v, output: %s", err, string(out))
	}
}

func TestReportSubcommandGolden(t *testing.T) {
	if os.Getenv("BE_REPORT_GOLDEN_TEST") == "1" {
		os.Args = []string{
			"cmd",
			"report",
			"--repo=" + os.Getenv("TEST_REPO"),
			"--coverage=" + os.Getenv("TEST_COVERAGE"),
			"--output=" + os.Getenv("TEST_OUTPUT"),
			"--json=" + os.Getenv("TEST_JSON"),
			"--decomplex-facts=" + os.Getenv("TEST_DECOMPLEX"),
			"--mutation=" + os.Getenv("TEST_MUTATION"),
			"--test-exposure=" + os.Getenv("TEST_EXPOSURE"),
			"--static-files-file=" + os.Getenv("TEST_STATIC_FILES"),
			"--lineage-db=" + os.Getenv("TEST_LINEAGE_DB"),
			"--lineage-command=" + os.Getenv("TEST_LINEAGE_COMMAND"),
			"--only=a.go",
			"--files=" + os.Getenv("TEST_FILES"),
		}
		flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
		main()
		return
	}

	dir := t.TempDir()
	runCmd(t, dir, "git", "init", "-q")
	runCmd(t, dir, "git", "config", "user.email", "test@test.com")
	runCmd(t, dir, "git", "config", "user.name", "test")

	// 1. Mock source files
	srcGo := `package main

func testFunc() {
	x := 1
	y := 2
	z := 3
	a := 4
	b := 5
}
`
	srcPy := `def testFunc():
    x = 1
    y = 2
    z = 3
    a = 4
    b = 5
`
	writeTempFile(t, dir, "a.go", srcGo)
	writeTempFile(t, dir, "b.py", srcPy)
	writeTempFile(t, dir, "c.rb", "def foo\n  x = 1\nend\n")
	runCmd(t, dir, "git", "add", "a.go", "b.py", "c.rb")
	runCmd(t, dir, "git", "commit", "-qm", "Fix issue")

	// 2. Coverage JSON
	covData := map[string]interface{}{
		"RSpec": map[string]interface{}{
			"coverage": map[string]interface{}{
				filepath.Join(dir, "a.go"): map[string]interface{}{
					"lines": []interface{}{1.0, nil, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 1.0},
					"branches": map[string]interface{}{
						"[:if,0,3,1,3,9]": map[string]interface{}{
							"[:then,1,3,1,3,4]": 0.0,
							"[:else,2,3,5,3,9]": 1.0,
						},
					},
				},
			},
		},
	}
	covBytes, _ := json.Marshal(covData)
	covFile := filepath.Join(dir, "coverage.json")
	os.WriteFile(covFile, covBytes, 0644)

	// 3. Decomplex JSON
	decomplexContent := fmt.Sprintf(`{
		"detectors": {
			"unused_return": [
				{
					"sites": ["%s:testFunc:3", "%s:testFunc:1"]
				}
			],
			"state_branch_density": [
				{
					"file": "%s",
					"method": "testFunc",
					"score": 2.5,
					"decisions": 4,
					"state_refs": ["x", "y"],
					"predicate": "cond",
					"at": "%s:testFunc:3"
				},
				{
					"file": "%s",
					"method": "testFunc",
					"score": 2.5,
					"decisions": 4,
					"state_refs": ["x", "y"],
					"predicate": "cond",
					"at": "%s:testFunc:1"
				}
			]
		}
	}`, filepath.Join(dir, "a.go"), filepath.Join(dir, "b.py"), filepath.Join(dir, "a.go"), filepath.Join(dir, "a.go"), filepath.Join(dir, "b.py"), filepath.Join(dir, "b.py"))
	decomplexFile := filepath.Join(dir, "decomplex.json")
	os.WriteFile(decomplexFile, []byte(decomplexContent), 0644)

	// 4. Mutation JSON
	mutationContent := `{
		"schema": "mutant-facts/v1",
		"subjects": [
			{ "file": "a.go", "method": "testFunc", "kill_rate": "82.4%", "gate_status": "advisory" }
		]
	}`
	mutationFile := filepath.Join(dir, "mutation.json")
	os.WriteFile(mutationFile, []byte(mutationContent), 0644)

	// 5. Exposure JSON
	exposureContent := `{
		"hits": [
			{ "file": "a.go", "function": "testFunc", "id": "t1", "type": "spec", "mutation": "killed", "line": 3 }
		],
		"files": [
			{
				"file": "a.go",
				"functions": [
					{
						"name": "testFunc",
						"tests": [
							{ "id": "t2", "type": "spec", "mutation": "survived" }
						]
					}
				]
			}
		]
	}`
	exposureFile := filepath.Join(dir, "exposure.json")
	os.WriteFile(exposureFile, []byte(exposureContent), 0644)

	// 6. Lineage mocks
	mockLineagePath := filepath.Join(dir, "mock-lineage")
	mockLineageContent := `#!/bin/sh
echo '[{"current_path":"a.go","name":"testFunc","risk_score":10.5,"fixes":2,"changes":5,"moves":1,"current_distinct_tests":3,"current_mutant_verified_tests":2,"current_mutant_killed_tests":1},{"current_path":"b.py","name":"testFunc","risk_score":10.5,"fixes":2,"changes":5,"moves":1,"current_distinct_tests":3,"current_mutant_verified_tests":2,"current_mutant_killed_tests":1,"current_test_types":"spec;unit"}]'`
	os.WriteFile(mockLineagePath, []byte(mockLineageContent), 0755)
	lineageCommand := mockLineagePath

	// 7. Mock fact-mine
	mockFactMinePath := filepath.Join(dir, "mock-fact-mine")
	mockFactMineContent := fmt.Sprintf(`#!/bin/sh
echo '{"documents":[{"file":"%s","branch_arms":[{"line":3,"span":[3,1,3,10],"decision_line":2}]},{"file":"%s","branch_arms":[{"line":2,"span":[2,1,2,10],"decision_line":1}]}]}'`,
		filepath.Join(dir, "b.py"), filepath.Join(dir, "c.rb"))
	os.WriteFile(mockFactMinePath, []byte(mockFactMineContent), 0755)

	// Static files JSON
	staticFilesContent := `["b.py", "c.rb", "d.go"]`
	staticFilesFile := filepath.Join(dir, "static.json")
	os.WriteFile(staticFilesFile, []byte(staticFilesContent), 0644)

	// Exec runs helper
	runGoldenSubcommand := func(name string, env map[string]string) (string, string) {
		markdownFile := filepath.Join(dir, "report_"+name+".md")
		sarifFile := filepath.Join(dir, "report_"+name+".sarif")

		cmd := exec.Command(os.Args[0], "-test.run=TestReportSubcommandGolden")
		cmd.Env = append(os.Environ(), "BE_REPORT_GOLDEN_TEST=1", "TEST_REPO="+dir, "TEST_OUTPUT="+markdownFile, "TEST_JSON="+sarifFile)
		for k, v := range env {
			cmd.Env = append(cmd.Env, k+"="+v)
		}
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("report subcommand golden run %s failed: %v, output: %s", name, err, string(out))
		}

		mdBytes, err := os.ReadFile(markdownFile)
		if err != nil {
			t.Fatalf("failed to read generated md: %v", err)
		}
		sarifBytes, err := os.ReadFile(sarifFile)
		if err != nil {
			t.Fatalf("failed to read generated sarif: %v", err)
		}

		normalizedMd := strings.ReplaceAll(string(mdBytes), filepath.ToSlash(dir), "[REPO_ROOT]")
		normalizedMd = strings.ReplaceAll(normalizedMd, dir, "[REPO_ROOT]")

		normalizedSarif := strings.ReplaceAll(string(sarifBytes), filepath.ToSlash(dir), "[REPO_ROOT]")
		normalizedSarif = strings.ReplaceAll(normalizedSarif, dir, "[REPO_ROOT]")

		return normalizedMd, normalizedSarif
	}

	// RUN 1: Full empirical run
	md1, sarif1 := runGoldenSubcommand("full", map[string]string{
		"TEST_COVERAGE":        covFile,
		"TEST_DECOMPLEX":       decomplexFile,
		"TEST_MUTATION":        mutationFile,
		"TEST_EXPOSURE":        exposureFile,
		"TEST_LINEAGE_DB":      covFile,
		"TEST_LINEAGE_COMMAND": lineageCommand,
	})

	// RUN 2: Minimal static run
	md2, sarif2 := runGoldenSubcommand("minimal", map[string]string{
		"TEST_COVERAGE":         "",
		"TEST_DECOMPLEX":        decomplexFile,
		"TEST_STATIC_FILES":     staticFilesFile,
		"TEST_LINEAGE_DB":       covFile,
		"TEST_LINEAGE_COMMAND":  lineageCommand,
		"FACT_MINE_RUST_BINARY": mockFactMinePath,
		"TEST_FILES":            "b.py",
	})

	// RUN 3: Simple run
	md3, sarif3 := runGoldenSubcommand("simple", map[string]string{
		"TEST_DECOMPLEX": decomplexFile,
	})

	type goldenPair struct {
		mdPath, sarifPath string
		mdText, sarifText string
	}

	goldens := []goldenPair{
		{"testdata/report.golden.md", "testdata/report.golden.sarif", md1, sarif1},
		{"testdata/report_minimal.golden.md", "testdata/report_minimal.golden.sarif", md2, sarif2},
		{"testdata/report_simple.golden.md", "testdata/report_simple.golden.sarif", md3, sarif3},
	}

	if *update {
		if err := os.MkdirAll("testdata", 0755); err != nil {
			t.Fatalf("failed to create testdata dir: %v", err)
		}
		for _, g := range goldens {
			if err := os.WriteFile(g.mdPath, []byte(g.mdText), 0644); err != nil {
				t.Fatalf("failed to write golden md: %v", err)
			}
			if err := os.WriteFile(g.sarifPath, []byte(g.sarifText), 0644); err != nil {
				t.Fatalf("failed to write golden sarif: %v", err)
			}
		}
		t.Log("Successfully updated golden files.")
		return
	}

	// Compare with goldens
	for _, g := range goldens {
		goldenMdBytes, err := os.ReadFile(g.mdPath)
		if err != nil {
			t.Fatalf("failed to read golden md file: %v (run go test with -update to generate)", err)
		}
		goldenSarifBytes, err := os.ReadFile(g.sarifPath)
		if err != nil {
			t.Fatalf("failed to read golden sarif file: %v (run go test with -update to generate)", err)
		}

		if g.mdText != string(goldenMdBytes) {
			t.Errorf("Markdown output mismatch for %s! Expected:\n%s\n\nGot:\n%s", g.mdPath, string(goldenMdBytes), g.mdText)
		}
		if g.sarifText != string(goldenSarifBytes) {
			t.Errorf("SARIF output mismatch for %s! Expected:\n%s\n\nGot:\n%s", g.sarifPath, string(goldenSarifBytes), g.sarifText)
		}
	}
}
