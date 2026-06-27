package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
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

type Output struct {
	FixCommits         int                     `json:"fix_commits"`
	FixScores          map[string]float64      `json:"fix_scores"`
	Blast              []BlastRow              `json:"blast_radius"`
	Coverage           *CoverageDataset        `json:"coverage,omitempty"`
	Gaps               map[string]FileGap      `json:"gaps,omitempty"`
	DecomplexScores    []DecomplexScoreEntry   `json:"decomplex_scores,omitempty"`
	StateBranchDensity []StateBranchDensityRow `json:"state_branch_density,omitempty"`
	MutationFacts      *MutationFactsOutput    `json:"mutation_facts,omitempty"`
	TestExposure       *TestExposurePayload    `json:"test_exposure,omitempty"`
}

type MutationFactsOutput struct {
	Active   bool           `json:"active"`
	Subjects []MutationFact `json:"subjects"`
}

type MutationFact struct {
	File       string   `json:"file"`
	Method     string   `json:"method"`
	KillRate   *float64 `json:"kill_rate"`
	GateStatus string   `json:"gate_status"`
}

type TestExposurePayload struct {
	MethodHits []MethodHitEntry `json:"method_hits,omitempty"`
	LineHits   []LineHitEntry   `json:"line_hits,omitempty"`
	BranchHits []BranchHitEntry `json:"branch_hits,omitempty"`
}

type MethodHitEntry struct {
	File   string `json:"file"`
	Method string `json:"method"`
	Hit    Hit    `json:"hit"`
}

type LineHitEntry struct {
	File string `json:"file"`
	Line int    `json:"line"`
	Hit  Hit    `json:"hit"`
}

type BranchHitEntry struct {
	File     string `json:"file"`
	BranchID string `json:"branch_id"`
	Line     int    `json:"line"`
	Hit      Hit    `json:"hit"`
}

type Hit struct {
	TestID         string `json:"test_id"`
	TestType       string `json:"test_type"`
	MutationStatus string `json:"mutation_status"`
	Line           int    `json:"line"`
	BranchID       string `json:"branch_id"`
}

type DecomplexScoreEntry struct {
	File      string    `json:"file"`
	Method    string    `json:"method"`
	Score     int       `json:"score"`
	Findings  []Finding `json:"findings"`
	Detectors []string  `json:"detectors"`
}

type Finding struct {
	Type string `json:"type"`
}

type StateBranchDensityRow struct {
	File      string      `json:"file"`
	Method    string      `json:"method"`
	Score     float64     `json:"score"`
	Decisions int         `json:"decisions"`
	At        interface{} `json:"at"`
	StateRefs []string    `json:"state_refs"`
	Predicate string      `json:"predicate"`
}

type BlastRow struct {
	File       string        `json:"file"`
	Score      float64       `json:"score"`
	Fixes      int           `json:"fixes"`
	AvgTouched float64       `json:"avg_touched"`
	MaxTouched int           `json:"max_touched"`
	Partners   [][2]interface{} `json:"partners"`
}

type CoverageDataset struct {
	Files map[string]FileCoverage `json:"files"`
}

type FileCoverage struct {
	Lines      []*int                    `json:"lines"`
	Branches   map[string]map[string]int `json:"branches"`
	SourcePath string                    `json:"source_path"`
}

type FileGap struct {
	Total     int     `json:"total"`
	Uncovered int     `json:"uncovered"`
	Gap       float64 `json:"gap"`
}

type Event struct {
	Time    int64
	Subject string
	Files   []string
}

func main() {
	repoPath := flag.String("repo", "", "Path to repository")
	covPath := flag.String("coverage", "", "Path to coverage JSON")
	decomplexFactsPath := flag.String("decomplex-facts", "", "Path to decomplex facts JSON")
	mutationPath := flag.String("mutation", "", "Path to mutation facts JSON")
	testExposurePath := flag.String("test-exposure", "", "Path to test exposure facts JSON")
	fixRePat := flag.String("fix-re", `\b(fix(es|ed)?|bug\s*fix|close[sd]?)\b`, "Regex for fix commits")
	flag.Parse()

	if *repoPath == "" {
		fmt.Fprintln(os.Stderr, "Error: --repo is required")
		os.Exit(1)
	}

	absRepo, err := filepath.Abs(*repoPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error resolving repo path: %v\n", err)
		os.Exit(1)
	}

	fixRe, err := regexp.Compile("(?i)" + *fixRePat)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error compiling fix regex: %v\n", err)
		os.Exit(1)
	}

	// 1. Process Git log
	events, err := getGitEvents(absRepo, fixRe)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading git events: %v\n", err)
		os.Exit(1)
	}

	scores, blast := computeBugspots(events)

	// 2. Process Coverage if supplied
	var covDataset *CoverageDataset
	var gaps map[string]FileGap
	if *covPath != "" {
		covDataset, gaps, err = processCoverage(*covPath, absRepo)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error processing coverage: %v\n", err)
			os.Exit(1)
		}
	}

	// 3. Process Decomplex facts if supplied
	var decomplexScores []DecomplexScoreEntry
	var densityRows []StateBranchDensityRow
	if *decomplexFactsPath != "" {
		decomplexScores, densityRows, err = processDecomplexFacts(*decomplexFactsPath, absRepo)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error processing decomplex facts: %v\n", err)
			os.Exit(1)
		}
	}

	// 4. Process Mutation facts if supplied
	var mutationOutput *MutationFactsOutput
	if *mutationPath != "" {
		mutationOutput, err = processMutationFacts(*mutationPath, absRepo)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error processing mutation facts: %v\n", err)
			os.Exit(1)
		}
	}

	// 5. Process Test Exposure facts if supplied
	var testExposureOutput *TestExposurePayload
	if *testExposurePath != "" {
		testExposureOutput, err = processTestExposureFacts(*testExposurePath, absRepo)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error processing test exposure facts: %v\n", err)
			os.Exit(1)
		}
	}

	out := Output{
		FixCommits:         len(events),
		FixScores:          scores,
		Blast:              blast,
		Coverage:           covDataset,
		Gaps:               gaps,
		DecomplexScores:    decomplexScores,
		StateBranchDensity: densityRows,
		MutationFacts:      mutationOutput,
		TestExposure:       testExposureOutput,
	}

	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(out); err != nil {
		fmt.Fprintf(os.Stderr, "Error encoding output: %v\n", err)
		os.Exit(1)
	}
}

func getGitEvents(repo string, fixRe *regexp.Regexp) ([]Event, error) {
	cmd := exec.Command("git", "-C", repo, "log", "--no-merges", "--pretty=format:@@@%ct%x09%s", "--name-only")
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	if err := cmd.Run(); err != nil {
		return nil, err
	}

	var events []Event
	var cur *Event

	scanner := bufio.NewScanner(&stdout)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "@@@") {
			if cur != nil && fixRe.MatchString(cur.Subject) && len(cur.Files) > 0 {
				events = append(events, *cur)
			}
			parts := strings.SplitN(line[3:], "\t", 2)
			if len(parts) < 2 {
				continue
			}
			t, _ := strconv.ParseInt(parts[0], 10, 64)
			cur = &Event{
				Time:    t,
				Subject: parts[1],
				Files:   nil,
			}
		} else if line != "" && cur != nil {
			cur.Files = append(cur.Files, line)
		}
	}
	if cur != nil && fixRe.MatchString(cur.Subject) && len(cur.Files) > 0 {
		events = append(events, *cur)
	}

	return events, nil
}

func computeBugspots(events []Event) (map[string]float64, []BlastRow) {
	if len(events) == 0 {
		return map[string]float64{}, nil
	}

	var first, last int64
	first = math.MaxInt64
	last = math.MinInt64
	for _, e := range events {
		if e.Time < first {
			first = e.Time
		}
		if e.Time > last {
			last = e.Time
		}
	}
	span := float64(last - first)

	// File bugspot scores
	scores := make(map[string]float64)
	for _, e := range events {
		t := 1.0
		if span > 0 {
			t = float64(e.Time-first) / span
		}
		w := 1.0 / (1.0 + math.Exp(-12.0*t+12.0))
		seen := make(map[string]bool)
		for _, f := range e.Files {
			if !seen[f] {
				seen[f] = true
				scores[f] += w
			}
		}
	}

	// Blast radius scoring
	type blastAccum struct {
		score      float64
		fixes      int
		touchedSum int
		maxTouched int
		partners   map[string]float64
	}

	acc := make(map[string]*blastAccum)
	for _, e := range events {
		// Dedup files in the commit
		seen := make(map[string]bool)
		var files []string
		for _, f := range e.Files {
			if !seen[f] {
				seen[f] = true
				files = append(files, f)
			}
		}
		if len(files) == 0 {
			continue
		}

		t := 1.0
		if span > 0 {
			t = float64(e.Time-first) / span
		}
		w := 1.0 / (1.0 + math.Exp(-12.0*t+12.0))
		touched := len(files)

		for _, file := range files {
			row, exists := acc[file]
			if !exists {
				row = &blastAccum{partners: make(map[string]float64)}
				acc[file] = row
			}
			row.score += w * math.Max(float64(touched-1), 0.0)
			row.fixes++
			row.touchedSum += touched
			if touched > row.maxTouched {
				row.maxTouched = touched
			}
			for _, partner := range files {
				if partner != file {
					row.partners[partner] += w
				}
			}
		}
	}

	var blast []BlastRow = []BlastRow{}
	for file, row := range acc {
		// Sort partners descending by weight
		type partnerPair struct {
			name   string
			weight float64
		}
		var pairs []partnerPair
		for p, w := range row.partners {
			pairs = append(pairs, partnerPair{p, w})
		}
		sort.Slice(pairs, func(i, j int) bool {
			if pairs[i].weight == pairs[j].weight {
				return pairs[i].name < pairs[j].name
			}
			return pairs[i].weight > pairs[j].weight
		})

		partners := [][2]interface{}{}
		for i := 0; i < len(pairs) && i < 5; i++ {
			partners = append(partners, [2]interface{}{pairs[i].name, math.Round(pairs[i].weight*1000) / 1000})
		}

		avg := float64(row.touchedSum) / float64(row.fixes)
		blast = append(blast, BlastRow{
			File:       file,
			Score:      math.Round(row.score*1000) / 1000,
			Fixes:      row.fixes,
			AvgTouched: math.Round(avg*100) / 100,
			MaxTouched: row.maxTouched,
			Partners:   partners,
		})
	}

	sort.Slice(blast, func(i, j int) bool {
		if blast[i].Score != blast[j].Score {
			return blast[i].Score > blast[j].Score
		}
		if blast[i].AvgTouched != blast[j].AvgTouched {
			return blast[i].AvgTouched > blast[j].AvgTouched
		}
		return blast[i].File < blast[j].File
	})

	return scores, blast
}

func processCoverage(covPath, repo string) (*CoverageDataset, map[string]FileGap, error) {
	data, err := os.ReadFile(covPath)
	if err != nil {
		return nil, nil, err
	}

	// We parse the raw SimpleCov JSON into an unstructured map first
	var raw map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, nil, err
	}

	// Format definition: SimpleCov resultset JSON
	// Maps: entryName -> { "coverage" -> { filePath -> { "lines" -> [...], "branches" -> { ... } } } }
	files := make(map[string]FileCoverage)

	for _, entryVal := range raw {
		entry, ok := entryVal.(map[string]interface{})
		if !ok {
			continue
		}
		covMapVal, ok := entry["coverage"]
		if !ok {
			continue
		}
		covMap, ok := covMapVal.(map[string]interface{})
		if !ok {
			continue
		}

		for file, covDataVal := range covMap {
			covData, ok := covDataVal.(map[string]interface{})
			if !ok {
				continue
			}

			absFile, err := filepath.EvalSymlinks(file)
			if err != nil {
				absFile = file
			}
			absFile, err = filepath.Abs(absFile)
			if err != nil {
				absFile = file
			}

			dst, exists := files[absFile]
			if !exists {
				dst = FileCoverage{
					Lines:      []*int{},
					Branches:   make(map[string]map[string]int),
					SourcePath: relpath(absFile, repo),
				}
			}

			// Merge lines
			if linesVal, ok := covData["lines"]; ok {
				if linesArr, ok := linesVal.([]interface{}); ok {
					dst.Lines = mergeLines(dst.Lines, linesArr)
				}
			}

			// Merge branches
			if branchesVal, ok := covData["branches"]; ok {
				if branchesMap, ok := branchesVal.(map[string]interface{}); ok {
					dst.Branches = mergeBranches(dst.Branches, branchesMap)
				}
			}

			files[absFile] = dst
		}
	}

	// Compute Coverage Gaps
	gaps := make(map[string]FileGap)
	for absFile, cov := range files {
		if len(cov.Branches) > 0 {
			total := 0
			uncov := 0
			for _, arms := range cov.Branches {
				for _, count := range arms {
					total++
					if count == 0 {
						uncov++
					}
				}
			}
			if total > 0 {
				gaps[relpath(absFile, repo)] = FileGap{
					Total:     total,
					Uncovered: uncov,
					Gap:       float64(uncov) / float64(total),
				}
			}
		}
	}

	return &CoverageDataset{Files: files}, gaps, nil
}

func mergeLines(target []*int, source []interface{}) []*int {
	maxLen := len(target)
	if len(source) > maxLen {
		maxLen = len(source)
	}

	res := make([]*int, maxLen)
	for i := 0; i < maxLen; i++ {
		var v1, v2 *int
		if i < len(target) {
			v1 = target[i]
		}
		if i < len(source) && source[i] != nil {
			if num, ok := source[i].(float64); ok {
				val := int(num)
				v2 = &val
			}
		}

		if v1 == nil {
			res[i] = v2
		} else if v2 == nil {
			res[i] = v1
		} else {
			sum := *v1 + *v2
			res[i] = &sum
		}
	}
	return res
}

func mergeBranches(target map[string]map[string]int, source map[string]interface{}) map[string]map[string]int {
	if target == nil {
		target = make(map[string]map[string]int)
	}
	for key, sourceArmsVal := range source {
		sourceArms, ok := sourceArmsVal.(map[string]interface{})
		if !ok {
			continue
		}
		targetArms, exists := target[key]
		if !exists {
			targetArms = make(map[string]int)
			target[key] = targetArms
		}
		for arm, hitsVal := range sourceArms {
			if hitsNum, ok := hitsVal.(float64); ok {
				targetArms[arm] = targetArms[arm] + int(hitsNum)
			}
		}
	}
	return target
}

func relpath(file, root string) string {
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		realRoot = root
	}
	realRoot = filepath.Clean(realRoot)

	realFile, err := filepath.EvalSymlinks(file)
	if err != nil {
		realFile = file
	}
	realFile = filepath.Clean(realFile)

	rel, err := filepath.Rel(realRoot, realFile)
	if err != nil {
		trimmed := strings.TrimPrefix(filepath.Clean(file), filepath.Clean(root)+"/")
		return trimmed
	}
	if rel == "." {
		return ""
	}
	return rel
}

func parseSite(site string, repoRoot string) (string, string, int, bool) {
	parts := strings.Split(site, ":")
	if len(parts) < 3 {
		return "", "", 0, false
	}
	lineStr := parts[len(parts)-1]
	methodName := parts[len(parts)-2]
	filePath := strings.Join(parts[:len(parts)-2], ":")

	line, err := strconv.Atoi(lineStr)
	if err != nil {
		return "", "", 0, false
	}

	return relpath(filePath, repoRoot), methodName, line, true
}

func extractSites(payload interface{}) []string {
	var sites []string
	switch val := payload.(type) {
	case []interface{}:
		for _, item := range val {
			if m, ok := item.(map[string]interface{}); ok {
				if s, ok := m["sites"]; ok {
					if arr, ok := s.([]interface{}); ok {
						for _, sVal := range arr {
							if str, ok := sVal.(string); ok {
								sites = append(sites, str)
							}
						}
					}
				}
			}
		}
	case map[string]interface{}:
		for _, v := range val {
			sites = append(sites, extractSites(v)...)
		}
	}
	return sites
}

func processDecomplexFacts(factsPath string, absRepo string) ([]DecomplexScoreEntry, []StateBranchDensityRow, error) {
	data, err := os.ReadFile(factsPath)
	if err != nil {
		return nil, nil, err
	}

	var raw map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, nil, err
	}

	// 1. Process detectors for Decomplex scores
	detectorsData, _ := raw["detectors"].(map[string]interface{})
	
	type methodKey struct {
		file   string
		method string
	}
	
	// Map to keep unique detectors for detectors field
	methodUniqueDetectors := make(map[methodKey]map[string]bool)
	// Slice to keep all findings (with duplicates)
	methodFindings := make(map[methodKey][]Finding)
	// Sort detector names alphabetically to match facts file key order
	var detectorNames []string
	for name := range detectorsData {
		detectorNames = append(detectorNames, name)
	}
	sort.Strings(detectorNames)
	for _, detectorName := range detectorNames {
		payload := detectorsData[detectorName]
		for _, site := range extractSites(payload) {
			relFile, methodName, _, ok := parseSite(site, absRepo)
			if !ok {
				continue
			}
			key := methodKey{file: relFile, method: methodName}
			
			if _, exists := methodUniqueDetectors[key]; !exists {
				methodUniqueDetectors[key] = make(map[string]bool)
			}
			methodUniqueDetectors[key][detectorName] = true
			
			methodFindings[key] = append(methodFindings[key], Finding{Type: detectorName})
		}
	}
	
	// Convert to DecomplexScoreEntry slice
	var decomplexScores []DecomplexScoreEntry
	for key, findingsList := range methodFindings {
		var detectors []string
		for d := range methodUniqueDetectors[key] {
			detectors = append(detectors, d)
		}
		sort.Strings(detectors)
		
		decomplexScores = append(decomplexScores, DecomplexScoreEntry{
			File:      key.file,
			Method:    key.method,
			Score:     len(detectors),
			Findings:  findingsList,
			Detectors: detectors,
		})
	}
	
	sort.Slice(decomplexScores, func(i, j int) bool {
		if decomplexScores[i].File != decomplexScores[j].File {
			return decomplexScores[i].File < decomplexScores[j].File
		}
		return decomplexScores[i].Method < decomplexScores[j].Method
	})

	// 2. Process state_branch_density
	var densityRows []StateBranchDensityRow
	if detectorsData != nil {
		if densityDataVal, ok := detectorsData["state_branch_density"]; ok {
			if densityArr, ok := densityDataVal.([]interface{}); ok {
				for _, entryVal := range densityArr {
					if entry, ok := entryVal.(map[string]interface{}); ok {
						fileStr, _ := entry["file"].(string)
						methodStr, _ := entry["method"].(string)
						scoreNum, _ := entry["score"].(float64)
						decisionsNum, _ := entry["decisions"].(float64)
						stateRefsArr, _ := entry["state_refs"].([]interface{})
						var stateRefs []string
						for _, refVal := range stateRefsArr {
							if rStr, ok := refVal.(string); ok {
								stateRefs = append(stateRefs, rStr)
							}
						}
						predicateStr, _ := entry["predicate"].(string)
						
						densityRows = append(densityRows, StateBranchDensityRow{
							File:      relpath(fileStr, absRepo),
							Method:    methodStr,
							Score:     scoreNum,
							Decisions: int(decisionsNum),
							At:        entry["at"],
							StateRefs: stateRefs,
							Predicate: predicateStr,
						})
					}
				}
			}
		}
	}
	
	sort.Slice(densityRows, func(i, j int) bool {
		if densityRows[i].File != densityRows[j].File {
			return densityRows[i].File < densityRows[j].File
		}
		return densityRows[i].Method < densityRows[j].Method
	})

	return decomplexScores, densityRows, nil
}

func parseKillRate(val interface{}) *float64 {
	if val == nil {
		return nil
	}
	text := fmt.Sprintf("%v", val)
	text = strings.TrimSuffix(text, "%")
	rate, err := strconv.ParseFloat(text, 64)
	if err != nil {
		return nil
	}
	if rate <= 1.0 {
		rate *= 100.0
	}
	return &rate
}

func normalizeFile(file string, repoRoot string) string {
	if file == "" {
		return ""
	}
	var abs string
	if filepath.IsAbs(file) {
		abs = filepath.Clean(file)
	} else {
		abs = filepath.Join(repoRoot, file)
	}
	realFile, err := filepath.EvalSymlinks(abs)
	if err != nil {
		realFile = abs
	}
	return cleanFile(relpath(realFile, repoRoot))
}

func cleanFile(file string) string {
	cleaned := strings.ReplaceAll(file, "\\", "/")
	cleaned = strings.TrimPrefix(cleaned, "./")
	return cleaned
}

func processMutationFacts(path string, absRepo string) (*MutationFactsOutput, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var raw map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	subjectsVal, ok := raw["subjects"]
	if !ok {
		subjectsVal = raw["subjects"]
	}
	subjectsArr, ok := subjectsVal.([]interface{})
	if !ok {
		return &MutationFactsOutput{Active: true, Subjects: []MutationFact{}}, nil
	}
	var subjects []MutationFact
	for _, itemVal := range subjectsArr {
		item, ok := itemVal.(map[string]interface{})
		if !ok {
			continue
		}
		fileStr, _ := item["file"].(string)
		methodStr, _ := item["method"].(string)
		gateStr, _ := item["gate_status"].(string)
		rate := parseKillRate(item["kill_rate"])
		normFile := normalizeFile(fileStr, absRepo)
		if normFile == "" || methodStr == "" {
			continue
		}
		subjects = append(subjects, MutationFact{
			File:       normFile,
			Method:     methodStr,
			KillRate:   rate,
			GateStatus: gateStr,
		})
	}
	return &MutationFactsOutput{Active: true, Subjects: subjects}, nil
}

func stringVal(item map[string]interface{}, keys ...string) string {
	for _, k := range keys {
		if v, ok := item[k]; ok {
			return fmt.Sprintf("%v", v)
		}
	}
	return ""
}

func intVal(item map[string]interface{}, keys ...string) int {
	for _, k := range keys {
		if v, ok := item[k]; ok {
			if f, ok := v.(float64); ok {
				return int(f)
			}
			if s, ok := v.(string); ok {
				if i, err := strconv.Atoi(s); err == nil {
					return i
				}
			}
		}
	}
	return 0
}

func hitFromMap(entry map[string]interface{}, line int, branchID string) Hit {
	testID := stringVal(entry, "test_id", "id")
	testType := stringVal(entry, "test_type", "type")
	mutStatus := stringVal(entry, "mutation_status", "mutant_status", "mutation")
	entryLine := intVal(entry, "line")
	if line != 0 {
		entryLine = line
	}
	entryBranchID := stringVal(entry, "branch_id")
	if branchID != "" {
		entryBranchID = branchID
	}
	return Hit{
		TestID:         testID,
		TestType:       testType,
		MutationStatus: mutStatus,
		Line:           entryLine,
		BranchID:       entryBranchID,
	}
}

func processTestExposureFacts(path string, absRepo string) (*TestExposurePayload, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var raw map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	payload := &TestExposurePayload{}
	if hitsVal, ok := raw["hits"]; ok {
		if hitsArr, ok := hitsVal.([]interface{}); ok {
			for _, entryVal := range hitsArr {
				entry, ok := entryVal.(map[string]interface{})
				if !ok {
					continue
				}
				fileStr := stringVal(entry, "file")
				normFile := normalizeFile(fileStr, absRepo)
				if normFile == "" {
					continue
				}
				method := stringVal(entry, "function", "method", "defn")
				hit := hitFromMap(entry, 0, "")
				if method != "" {
					payload.MethodHits = append(payload.MethodHits, MethodHitEntry{
						File:   normFile,
						Method: method,
						Hit:    hit,
					})
				}
				if hit.Line > 0 {
					payload.LineHits = append(payload.LineHits, LineHitEntry{
						File: normFile,
						Line: hit.Line,
						Hit:  hit,
					})
				}
				if hit.BranchID != "" || hit.Line > 0 {
					payload.BranchHits = append(payload.BranchHits, BranchHitEntry{
						File:     normFile,
						BranchID: hit.BranchID,
						Line:     hit.Line,
						Hit:      hit,
					})
				}
			}
		}
	}
	if filesVal, ok := raw["files"]; ok {
		if filesArr, ok := filesVal.([]interface{}); ok {
			for _, fileEntryVal := range filesArr {
				fileEntry, ok := fileEntryVal.(map[string]interface{})
				if !ok {
					continue
				}
				fileStr := stringVal(fileEntry, "file")
				normFile := normalizeFile(fileStr, absRepo)
				if normFile == "" {
					continue
				}
				if fnsVal, ok := fileEntry["functions"]; ok {
					if fnsArr, ok := fnsVal.([]interface{}); ok {
						for _, fnVal := range fnsArr {
							fn, ok := fnVal.(map[string]interface{})
							if !ok {
								continue
							}
							method := stringVal(fn, "name", "method", "function")
							if method == "" {
								continue
							}
							if testsVal, ok := fn["tests"]; ok {
								if testsArr, ok := testsVal.([]interface{}); ok {
									for _, testVal := range testsArr {
										if test, ok := testVal.(map[string]interface{}); ok {
											payload.MethodHits = append(payload.MethodHits, MethodHitEntry{
												File:   normFile,
												Method: method,
												Hit:    hitFromMap(test, 0, ""),
											})
										}
									}
								}
							}
						}
					}
				}
				if linesVal, ok := fileEntry["lines"]; ok {
					if linesArr, ok := linesVal.([]interface{}); ok {
						for _, lineEntryVal := range linesArr {
							lineEntry, ok := lineEntryVal.(map[string]interface{})
							if !ok {
								continue
							}
							line := intVal(lineEntry, "line")
							if line <= 0 {
								continue
							}
							if testsVal, ok := lineEntry["tests"]; ok {
								if testsArr, ok := testsVal.([]interface{}); ok {
									for _, testVal := range testsArr {
										if test, ok := testVal.(map[string]interface{}); ok {
											payload.LineHits = append(payload.LineHits, LineHitEntry{
												File: normFile,
												Line: line,
												Hit:  hitFromMap(test, line, ""),
											})
										}
									}
								}
							}
						}
					}
				}
				if branchesVal, ok := fileEntry["branches"]; ok {
					if branchesArr, ok := branchesVal.([]interface{}); ok {
						for _, branchEntryVal := range branchesArr {
							branchEntry, ok := branchEntryVal.(map[string]interface{})
							if !ok {
								continue
							}
							branchID := stringVal(branchEntry, "branch_id", "id")
							line := intVal(branchEntry, "line")
							if testsVal, ok := branchEntry["tests"]; ok {
								if testsArr, ok := testsVal.([]interface{}); ok {
									for _, testVal := range testsArr {
										if test, ok := testVal.(map[string]interface{}); ok {
											payload.BranchHits = append(payload.BranchHits, BranchHitEntry{
												File:     normFile,
												BranchID: branchID,
												Line:     line,
												Hit:      hitFromMap(test, line, branchID),
											})
										}
									}
								}
							}
						}
					}
				}
			}
		}
	}
	return payload, nil
}
