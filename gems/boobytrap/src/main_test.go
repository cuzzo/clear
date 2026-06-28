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
		{"c", "/a/b", "c"},           // relative vs absolute error case
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

func runCmd(t *testing.T, dir string, name string, args ...string) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	if err := cmd.Run(); err != nil {
		t.Fatalf("command failed: %s %v: %v", name, args, err)
	}
}

func writeTempFile(t *testing.T, dir, filename, content string) {
	path := filepath.Join(dir, filename)
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
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
	runCmd(t, dir, "git", "add", "b.py" ,"c.rb", "d.go")
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
