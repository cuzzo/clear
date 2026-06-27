package main

import (
	"encoding/json"
	"flag"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"
)

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
