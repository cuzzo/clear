package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type FuncRange struct {
	Name      string
	FirstLine int
	LastLine  int
}

func fallbackFunctionRanges(lines []string) []FuncRange {
	var ranges []FuncRange
	re := regexp.MustCompile(`\b(?:def|function|fn|func)\s+([A-Za-z_]\w*)(?:\s*\(|\b)`)
	for i, raw := range lines {
		matches := re.FindStringSubmatch(raw)
		if matches == nil {
			continue
		}
		name := matches[1]
		first := i + 1
		last := findBraceEnd(lines, i)
		if last == 0 {
			last = findIndentEnd(lines, i)
		}
		if last == 0 {
			last = first
		}
		ranges = append(ranges, FuncRange{
			Name:      name,
			FirstLine: first,
			LastLine:  last,
		})
	}
	return ranges
}

func findIndentEnd(lines []string, startIdx int) int {
	baseIndent := getIndent(lines[startIdx])
	last := startIdx + 1
	for offset := startIdx + 1; offset < len(lines); offset++ {
		raw := lines[offset]
		stripped := strings.TrimSpace(raw)
		if stripped == "" {
			continue
		}
		indent := getIndent(raw)
		if indent <= baseIndent {
			break
		}
		last = offset + 1
	}
	return last
}

func getIndent(line string) int {
	count := 0
	for _, r := range line {
		if r == ' ' || r == '\t' {
			count++
		} else {
			break
		}
	}
	return count
}

func findBraceEnd(lines []string, startIdx int) int {
	depth := 0
	opened := false
	for offset := startIdx; offset < len(lines); offset++ {
		raw := lines[offset]
		for _, ch := range raw {
			if ch == '{' {
				depth++
				opened = true
			} else if ch == '}' && opened {
				depth--
				if depth <= 0 {
					return offset + 1
				}
			}
		}
	}
	return 0
}

func executableSourceLine(line string) bool {
	stripped := strings.TrimSpace(line)
	if stripped == "" {
		return false
	}
	if strings.HasPrefix(stripped, "#") || strings.HasPrefix(stripped, "//") || strings.HasPrefix(stripped, "/*") || strings.HasPrefix(stripped, "*") {
		return false
	}
	switch stripped {
	case "end", "}", "{", ")", "(":
		return false
	}
	return true
}

var stateWriteRegexes = []*regexp.Regexp{
	regexp.MustCompile(`@\w+\s*(?:[+\-*\/%|&^]?=|<<)`),
	regexp.MustCompile(`@\w+\.\w+!?[=(]`),
	regexp.MustCompile(`\b[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+\s*(?:[+\-*\/%|&^]?=|<<)`),
}

func stateWriteCount(lines []string) int {
	count := 0
	for _, line := range lines {
		matched := false
		for _, re := range stateWriteRegexes {
			if re.MatchString(line) {
				matched = true
				break
			}
		}
		if matched {
			count++
		}
	}
	return count
}

func methodAliases(method string) []string {
	aliases := []string{method}
	if strings.Contains(method, "#") {
		parts := strings.Split(method, "#")
		aliases = append(aliases, parts[len(parts)-1])
	}
	if strings.Contains(method, ".") {
		parts := strings.Split(method, ".")
		aliases = append(aliases, parts[len(parts)-1])
	}
	if strings.Contains(method, "::") {
		parts := strings.Split(method, "::")
		aliases = append(aliases, parts[len(parts)-1])
	}
	seen := make(map[string]bool)
	var res []string
	for _, a := range aliases {
		if a != "" && !seen[a] {
			seen[a] = true
			res = append(res, a)
		}
	}
	return res
}

type BranchArmPayload struct {
	Line int `json:"line"`
}

type MethodKey struct {
	File   string
	Method string
}

type MethodGapRow struct {
	File                   string    `json:"file"`
	Name                   string    `json:"name"`
	FirstLine              int       `json:"first_line"`
	LastLine               int       `json:"last_line"`
	ExecutableLines        int       `json:"executable_lines"`
	CoveredLines           int       `json:"covered_lines"`
	MissedLines            int       `json:"missed_lines"`
	LineGap                float64   `json:"line_gap"`
	DecomplexScore         int       `json:"decomplex_score"`
	DecomplexFindings      []Finding `json:"decomplex_findings"`
	DecomplexDetectors     []string  `json:"decomplex_detectors"`
	StateWrites            int       `json:"state_writes"`
	UncoveredBranches      int       `json:"uncovered_branches"`
	Risk                   float64   `json:"risk"`
	FixNorm                float64   `json:"fix_norm"`
	VerificationStatus     string    `json:"verification_status"`
	MutationKillRate       *float64  `json:"mutation_kill_rate"`
	MutationGateStatus     string    `json:"mutation_gate_status"`
	RiskProfile            string    `json:"risk_profile"`
	VerificationMultiplier float64   `json:"verification_multiplier"`
	TestExposureStatus     string    `json:"test_exposure_status"`
	TestExposureProfile    string    `json:"test_exposure_profile"`
	TestExposureMultiplier float64   `json:"test_exposure_multiplier"`
	DistinctTestCount      int       `json:"distinct_test_count"`
	TestedLineCount        int       `json:"tested_line_count"`
	TestedBranchCount      int       `json:"tested_branch_count"`
	MutantVerifiedTestCount int       `json:"mutant_verified_test_count"`
	MutantKilledTestCount   int       `json:"mutant_killed_test_count"`
	LineageScore           float64   `json:"lineage_score"`
	LineageFixes           int       `json:"lineage_fixes"`
	LineageChanges         int       `json:"lineage_changes"`
	LineageMoves           int       `json:"lineage_moves"`
}

func methodRiskScore(missed int, gap float64, decomplexScore float64, stateWrites int, darkBranches int) float64 {
	return (float64(missed) * gap) + (decomplexScore * 1.5) + (float64(stateWrites) * 1.0) + (float64(darkBranches) * 0.5)
}

func branchMissesByLine(branches map[string]map[string]int) map[int]int {
	out := make(map[int]int)
	for _, arms := range branches {
		for arm, count := range arms {
			if count == 0 {
				line := parseBranchArmLine(arm)
				if line > 0 {
					out[line]++
				}
			}
		}
	}
	return out
}

func parseBranchArmLine(arm string) int {
	cleaned := strings.NewReplacer("[", "", "]", "", ":", "", ",", " ").Replace(arm)
	fields := strings.Fields(cleaned)
	if len(fields) >= 3 {
		line, _ := strconv.Atoi(fields[2])
		return line
	}
	return 0
}

func computeMethodGapsFromCoverage(dataset *CoverageDataset, repoRoot string, decomplexScoresMap map[MethodKey]DecomplexScoreEntry) []MethodGapRow {
	var rows []MethodGapRow
	for absPath, fileCov := range dataset.Files {
		if _, err := os.Stat(absPath); err != nil {
			continue
		}
		rel := relpathNoEval(absPath, repoRoot)

		data, err := os.ReadFile(absPath)
		if err != nil {
			continue
		}
		sourceLines := strings.Split(string(data), "\n")

		branchMisses := branchMissesByLine(fileCov.Branches)
		mRanges := fallbackFunctionRanges(sourceLines)

		for _, m := range mRanges {
			execLines := 0
			coveredLines := 0
			for ln := m.FirstLine; ln <= m.LastLine; ln++ {
				if ln-1 >= len(sourceLines) {
					continue
				}
				if ln-1 >= len(fileCov.Lines) {
					continue
				}
				v := fileCov.Lines[ln-1]
				if v == nil {
					continue
				}
				if !executableSourceLine(sourceLines[ln-1]) {
					continue
				}
				execLines++
				if *v > 0 {
					coveredLines++
				}
			}
			if execLines < 5 {
				continue
			}
			missed := execLines - coveredLines
			if missed == 0 {
				continue
			}

			// Slice body lines
			endIdx := m.LastLine
			if endIdx > len(sourceLines) {
				endIdx = len(sourceLines)
			}
			var body []string
			if m.FirstLine-1 < endIdx {
				body = sourceLines[m.FirstLine-1 : endIdx]
			}
			stateWrites := stateWriteCount(body)

			darkBranches := 0
			for ln, count := range branchMisses {
				if ln >= m.FirstLine && ln <= m.LastLine {
					darkBranches += count
				}
			}

			gap := float64(missed) / float64(execLines)
			key := MethodKey{File: rel, Method: m.Name}
			decomplex, exists := decomplexScoresMap[key]
			var findings []Finding
			var detectors []string
			dScore := 0.0
			if exists {
				findings = decomplex.Findings
				detectors = decomplex.Detectors
				dScore = float64(decomplex.Score)
			}

			rows = append(rows, MethodGapRow{
				File:               rel,
				Name:               m.Name,
				FirstLine:          m.FirstLine,
				LastLine:           m.LastLine,
				ExecutableLines:    execLines,
				CoveredLines:       coveredLines,
				MissedLines:        missed,
				LineGap:            gap,
				DecomplexScore:     int(dScore),
				DecomplexFindings:  findings,
				DecomplexDetectors: detectors,
				StateWrites:        stateWrites,
				UncoveredBranches:  darkBranches,
				Risk:               methodRiskScore(missed, gap, dScore, stateWrites, darkBranches),
			})
		}
	}
	return rows
}

func computeMethodGapsFromStatic(files []string, repoRoot string, decomplexScoresMap map[MethodKey]DecomplexScoreEntry, decomplexSyntax []FactMineDoc) []MethodGapRow {
	var rows []MethodGapRow

	// Pre-map decomplex syntax for quick lookup
	staticBranches := make(map[string]map[int]int)
	for _, doc := range decomplexSyntax {
		rel := relpathNoEval(doc.File, repoRoot)
		branchMisses := make(map[int]int)
		for _, armRaw := range doc.BranchArms {
			var arm BranchArmPayload
			if err := json.Unmarshal(armRaw, &arm); err == nil {
				branchMisses[arm.Line]++
			}
		}
		staticBranches[rel] = branchMisses
	}

	for _, file := range files {
		absPath := file
		if !filepath.IsAbs(file) {
			absPath = filepath.Join(repoRoot, file)
		}
		absPath = filepath.Clean(absPath)
		if _, err := os.Stat(absPath); err != nil {
			continue
		}
		rel := relpathNoEval(absPath, repoRoot)

		data, err := os.ReadFile(absPath)
		if err != nil {
			continue
		}
		sourceLines := strings.Split(string(data), "\n")

		branchMisses := staticBranches[rel]
		mRanges := fallbackFunctionRanges(sourceLines)

		for _, m := range mRanges {
			execLines := 0
			for ln := m.FirstLine; ln <= m.LastLine; ln++ {
				if ln-1 >= len(sourceLines) {
					continue
				}
				if !executableSourceLine(sourceLines[ln-1]) {
					continue
				}
				execLines++
			}
			if execLines < 5 {
				continue
			}

			endIdx := m.LastLine
			if endIdx > len(sourceLines) {
				endIdx = len(sourceLines)
			}
			var body []string
			if m.FirstLine-1 < endIdx {
				body = sourceLines[m.FirstLine-1 : endIdx]
			}
			stateWrites := stateWriteCount(body)

			darkBranches := 0
			for ln, count := range branchMisses {
				if ln >= m.FirstLine && ln <= m.LastLine {
					darkBranches += count
				}
			}

			key := MethodKey{File: rel, Method: m.Name}
			decomplex, exists := decomplexScoresMap[key]
			var findings []Finding
			var detectors []string
			dScore := 0.0
			if exists {
				findings = decomplex.Findings
				detectors = decomplex.Detectors
				dScore = float64(decomplex.Score)
			}

			rows = append(rows, MethodGapRow{
				File:               rel,
				Name:               m.Name,
				FirstLine:          m.FirstLine,
				LastLine:           m.LastLine,
				ExecutableLines:    execLines,
				CoveredLines:       0,
				MissedLines:        execLines,
				LineGap:            1.0,
				DecomplexScore:     int(dScore),
				DecomplexFindings:  findings,
				DecomplexDetectors: detectors,
				StateWrites:        stateWrites,
				UncoveredBranches:  darkBranches,
				Risk:               methodRiskScore(execLines, 1.0, dScore, stateWrites, darkBranches),
			})
		}
	}
	return rows
}

// Mutation Fact logic

func isMutationWeak(killRate *float64, gateStatus string) bool {
	if killRate == nil {
		return true
	}
	if *killRate < 60.0 {
		return true
	}
	switch strings.ToLower(gateStatus) {
	case "advisory", "soft", "open", "failed", "failing", "missing", "none", "unknown":
		return true
	}
	return false
}

func isMutationStrong(killRate *float64, gateStatus string) bool {
	if killRate == nil {
		return false
	}
	if *killRate < 90.0 {
		return false
	}
	switch strings.ToLower(gateStatus) {
	case "hard", "hard_gate", "hard-gated", "enforced", "required", "pass", "passed", "clean":
		return true
	}
	return false
}

func mutationSummary(killRate *float64, gateStatus string) string {
	rate := "no mutation"
	if killRate != nil {
		rate = fmt.Sprintf("%.1f%% killed", *killRate)
	}
	status := "unknown gate"
	if gateStatus != "" {
		status = gateStatus
	}
	return rate + " / " + status
}

func mutationRiskMultiplier(fact *MutationFact, active bool, complexity float64, history float64, coverageGap float64) float64 {
	if !active {
		return 1.0
	}
	var rate *float64
	var status string
	if fact != nil {
		rate = fact.KillRate
		status = fact.GateStatus
	}

	highComplexity := complexity >= 5.0
	highHistory := history >= 0.5
	highGap := coverageGap >= 0.8

	if isMutationStrong(rate, status) {
		if highComplexity && highHistory {
			return 0.9
		}
		return 0.75
	} else if fact != nil && !isMutationWeak(rate, status) && !isMutationStrong(rate, status) { // moderate
		return 1.1
	} else if highComplexity && highHistory && highGap {
		return 1.9
	} else if highComplexity && highHistory {
		return 1.7
	} else if highHistory || highComplexity {
		return 1.45
	}
	return 1.25
}

func mutationProfile(fact *MutationFact, active bool, complexity float64, history float64, coverageGap float64) string {
	if !active {
		return ""
	}
	var rate *float64
	var status string
	if fact != nil {
		rate = fact.KillRate
		status = fact.GateStatus
	}

	highComplexity := complexity >= 5.0
	highHistory := history >= 0.5
	highGap := coverageGap >= 0.8

	if isMutationWeak(rate, status) && highComplexity && highHistory && highGap {
		return "lurking disaster"
	} else if isMutationStrong(rate, status) && highComplexity {
		return "hardened veteran"
	} else if isMutationWeak(rate, status) && highHistory {
		return "fragile newcomer"
	} else if isMutationWeak(rate, status) {
		return "weak verification"
	} else if fact != nil && !isMutationWeak(rate, status) && !isMutationStrong(rate, status) {
		return "partial verification"
	}
	return "load-bearing tests"
}

func lookupMutationFact(factsMap map[MethodKey]MutationFact, file string, method string) *MutationFact {
	rel := cleanFile(file)
	aliases := methodAliases(method)

	// 1. Alias lookup
	for _, alias := range aliases {
		key := MethodKey{File: rel, Method: alias}
		if fact, exists := factsMap[key]; exists {
			return &fact
		}
	}
	// 2. File default default lookup
	keyDefault := MethodKey{File: rel, Method: "*"}
	if fact, exists := factsMap[keyDefault]; exists {
		return &fact
	}
	// 3. Global lookup
	for _, alias := range aliases {
		keyGlobal := MethodKey{File: "\x00global", Method: alias}
		if fact, exists := factsMap[keyGlobal]; exists {
			return &fact
		}
	}
	return nil
}

// Test Exposure Fact logic

type TestExposureHit struct {
	TestID         string `json:"test_id"`
	TestType       string `json:"test_type"`
	MutationStatus string `json:"mutation_status"`
	Line           int    `json:"line"`
	BranchID       string `json:"branch_id"`
}

type TestExposureAggregated struct {
	FunctionTests []TestExposureHit
	LineTests     map[int][]TestExposureHit
	BranchTests   map[string][]TestExposureHit
}

func isHitMutation(hit TestExposureHit) bool {
	status := strings.ToLower(hit.MutationStatus)
	return status != "" && status != "none" && status != "no" && status != "false" && status != "unverified"
}

func isHitKilled(hit TestExposureHit) bool {
	switch strings.ToLower(hit.MutationStatus) {
	case "killed", "kill", "pass", "passed", "hard", "hard-gated":
		return true
	}
	return false
}

func isHitSurvived(hit TestExposureHit) bool {
	switch strings.ToLower(hit.MutationStatus) {
	case "survived", "survive", "timeout", "timedout", "error", "failed", "failing":
		return true
	}
	return false
}

func uniqueTestIDs(hits []TestExposureHit) []string {
	seen := make(map[string]bool)
	var ids []string
	for _, h := range hits {
		if h.TestID != "" && !seen[h.TestID] {
			seen[h.TestID] = true
			ids = append(ids, h.TestID)
		}
	}
	return ids
}

func testExposureSummary(agg *TestExposureAggregated) string {
	all := append([]TestExposureHit{}, agg.FunctionTests...)
	for _, hList := range agg.LineTests {
		all = append(all, hList...)
	}
	for _, hList := range agg.BranchTests {
		all = append(all, hList...)
	}

	ids := uniqueTestIDs(all)
	if len(ids) == 0 {
		return "no named tests"
	}

	typeCounts := make(map[string]map[string]bool)
	for _, h := range all {
		tType := strings.TrimSpace(h.TestType)
		if tType == "" {
			tType = "unknown"
		}
		if _, exists := typeCounts[tType]; !exists {
			typeCounts[tType] = make(map[string]bool)
		}
		typeCounts[tType][h.TestID] = true
	}
	var typeKeys []string
	for k := range typeCounts {
		typeKeys = append(typeKeys, k)
	}
	sort.Strings(typeKeys)
	var typeTexts []string
	for _, k := range typeKeys {
		typeTexts = append(typeTexts, fmt.Sprintf("%s=%d", k, len(typeCounts[k])))
	}
	typeText := strings.Join(typeTexts, "/")

	killedCount := 0
	verifiedCount := 0
	killedSeen := make(map[string]bool)
	verifiedSeen := make(map[string]bool)
	for _, h := range all {
		if isHitKilled(h) {
			if !killedSeen[h.TestID] {
				killedSeen[h.TestID] = true
				killedCount++
			}
		}
		if isHitMutation(h) {
			if !verifiedSeen[h.TestID] {
				verifiedSeen[h.TestID] = true
				verifiedCount++
			}
		}
	}

	testedLines := 0
	for _, hits := range agg.LineTests {
		if len(hits) > 0 {
			testedLines++
		}
	}
	testedBranches := 0
	for _, hits := range agg.BranchTests {
		if len(hits) > 0 {
			testedBranches++
		}
	}

	return fmt.Sprintf("%d tests; %s; mutant killed %d/%d; lines=%d; branches=%d",
		len(ids), typeText, killedCount, verifiedCount, testedLines, testedBranches)
}

func testExposureMultiplier(agg *TestExposureAggregated, active bool, complexity float64, history float64, coverageGap float64) float64 {
	if !active {
		return 1.0
	}
	all := append([]TestExposureHit{}, agg.FunctionTests...)
	for _, hList := range agg.LineTests {
		all = append(all, hList...)
	}
	for _, hList := range agg.BranchTests {
		all = append(all, hList...)
	}
	ids := uniqueTestIDs(all)
	highRiskShape := complexity >= 5.0 || history >= 0.5 || coverageGap >= 0.8
	if len(ids) == 0 {
		if highRiskShape {
			return 1.15
		}
		return 1.05
	}

	killed := 0
	killedSeen := make(map[string]bool)
	for _, h := range all {
		if isHitKilled(h) {
			if !killedSeen[h.TestID] {
				killedSeen[h.TestID] = true
				killed++
			}
		}
	}
	typeCounts := make(map[string]bool)
	for _, h := range all {
		tType := strings.TrimSpace(h.TestType)
		if tType == "" {
			tType = "unknown"
		}
		typeCounts[tType] = true
	}

	if killed >= 3 {
		return 0.55
	}
	if killed > 0 {
		return 0.70
	}
	if len(ids) >= 5 && len(typeCounts) >= 2 {
		return 0.80
	}
	if len(ids) >= 2 {
		return 0.90
	}
	return 0.98
}

func testExposureProfile(agg *TestExposureAggregated, active bool) string {
	if !active {
		return ""
	}
	all := append([]TestExposureHit{}, agg.FunctionTests...)
	for _, hList := range agg.LineTests {
		all = append(all, hList...)
	}
	for _, hList := range agg.BranchTests {
		all = append(all, hList...)
	}
	ids := uniqueTestIDs(all)
	if len(ids) == 0 {
		return "unobserved by named tests"
	}
	killed := 0
	killedSeen := make(map[string]bool)
	for _, h := range all {
		if isHitKilled(h) {
			if !killedSeen[h.TestID] {
				killedSeen[h.TestID] = true
				killed++
			}
		}
	}
	if killed > 0 {
		return "mutation-killed exposure"
	}
	typeCounts := make(map[string]bool)
	for _, h := range all {
		tType := strings.TrimSpace(h.TestType)
		if tType == "" {
			tType = "unknown"
		}
		typeCounts[tType] = true
	}
	if len(typeCounts) >= 2 {
		return "diverse named coverage"
	}
	if len(ids) >= 2 {
		return "named coverage"
	}
	return "thin named coverage"
}

func buildTestExposureAggregated(index *TestExposurePayload, file string, method string, firstLine int, lastLine int) *TestExposureAggregated {
	rel := cleanFile(file)
	agg := &TestExposureAggregated{
		LineTests:   make(map[int][]TestExposureHit),
		BranchTests: make(map[string][]TestExposureHit),
	}

	aliases := methodAliases(method)

	// 1. Method hits
	if index != nil && index.MethodHits != nil {
		for _, entry := range index.MethodHits {
			if cleanFile(entry.File) != rel {
				continue
			}
			matched := false
			for _, alias := range aliases {
				if entry.Method == alias {
					matched = true
					break
				}
			}
			if matched {
				agg.FunctionTests = append(agg.FunctionTests, TestExposureHit{
					TestID:         entry.Hit.TestID,
					TestType:       entry.Hit.TestType,
					MutationStatus: entry.Hit.MutationStatus,
					Line:           entry.Hit.Line,
					BranchID:       entry.Hit.BranchID,
				})
			}
		}
	}

	// 2. Line hits
	if index != nil && index.LineHits != nil && firstLine > 0 && lastLine > 0 {
		for _, entry := range index.LineHits {
			if cleanFile(entry.File) != rel {
				continue
			}
			if entry.Line >= firstLine && entry.Line <= lastLine {
				agg.LineTests[entry.Line] = append(agg.LineTests[entry.Line], TestExposureHit{
					TestID:         entry.Hit.TestID,
					TestType:       entry.Hit.TestType,
					MutationStatus: entry.Hit.MutationStatus,
					Line:           entry.Hit.Line,
					BranchID:       entry.Hit.BranchID,
				})
			}
		}
	}

	// 3. Branch hits
	if index != nil && index.BranchHits != nil && firstLine > 0 && lastLine > 0 {
		for _, entry := range index.BranchHits {
			if cleanFile(entry.File) != rel {
				continue
			}
			if entry.Line >= firstLine && entry.Line <= lastLine {
				brKey := entry.BranchID
				if brKey == "" {
					brKey = fmt.Sprintf("line:%d", entry.Line)
				}
				agg.BranchTests[brKey] = append(agg.BranchTests[brKey], TestExposureHit{
					TestID:         entry.Hit.TestID,
					TestType:       entry.Hit.TestType,
					MutationStatus: entry.Hit.MutationStatus,
					Line:           entry.Hit.Line,
					BranchID:       entry.Hit.BranchID,
				})
			}
		}
	}

	return agg
}

// Lineage SQLite logic

type LineageUnit struct {
	ID                         string   `json:"id"`
	Name                       string   `json:"name"`
	Kind                       string   `json:"kind"`
	File                       string   `json:"current_path"`
	TotalEvents                int      `json:"total_events"`
	Changes                    int      `json:"changes"`
	Moves                      int      `json:"moves"`
	Fixes                      int      `json:"fixes"`
	RiskScore                  float64  `json:"risk_score"`
	CurrentDistinctTests       int      `json:"current_distinct_tests"`
	CurrentTestTypes           string   `json:"current_test_types"`
	CurrentMutantVerifiedTests int      `json:"current_mutant_verified_tests"`
	CurrentMutantKilledTests   int      `json:"current_mutant_killed_tests"`
	LastTestExposureAt         int64    `json:"last_test_exposure_at"`
	LatestFixAt                int64    `json:"latest_fix_at"`
	LatestChangeAt             int64    `json:"latest_change_at"`
	FixesAfterTestExposure     int      `json:"fixes_after_test_exposure"`
	ChangesAfterTestExposure   int      `json:"changes_after_test_exposure"`
}

type LineageIndex struct {
	Status          string
	Units           []LineageUnit
	Index           map[MethodKey]LineageUnit
	HasTestExposure bool
	Label           string
}

func loadLineage(dbPath string, repoRoot string, only []string, top int, command string) LineageIndex {
	if dbPath == "" {
		return LineageIndex{Status: "absent"}
	}
	if _, err := os.Stat(dbPath); err != nil {
		return LineageIndex{Status: "absent"}
	}

	args := []string{"summary", "--db", dbPath, "--top", strconv.Itoa(top), "--format", "json"}
	for _, o := range only {
		args = append(args, "--only", o)
	}

	var cmd *exec.Cmd
	if command != "" {
		parts := strings.Fields(command)
		parts = append(parts, args...)
		cmd = exec.Command(parts[0], parts[1:]...)
	} else {
		binary := filepath.Join(repoRoot, "gems", "lineage", "target", "release", "lineage")
		if _, err := os.Stat(binary); err == nil {
			cmd = exec.Command(binary, args...)
		} else {
			cmd = exec.Command("cargo", "run", "--quiet", "--manifest-path", filepath.Join(repoRoot, "gems", "lineage", "Cargo.toml"), "--")
			cmd.Args = append(cmd.Args, args...)
		}
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		if os.Getenv("BOOBYTRAP_DEBUG") != "" {
			fmt.Fprintf(os.Stderr, "Lineage execution failed: %v, stderr: %s\n", err, stderr.String())
		}
		return LineageIndex{Status: "absent"}
	}

	var rawUnits []LineageUnit
	if err := json.Unmarshal(stdout.Bytes(), &rawUnits); err != nil {
		return LineageIndex{Status: "absent"}
	}

	units := []LineageUnit{}
	index := make(map[MethodKey]LineageUnit)
	hasTestExposure := false

	for _, u := range rawUnits {
		// Verify file exists
		if u.File != "" {
			abs := filepath.Join(repoRoot, u.File)
			if _, err := os.Stat(abs); err == nil {
				units = append(units, u)
				key := MethodKey{File: u.File, Method: u.Name}
				index[key] = u
				if u.CurrentDistinctTests > 0 {
					hasTestExposure = true
				}
			}
		}
	}

	return LineageIndex{
		Status:          "ok",
		Units:           units,
		Index:           index,
		HasTestExposure: hasTestExposure,
		Label:           filepath.Base(dbPath),
	}
}

func parseTestTypes(val string) []string {
	if val == "" {
		return nil
	}
	parts := strings.Split(val, ",")
	seen := make(map[string]bool)
	var res []string
	for _, p := range parts {
		cleaned := strings.TrimSpace(p)
		if cleaned != "" && !seen[cleaned] {
			seen[cleaned] = true
			res = append(res, cleaned)
		}
	}
	sort.Strings(res)
	return res
}

func lineageTestExposureStatus(u LineageUnit) string {
	if u.CurrentDistinctTests == 0 {
		return ""
	}
	types := parseTestTypes(u.CurrentTestTypes)
	typeText := "unknown"
	if len(types) > 0 {
		typeText = strings.Join(types, "/")
	}
	stale := ""
	if u.FixesAfterTestExposure > 0 {
		stale = fmt.Sprintf("; ignored: %d later fix(es)", u.FixesAfterTestExposure)
	} else if u.CurrentDistinctTests > 0 && u.FixesAfterTestExposure == 0 && u.LatestFixAt > 0 && u.LastTestExposureAt >= u.LatestFixAt {
		stale = "; hardened after latest fix"
	}
	return fmt.Sprintf("lineage: %d tests; %s; mutant killed %d/%d%s",
		u.CurrentDistinctTests, typeText, u.CurrentMutantKilledTests, u.CurrentMutantVerifiedTests, stale)
}

func lineageExposureProfile(u LineageUnit) string {
	if u.CurrentDistinctTests == 0 {
		return ""
	}
	if u.FixesAfterTestExposure > 0 {
		return "stale lineage exposure ignored"
	}
	if u.CurrentMutantKilledTests > 0 {
		return "mutation-killed exposure (lineage)"
	}
	types := parseTestTypes(u.CurrentTestTypes)
	if len(types) >= 2 {
		return "diverse named coverage (lineage)"
	}
	if u.CurrentDistinctTests >= 2 {
		return "named coverage (lineage)"
	}
	return "thin named coverage (lineage)"
}

func lineageExposureMultiplier(u LineageUnit, active bool, complexity float64, history float64, coverageGap float64) float64 {
	if !active {
		return 1.0
	}
	if u.CurrentDistinctTests == 0 {
		return 1.0
	}
	if u.FixesAfterTestExposure > 0 {
		return 1.0
	}
	// Check if hardened
	hardened := u.CurrentDistinctTests > 0 && u.FixesAfterTestExposure == 0 && u.LatestFixAt > 0 && u.LastTestExposureAt >= u.LatestFixAt
	if !hardened {
		return 1.0
	}

	killed := u.CurrentMutantKilledTests
	tests := u.CurrentDistinctTests
	types := len(parseTestTypes(u.CurrentTestTypes))
	highRiskShape := complexity >= 5.0 || history >= 0.5 || coverageGap >= 0.8

	if killed >= 3 {
		return 0.45
	}
	if killed > 0 {
		return 0.60
	}
	if tests >= 5 && types >= 2 {
		return 0.75
	}
	if tests >= 2 {
		return 0.88
	}
	if highRiskShape {
		return 0.97
	}
	return 1.0
}

// Hotspots ranking logic

type HotspotRow struct {
	File          string  `json:"file"`
	Fix           float64 `json:"fix"`
	FixNorm       float64 `json:"fix_norm"`
	Gap           float64 `json:"gap"`
	TotalBranches int     `json:"total_branches"`
	Uncovered     int     `json:"uncovered"`
	Hotspot       float64 `json:"hotspot"`
}

type UnmeasuredEntry struct {
	File    string  `json:"file"`
	Fix     float64 `json:"fix"`
	FixNorm float64 `json:"fix_norm"`
}

func rankHotspots(scores map[string]float64, gaps map[string]FileGap) ([]HotspotRow, []UnmeasuredEntry) {
	maxVal := 0.0
	for _, val := range scores {
		if val > maxVal {
			maxVal = val
		}
	}
	if maxVal == 0.0 {
		maxVal = 1.0
	}

	var ranked []HotspotRow
	var unmeasured []UnmeasuredEntry

	for file, fix := range scores {
		fixNorm := fix / maxVal
		g, exists := gaps[file]
		if !exists {
			unmeasured = append(unmeasured, UnmeasuredEntry{
				File:    file,
				Fix:     math.Round(fix*1000) / 1000,
				FixNorm: math.Round(fixNorm*1000) / 1000,
			})
			continue
		}
		ranked = append(ranked, HotspotRow{
			File:          file,
			Fix:           math.Round(fix*1000) / 1000,
			FixNorm:       math.Round(fixNorm*1000) / 1000,
			Gap:           math.Round(g.Gap*1000) / 1000,
			TotalBranches: g.Total,
			Uncovered:     g.Uncovered,
			Hotspot:       math.Round((fixNorm*g.Gap)*10000) / 10000,
		})
	}

	sort.Slice(ranked, func(i, j int) bool {
		if ranked[i].Hotspot != ranked[j].Hotspot {
			return ranked[i].Hotspot > ranked[j].Hotspot
		}
		return ranked[i].File < ranked[j].File
	})

	sort.Slice(unmeasured, func(i, j int) bool {
		if unmeasured[i].Fix != unmeasured[j].Fix {
			return unmeasured[i].Fix > unmeasured[j].Fix
		}
		return unmeasured[i].File < unmeasured[j].File
	})

	return ranked, unmeasured
}

