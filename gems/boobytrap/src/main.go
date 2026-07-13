package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"encoding/xml"
	"flag"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"runtime"
	"strings"
	"sync"
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
	DecomplexSyntax    []FactMineDoc           `json:"decomplex_syntax,omitempty"`
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

type NativeBranchArm struct {
	BranchID     string `json:"branch_id"`
	ArmID        string `json:"arm_id"`
	Kind         string `json:"kind"`
	Member       string `json:"member"`
	DecisionSpan []int  `json:"decision_span"`
	ArmSpan      []int  `json:"arm_span"`
	Hits         int    `json:"hits"`
}

type CoverageDataset struct {
	Files map[string]FileCoverage `json:"files"`
}

type FileCoverage struct {
	Lines      []*int                    `json:"lines"`
	Branches   map[string]map[string]int `json:"branches"`
	SourcePath string                    `json:"source_path"`
	BranchArms []NativeBranchArm         `json:"branch_arms"`
	Format     string                    `json:"format"`
	Language   string                    `json:"language"`
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
	var repoPath *string
	var covPath *string
	var decomplexFactsPath *string
	var mutationPath *string
	var testExposurePath *string
	var staticFilesPath *string
	var fixRePat *string
	var output *string
	var jsonPath *string
	var top *int
	var only stringSlice
	var exclude stringSlice
	var files *string
	var lineageDBPath *string
	var lineageCommand *string
	var parseCoverageOnly *bool

	isReportSubcommand := len(os.Args) >= 2 && os.Args[1] == "report"

	if isReportSubcommand {
		fs := flag.NewFlagSet("report", flag.ExitOnError)
		repoPath = fs.String("repo", ".", "Path to repository")
		covPath = fs.String("coverage", "coverage/.resultset.json", "Path to coverage JSON")
		decomplexFactsPath = fs.String("decomplex-facts", "", "Path to decomplex facts JSON")
		mutationPath = fs.String("mutation", "", "Path to mutation facts JSON")
		testExposurePath = fs.String("test-exposure", "", "Path to test exposure facts JSON")
		staticFilesPath = fs.String("static-files-file", "", "Path to JSON file containing list of static files to analyze")
		fixRePat = fs.String("fix-re", `\b(fix(es|ed)?|bug\s*fix|close[sd]?)\b`, "Regex for fix commits")
		output = fs.String("output", "", "Path to output Markdown file")
		jsonPath = fs.String("json", "", "Path to output SARIF JSON file")
		top = fs.Int("top", 40, "Limit ranking table size")
		fs.Var(&only, "only", "restrict ranking to path prefix")
		fs.Var(&exclude, "exclude", "exclude glob pattern")
		files = fs.String("files", "", "restrict ranking to exact source files")
		lineageDBPath = fs.String("lineage-db", "", "Path to lineage SQLite database")
		lineageCommand = fs.String("lineage-command", "", "Custom lineage summary command")
		parseCoverageOnly = fs.Bool("parse-coverage-only", false, "Parse coverage and dump normalized JSON to stdout, then exit")

		fs.Parse(os.Args[2:])
	} else {
		if len(os.Args) >= 2 && (os.Args[1] == "-h" || os.Args[1] == "--help") {
			fmt.Println("Usage: boobytrap report [options]")
			flag.PrintDefaults()
			os.Exit(0)
		}

		repoPath = flag.String("repo", "", "Path to repository")
		covPath = flag.String("coverage", "", "Path to coverage JSON")
		decomplexFactsPath = flag.String("decomplex-facts", "", "Path to decomplex facts JSON")
		mutationPath = flag.String("mutation", "", "Path to mutation facts JSON")
		testExposurePath = flag.String("test-exposure", "", "Path to test exposure facts JSON")
		staticFilesPath = flag.String("static-files-file", "", "Path to JSON file containing list of static files to analyze")
		fixRePat = flag.String("fix-re", `\b(fix(es|ed)?|bug\s*fix|close[sd]?)\b`, "Regex for fix commits")
		lineageDBPath = flag.String("lineage-db", "", "Path to lineage SQLite database")
		lineageCommand = flag.String("lineage-command", "", "Custom lineage summary command")
		parseCoverageOnly = flag.Bool("parse-coverage-only", false, "Parse coverage and dump normalized JSON to stdout, then exit")
		flag.Parse()
	}

	if *parseCoverageOnly {
		if *covPath == "" {
			fmt.Fprintln(os.Stderr, "Error: --coverage is required for --parse-coverage-only")
			os.Exit(1)
		}
		absRepo := "."
		if *repoPath != "" {
			var err error
			absRepo, err = filepath.Abs(*repoPath)
			if err != nil {
				absRepo = "."
			}
		}
		covDataset, _, err := processCoverage(*covPath, absRepo)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error processing coverage: %v\n", err)
			os.Exit(1)
		}
		enc := json.NewEncoder(os.Stdout)
		if err := enc.Encode(covDataset); err != nil {
			fmt.Fprintf(os.Stderr, "Error encoding output: %v\n", err)
			os.Exit(1)
		}
		os.Exit(0)
	}

	if *repoPath == "" {
		fmt.Fprintln(os.Stderr, "Error: --repo is required")
		os.Exit(1)
	}

	absRepo, err := filepath.Abs(*repoPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error resolving repo path: %v\n", err)
		os.Exit(1)
	}

	if isReportSubcommand {
		srcFiles, err := getSourceFilesFromRuby(absRepo, only, *files, exclude)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error getting source files: %v\n", err)
			os.Exit(1)
		}

		tmpStaticFile, err := os.CreateTemp("", "boobytrap-static-*.json")
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error creating temp file: %v\n", err)
			os.Exit(1)
		}
		defer os.Remove(tmpStaticFile.Name())

		srcFilesJSON, _ := json.Marshal(srcFiles)
		if _, err := tmpStaticFile.Write(srcFilesJSON); err != nil {
			fmt.Fprintf(os.Stderr, "Error writing to temp file: %v\n", err)
			os.Exit(1)
		}
		tmpStaticFile.Close()

		*staticFilesPath = tmpStaticFile.Name()
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

	// 6. Process Static Files if supplied
	var staticGaps map[string]FileGap
	var staticDocs []FactMineDoc
	if *staticFilesPath != "" {
		staticGaps, staticDocs, err = processStaticGaps(*staticFilesPath, absRepo, covDataset)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error processing static gaps: %v\n", err)
			os.Exit(1)
		}
	}

	// Merge static gaps into gaps (coverage takes precedence)
	if len(staticGaps) > 0 {
		if gaps == nil {
			gaps = make(map[string]FileGap)
		}
		for k, v := range staticGaps {
			if _, exists := gaps[k]; !exists {
				gaps[k] = v
			}
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
		DecomplexSyntax:    staticDocs,
	}

	if isReportSubcommand {
		var lineageDBPathStr string
		if lineageDBPath != nil {
			lineageDBPathStr = *lineageDBPath
		}
		var lineageCommandStr string
		if lineageCommand != nil {
			lineageCommandStr = *lineageCommand
		}

		var filesSlice []string
		if *files != "" {
			filesSlice = strings.Split(*files, ",")
		}

		ranked, unmeasured := rankHotspots(scores, gaps)

		var filteredRanked []HotspotRow
		for _, r := range ranked {
			if inScope(r.File, only, filesSlice) {
				filteredRanked = append(filteredRanked, r)
			}
		}
		var filteredUnmeasured []UnmeasuredEntry
		for _, u := range unmeasured {
			if inScope(u.File, only, filesSlice) {
				filteredUnmeasured = append(filteredUnmeasured, u)
			}
		}

		decomplexMap := make(map[MethodKey]DecomplexScoreEntry)
		for _, ds := range decomplexScores {
			decomplexMap[MethodKey{File: ds.File, Method: ds.Method}] = ds
		}

		var methodGaps []MethodGapRow
		var staticFiles []string
		if *staticFilesPath != "" {
			data, err := os.ReadFile(*staticFilesPath)
			if err == nil {
				json.Unmarshal(data, &staticFiles)
			}
		}

		haveCov := covDataset != nil && len(covDataset.Files) > 0
		if haveCov {
			methodGaps = computeMethodGapsFromCoverage(covDataset, absRepo, decomplexMap)
		} else {
			methodGaps = computeMethodGapsFromStatic(staticFiles, absRepo, decomplexMap, staticDocs)
		}

		fixMax := 0.0
		for _, s := range scores {
			if s > fixMax {
				fixMax = s
			}
		}
		if fixMax <= 0.0 {
			fixMax = 1.0
		}

		mutationActive := mutationOutput != nil && mutationOutput.Active
		mutationMap := make(map[MethodKey]MutationFact)
		if mutationActive {
			groupedMutation := make(map[string][]MutationFact)
			for _, mf := range mutationOutput.Subjects {
				key := MethodKey{File: mf.File, Method: mf.Method}
				mutationMap[key] = mf
				if mf.File != "\x00global" && mf.Method != "*" && !strings.HasSuffix(mf.Method, "*") {
					groupedMutation[mf.Method] = append(groupedMutation[mf.Method], mf)
				}
			}
			for method, candidates := range groupedMutation {
				seen := make(map[MethodKey]bool)
				var unique []MutationFact
				for _, c := range candidates {
					k := MethodKey{File: c.File, Method: c.Method}
					if !seen[k] {
						seen[k] = true
						unique = append(unique, c)
					}
				}
				if len(unique) == 1 {
					keyGlobal := MethodKey{File: "\x00global", Method: method}
					mutationMap[keyGlobal] = unique[0]
				}
			}
		}

		testExposureActive := testExposureOutput != nil

		for i := range methodGaps {
			row := &methodGaps[i]
			fixNorm := math.Round((scores[row.File]/fixMax)*1000) / 1000
			row.FixNorm = fixNorm
			row.Risk = row.Risk * (1.0 + fixNorm)

			structuralScore := float64(row.DecomplexScore) + float64(row.StateWrites) + (float64(row.UncoveredBranches) / 2.0)

			if mutationActive {
				row.VerificationStatus = "no mutation"
				mf := lookupMutationFact(mutationMap, row.File, row.Name)
				if mf != nil {
					row.VerificationStatus = mutationSummary(mf.KillRate, mf.GateStatus)
					row.MutationKillRate = mf.KillRate
					row.MutationGateStatus = mf.GateStatus
				}
				row.RiskProfile = mutationProfile(mf, true, structuralScore, fixNorm, row.LineGap)
				row.VerificationMultiplier = mutationRiskMultiplier(mf, true, structuralScore, fixNorm, row.LineGap)
				row.Risk = row.Risk * row.VerificationMultiplier
			}

			if testExposureActive {
				agg := buildTestExposureAggregated(testExposureOutput, row.File, row.Name, row.FirstLine, row.LastLine)
				row.TestExposureStatus = testExposureSummary(agg)
				row.TestExposureProfile = testExposureProfile(agg, true)

				allHits := append([]TestExposureHit{}, agg.FunctionTests...)
				for _, hList := range agg.LineTests {
					allHits = append(allHits, hList...)
				}
				for _, hList := range agg.BranchTests {
					allHits = append(allHits, hList...)
				}
				row.DistinctTestCount = len(uniqueTestIDs(allHits))
				testedLines := 0
				for _, hList := range agg.LineTests {
					if len(hList) > 0 {
						testedLines++
					}
				}
				row.TestedLineCount = testedLines
				testedBranches := 0
				for _, hList := range agg.BranchTests {
					if len(hList) > 0 {
						testedBranches++
					}
				}
				row.TestedBranchCount = testedBranches

				mutantVerified := make(map[string]bool)
				mutantKilled := make(map[string]bool)
				for _, h := range allHits {
					if isHitMutation(h) {
						mutantVerified[h.TestID] = true
					}
					if isHitKilled(h) {
						mutantKilled[h.TestID] = true
					}
				}
				row.MutantVerifiedTestCount = len(mutantVerified)
				row.MutantKilledTestCount = len(mutantKilled)

				row.TestExposureMultiplier = testExposureMultiplier(agg, true, structuralScore, fixNorm, row.LineGap)
				row.Risk = row.Risk * row.TestExposureMultiplier
			}
			row.Risk = math.Round(row.Risk*10000) / 10000
		}

		lineageIndex := loadLineage(lineageDBPathStr, absRepo, only, *top, lineageCommandStr)
		if lineageIndex.Status == "ok" {
			lineageMax := 0.0
			for _, u := range lineageIndex.Units {
				if u.RiskScore > lineageMax {
					lineageMax = u.RiskScore
				}
			}
			if lineageMax <= 0.0 {
				lineageMax = 1.0
			}

			for i := range methodGaps {
				row := &methodGaps[i]
				key := MethodKey{File: row.File, Method: row.Name}
				if u, exists := lineageIndex.Index[key]; exists {
					row.LineageScore = u.RiskScore
					row.LineageFixes = u.Fixes
					row.LineageChanges = u.Changes
					row.LineageMoves = u.Moves
					lineageNorm := u.RiskScore / lineageMax
					row.Risk = row.Risk * (1.0 + lineageNorm)

					if !testExposureActive && u.CurrentDistinctTests > 0 {
						row.TestExposureStatus = lineageTestExposureStatus(u)
						row.TestExposureProfile = lineageExposureProfile(u)
						row.DistinctTestCount = u.CurrentDistinctTests
						row.MutantVerifiedTestCount = u.CurrentMutantVerifiedTests
						row.MutantKilledTestCount = u.CurrentMutantKilledTests
						structuralScore := float64(row.DecomplexScore) + float64(row.StateWrites) + (float64(row.UncoveredBranches) / 2.0)
						row.TestExposureMultiplier = lineageExposureMultiplier(u, true, structuralScore, row.FixNorm, row.LineGap)
						row.Risk = row.Risk * row.TestExposureMultiplier
					}
					row.Risk = math.Round(row.Risk*10000) / 10000
				}
			}
		}

		stateBranchHotspotsList := buildStateBranchHotspots(densityRows, methodGaps, scores, fixMax, gaps)

		var filteredBlast []BlastRow
		for _, b := range blast {
			absPath := filepath.Join(absRepo, b.File)
			if _, err := os.Stat(absPath); err != nil {
				continue
			}
			if inScope(b.File, only, filesSlice) {
				filteredBlast = append(filteredBlast, b)
			}
		}

		sort.Slice(methodGaps, func(i, j int) bool {
			if methodGaps[i].Risk != methodGaps[j].Risk {
				return methodGaps[i].Risk > methodGaps[j].Risk
			}
			if methodGaps[i].MissedLines != methodGaps[j].MissedLines {
				return methodGaps[i].MissedLines > methodGaps[j].MissedLines
			}
			if methodGaps[i].File != methodGaps[j].File {
				return methodGaps[i].File < methodGaps[j].File
			}
			return methodGaps[i].FirstLine < methodGaps[j].FirstLine
		})

		covLabel := ""
		if *covPath != "" {
			covLabel = filepath.Base(*covPath)
		}

		md := generateMarkdown(
			absRepo,
			only,
			filesSlice,
			len(events),
			filteredRanked,
			filteredUnmeasured,
			methodGaps,
			stateBranchHotspotsList,
			filteredBlast,
			lineageIndex,
			haveCov,
			covLabel,
			mutationActive,
			filepath.Base(*mutationPath),
			testExposureActive,
			filepath.Base(*testExposurePath),
			*top,
		)

		if *output != "" {
			if err := os.WriteFile(*output, []byte(md), 0644); err != nil {
				fmt.Fprintf(os.Stderr, "Error writing output report: %v\n", err)
				os.Exit(1)
			}
		} else {
			fmt.Print(md)
		}

		if *jsonPath != "" {
			sarif := generateSarif(
				absRepo,
				only,
				filesSlice,
				len(events),
				filteredRanked,
				filteredUnmeasured,
				methodGaps,
				stateBranchHotspotsList,
				filteredBlast,
				lineageIndex,
				haveCov,
				covLabel,
				mutationActive,
				filepath.Base(*mutationPath),
				testExposureActive,
				filepath.Base(*testExposurePath),
				*top,
			)
			if err := os.WriteFile(*jsonPath, []byte(sarif), 0644); err != nil {
				fmt.Fprintf(os.Stderr, "Error writing json report: %v\n", err)
				os.Exit(1)
			}
		}

		os.Exit(0)
	} else {
		enc := json.NewEncoder(os.Stdout)
		if err := enc.Encode(out); err != nil {
			fmt.Fprintf(os.Stderr, "Error encoding output: %v\n", err)
			os.Exit(1)
		}
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

type NilKillBranchCoverage struct {
	Format string `json:"format"`
	Root   string `json:"root"`
	Files  []struct {
		Path     string `json:"path"`
		File     string `json:"file"`
		Filename string `json:"filename"`
		Language string `json:"language"`
		Lines    interface{} `json:"lines"` // can be array or map
		Arms     []struct {
			BranchID     string      `json:"branch_id"`
			ArmID        string      `json:"arm_id"`
			Kind         string      `json:"kind"`
			Member       string      `json:"member"`
			Label        string      `json:"label"`
			Arm          string      `json:"arm"`
			DecisionSpan interface{} `json:"decision_span"`
			ArmSpan      interface{} `json:"arm_span"`
			Span         interface{} `json:"span"`
			Hits         interface{} `json:"hits"`
			Count        interface{} `json:"count"`
			SampleCount  interface{} `json:"sample_count"`
		} `json:"arms"`
	} `json:"files"`
}

type KcovCodecov struct {
	Coverage map[string]map[string]interface{} `json:"coverage"`
}

type NilKillJsonlLine struct {
	Path  string      `json:"path"`
	Lines interface{} `json:"lines"`
}

func parseIntList(val interface{}) []int {
	if val == nil {
		return nil
	}
	arr, ok := val.([]interface{})
	if !ok {
		return nil
	}
	res := make([]int, 0, len(arr))
	for _, item := range arr {
		if num, ok := item.(float64); ok {
			res = append(res, int(num))
		}
	}
	return res
}

func parseInt(val interface{}) int {
	if val == nil {
		return 0
	}
	if num, ok := val.(float64); ok {
		return int(num)
	}
	return 0
}

func parseNilKillLines(val interface{}) []*int {
	if val == nil {
		return nil
	}
	if arr, ok := val.([]interface{}); ok {
		maxLine := 0
		for _, item := range arr {
			if num, ok := item.(float64); ok {
				lineNum := int(num)
				if lineNum > maxLine {
					maxLine = lineNum
				}
			}
		}
		res := make([]*int, maxLine)
		for _, item := range arr {
			if num, ok := item.(float64); ok {
				lineNum := int(num)
				if lineNum > 0 {
					hits := 1
					res[lineNum-1] = &hits
				}
			}
		}
		return res
	}
	if m, ok := val.(map[string]interface{}); ok {
		maxLine := 0
		for k := range m {
			if lineNum, err := strconv.Atoi(k); err == nil {
				if lineNum > maxLine {
					maxLine = lineNum
				}
			}
		}
		res := make([]*int, maxLine)
		for k, hitVal := range m {
			if lineNum, err := strconv.Atoi(k); err == nil {
				if lineNum > 0 {
					hits := parseInt(hitVal)
					res[lineNum-1] = &hits
				}
			}
		}
		return res
	}
	return nil
}

func detectLanguage(path string) string {
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".rb":
		return "ruby"
	case ".py":
		return "python"
	case ".js", ".jsx", ".mjs", ".cjs":
		return "javascript"
	case ".ts", ".tsx":
		return "typescript"
	case ".go":
		return "go"
	case ".rs":
		return "rust"
	case ".zig":
		return "zig"
	case ".c", ".h":
		return "c"
	case ".cpp", ".cc", ".cxx", ".hh", ".hpp", ".hxx":
		return "cpp"
	case ".cs":
		return "csharp"
	case ".java":
		return "java"
	case ".kt", ".kts":
		return "kotlin"
	case ".swift":
		return "swift"
	case ".php":
		return "php"
	case ".lua":
		return "lua"
	}
	return ""
}

func parseGoCoverprofile(data []byte, repo string, files map[string]FileCoverage) error {
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "mode:") {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) != 3 {
			continue
		}
		covPart := parts[0]
		countVal, err := strconv.Atoi(parts[2])
		if err != nil {
			continue
		}
		colonIdx := strings.LastIndex(covPart, ":")
		if colonIdx == -1 {
			continue
		}
		filePath := covPart[:colonIdx]
		rangePart := covPart[colonIdx+1:]

		absFile := filePath
		if !filepath.IsAbs(filePath) {
			candidate := filepath.Join(repo, filePath)
			if _, err := os.Stat(candidate); err == nil {
				absFile = filepath.Clean(candidate)
			} else {
				parts := strings.Split(filePath, "/")
				resolved := false
				for i := 1; i < len(parts); i++ {
					sub := filepath.Join(parts[i:]...)
					candidate = filepath.Join(repo, sub)
					if _, err := os.Stat(candidate); err == nil {
						absFile = filepath.Clean(candidate)
						resolved = true
						break
					}
				}
				if !resolved {
					absFile = filepath.Clean(filepath.Join(repo, filePath))
				}
			}
		}

		commaIdx := strings.Index(rangePart, ",")
		if commaIdx == -1 {
			continue
		}
		startPart := rangePart[:commaIdx]
		endPart := rangePart[commaIdx+1:]

		startDot := strings.Index(startPart, ".")
		endDot := strings.Index(endPart, ".")
		if startDot == -1 || endDot == -1 {
			continue
		}
		startLine, err := strconv.Atoi(startPart[:startDot])
		if err != nil {
			continue
		}
		endLine, err := strconv.Atoi(endPart[:endDot])
		if err != nil {
			continue
		}

		dst, exists := files[absFile]
		if !exists {
			dst = FileCoverage{
				Lines:      []*int{},
				Branches:   make(map[string]map[string]int),
				SourcePath: relpathNoEval(absFile, repo),
				Format:     "go_coverprofile",
				Language:   "go",
			}
		}

		for len(dst.Lines) < endLine {
			dst.Lines = append(dst.Lines, nil)
		}

		for l := startLine; l <= endLine; l++ {
			if dst.Lines[l-1] == nil {
				val := countVal
				dst.Lines[l-1] = &val
			} else {
				*dst.Lines[l-1] = maxInt(*dst.Lines[l-1], countVal)
			}
		}
		files[absFile] = dst
	}
	return scanner.Err()
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func parseNilKillJsonl(data []byte, repo string, files map[string]FileCoverage) error {
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var item NilKillJsonlLine
		if err := json.Unmarshal(line, &item); err != nil {
			return err
		}
		if item.Path == "" {
			continue
		}
		absFile := item.Path
		if !filepath.IsAbs(absFile) {
			absFile = filepath.Join(repo, absFile)
		}
		absFile = filepath.Clean(absFile)

		dst, exists := files[absFile]
		if !exists {
			dst = FileCoverage{
				Lines:      []*int{},
				Branches:   make(map[string]map[string]int),
				SourcePath: relpathNoEval(absFile, repo),
				Format:     "nil_kill_jsonl",
				Language:   detectLanguage(absFile),
			}
		}

		lines := parseNilKillLines(item.Lines)
		dst.Lines = mergeLines(dst.Lines, convertLinesToInterface(lines))
		files[absFile] = dst
	}
	return nil
}

func convertLinesToInterface(lines []*int) []interface{} {
	res := make([]interface{}, len(lines))
	for i, v := range lines {
		if v != nil {
			res[i] = float64(*v)
		}
	}
	return res
}

func parseKcovCodecov(data []byte, repo string, files map[string]FileCoverage) error {
	var kcov KcovCodecov
	if err := json.Unmarshal(data, &kcov); err != nil {
		return err
	}
	for file, lineHits := range kcov.Coverage {
		absFile := file
		if !filepath.IsAbs(file) {
			absFile = filepath.Join(repo, file)
		}
		absFile = filepath.Clean(absFile)

		dst, exists := files[absFile]
		if !exists {
			dst = FileCoverage{
				Lines:      []*int{},
				Branches:   make(map[string]map[string]int),
				SourcePath: relpathNoEval(absFile, repo),
				Format:     "kcov_codecov",
				Language:   detectLanguage(absFile),
			}
		}

		for lineStr, hitsVal := range lineHits {
			lineNum, err := strconv.Atoi(lineStr)
			if err != nil || lineNum <= 0 {
				continue
			}
			hits := parseInt(hitsVal)
			for len(dst.Lines) < lineNum {
				dst.Lines = append(dst.Lines, nil)
			}
			if dst.Lines[lineNum-1] == nil {
				dst.Lines[lineNum-1] = &hits
			} else {
				*dst.Lines[lineNum-1] += hits
			}
		}
		files[absFile] = dst
	}
	return nil
}

func parseNilKillBranchCoverage(data []byte, repo string, files map[string]FileCoverage) error {
	var nk NilKillBranchCoverage
	if err := json.Unmarshal(data, &nk); err != nil {
		return err
	}
	covRoot := nk.Root
	if covRoot == "" {
		covRoot = repo
	} else if !filepath.IsAbs(covRoot) {
		covRoot = filepath.Join(repo, covRoot)
	}
	covRoot = filepath.Clean(covRoot)

	for _, entry := range nk.Files {
		rel := entry.Path
		if rel == "" {
			rel = entry.File
		}
		if rel == "" {
			rel = entry.Filename
		}
		if rel == "" {
			continue
		}

		absFile := rel
		if !filepath.IsAbs(rel) {
			candidate := filepath.Clean(filepath.Join(covRoot, rel))
			if _, err := os.Stat(candidate); err == nil {
				absFile = candidate
			} else {
				absFile = filepath.Clean(filepath.Join(repo, rel))
			}
		}

		dst, exists := files[absFile]
		if !exists {
			dst = FileCoverage{
				Lines:      []*int{},
				Branches:   make(map[string]map[string]int),
				SourcePath: relpathNoEval(absFile, repo),
				Format:     "nil_kill_branch",
				Language:   entry.Language,
			}
		}
		if dst.Language == "" {
			dst.Language = detectLanguage(absFile)
		}

		lines := parseNilKillLines(entry.Lines)
		dst.Lines = mergeLines(dst.Lines, convertLinesToInterface(lines))

		for _, arm := range entry.Arms {
			armSpan := parseIntList(arm.ArmSpan)
			if len(armSpan) == 0 {
				armSpan = parseIntList(arm.Span)
			}
			decisionSpan := parseIntList(arm.DecisionSpan)
			if len(armSpan) != 4 || len(decisionSpan) != 4 {
				continue
			}

			hits := 0
			if arm.Hits != nil {
				hits = parseInt(arm.Hits)
			} else if arm.Count != nil {
				hits = parseInt(arm.Count)
			} else if arm.SampleCount != nil {
				hits = parseInt(arm.SampleCount)
			}

			kind := arm.Kind
			if kind == "" {
				kind = "branch"
			}
			member := arm.Member
			if member == "" {
				member = arm.Label
			}
			if member == "" {
				member = arm.Arm
			}

			dst.BranchArms = append(dst.BranchArms, NativeBranchArm{
				BranchID:     arm.BranchID,
				ArmID:        arm.ArmID,
				Kind:         kind,
				Member:       member,
				DecisionSpan: decisionSpan,
				ArmSpan:      armSpan,
				Hits:         hits,
			})
		}

		files[absFile] = dst
	}
	return nil
}

type CoberturaLine struct {
	Number int `xml:"number,attr"`
	Hits   int `xml:"hits,attr"`
}

type CoberturaClass struct {
	Filename string          `xml:"filename,attr"`
	Lines    []CoberturaLine `xml:"lines>line"`
}

type CoberturaPackage struct {
	Classes []CoberturaClass `xml:"classes>class"`
}

type CoberturaCoverage struct {
	XMLName  xml.Name           `xml:"coverage"`
	Sources  []string           `xml:"sources>source"`
	Packages []CoberturaPackage `xml:"packages>package"`
}

func processCoverage(covPath, repo string) (*CoverageDataset, map[string]FileGap, error) {
	files := make(map[string]FileCoverage)
	paths := filepath.SplitList(covPath)

	for _, path := range paths {
		if path == "" {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, nil, err
		}

		trimmed := bytes.TrimSpace(data)
		if bytes.HasPrefix(trimmed, []byte("mode:")) {
			if err := parseGoCoverprofile(data, repo, files); err != nil {
				return nil, nil, err
			}
		} else if bytes.HasPrefix(trimmed, []byte("<")) {
			var xmlCov CoberturaCoverage
			if err := xml.Unmarshal(data, &xmlCov); err != nil {
				return nil, nil, err
			}
			for _, pkg := range xmlCov.Packages {
				for _, class := range pkg.Classes {
					filename := class.Filename
					if filename == "" {
						continue
					}
					absFile := filename
					if !filepath.IsAbs(filename) {
						resolved := false
						for _, source := range xmlCov.Sources {
							candidate := source
							if !filepath.IsAbs(source) {
								candidate = filepath.Join(repo, source)
							}
							candidate = filepath.Join(candidate, filename)
							if _, err := os.Stat(candidate); err == nil {
								absFile = filepath.Clean(candidate)
								resolved = true
								break
							}
						}
						if !resolved {
							absFile = filepath.Clean(filepath.Join(repo, filename))
						}
					}

					dst, exists := files[absFile]
					if !exists {
						dst = FileCoverage{
							Lines:      []*int{},
							Branches:   make(map[string]map[string]int),
							SourcePath: relpathNoEval(absFile, repo),
							Format:     "kcov_cobertura",
							Language:   detectLanguage(absFile),
						}
					}

					for _, line := range class.Lines {
						number := line.Number
						if number <= 0 {
							continue
						}
						for len(dst.Lines) < number {
							dst.Lines = append(dst.Lines, nil)
						}
						hits := line.Hits
						if dst.Lines[number-1] == nil {
							dst.Lines[number-1] = &hits
						} else {
							*dst.Lines[number-1] += hits
						}
					}
					files[absFile] = dst
				}
			}
		} else {
			isJsonl := strings.HasSuffix(strings.ToLower(path), ".jsonl") || (len(trimmed) > 0 && trimmed[0] != '{')
			if isJsonl {
				if err := parseNilKillJsonl(data, repo, files); err != nil {
					return nil, nil, err
				}
			} else {
				var raw map[string]interface{}
				if err := json.Unmarshal(data, &raw); err != nil {
					return nil, nil, err
				}

				if format, ok := raw["format"].(string); ok && format == "nil-kill.branch-coverage" {
					if err := parseNilKillBranchCoverage(data, repo, files); err != nil {
						return nil, nil, err
					}
				} else if isPythonCoverageJson(raw) {
					if err := parsePythonCoverageJson(data, repo, files); err != nil {
						return nil, nil, err
					}
				} else {
					isKcov := false
					if _, ok := raw["coverage"]; ok {
						if covMap, ok := raw["coverage"].(map[string]interface{}); ok {
							for _, v := range covMap {
								if linesMap, ok := v.(map[string]interface{}); ok {
									for k := range linesMap {
										if _, err := strconv.Atoi(k); err == nil {
											isKcov = true
											break
										}
									}
								}
								break
							}
						}
					}

					if isKcov {
						if err := parseKcovCodecov(data, repo, files); err != nil {
							return nil, nil, err
						}
					} else {
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

								absFile := file
								if !filepath.IsAbs(file) {
									absFile = filepath.Join(repo, file)
								}
								absFile = filepath.Clean(absFile)

								dst, exists := files[absFile]
								if !exists {
									dst = FileCoverage{
										Lines:      []*int{},
										Branches:   make(map[string]map[string]int),
										SourcePath: relpathNoEval(absFile, repo),
										Format:     "simplecov",
										Language:   detectLanguage(absFile),
									}
								}

								if linesVal, ok := covData["lines"]; ok {
									if linesArr, ok := linesVal.([]interface{}); ok {
										dst.Lines = mergeLines(dst.Lines, linesArr)
									}
								}

								if branchesVal, ok := covData["branches"]; ok {
									if branchesMap, ok := branchesVal.(map[string]interface{}); ok {
										dst.Branches = mergeBranches(dst.Branches, branchesMap)
									}
								}

								files[absFile] = dst
							}
						}
					}
				}
			}
		}
	}

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
				gaps[relpathNoEval(absFile, repo)] = FileGap{
					Total:     total,
					Uncovered: uncov,
					Gap:       float64(uncov) / float64(total),
				}
			}
		} else if len(cov.BranchArms) > 0 {
			total := 0
			uncov := 0
			for _, arm := range cov.BranchArms {
				total++
				if arm.Hits == 0 {
					uncov++
				}
			}
			if total > 0 {
				gaps[relpathNoEval(absFile, repo)] = FileGap{
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

func relpathNoEval(file, root string) string {
	absRoot, err := filepath.Abs(root)
	if err != nil {
		absRoot = root
	}
	absFile, err := filepath.Abs(file)
	if err != nil {
		absFile = file
	}
	rel, err := filepath.Rel(filepath.Clean(absRoot), filepath.Clean(absFile))
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

type FactMineOutput struct {
	Documents []FactMineDoc `json:"documents"`
}

type FactMineDoc struct {
	File       string            `json:"file"`
	Language   string            `json:"language"`
	BranchArms []json.RawMessage `json:"branch_arms"`
}

func processStaticGaps(staticFilesFile string, absRepo string, covDataset *CoverageDataset) (map[string]FileGap, []FactMineDoc, error) {
	data, err := os.ReadFile(staticFilesFile)
	if err != nil {
		return nil, nil, err
	}
	var allFiles []string
	if err := json.Unmarshal(data, &allFiles); err != nil {
		return nil, nil, err
	}
	if len(allFiles) == 0 {
		return nil, nil, nil
	}
	var files []string
	for _, f := range allFiles {
		abs := f
		if !filepath.IsAbs(f) {
			abs = filepath.Join(absRepo, f)
		}
		abs = filepath.Clean(abs)
		covered := false
		if covDataset != nil && covDataset.Files != nil {
			if _, ok := covDataset.Files[abs]; ok {
				covered = true
			}
		}
		if !covered {
			files = append(files, f)
		}
	}
	if len(files) == 0 {
		return nil, nil, nil
	}
	bin := findFactMineRustBinary(absRepo)
	if _, err := os.Stat(bin); err != nil {
		return nil, nil, nil
	}
	filesByLang := make(map[string][]string)
	for _, f := range files {
		lang := languageFor(f)
		filesByLang[lang] = append(filesByLang[lang], f)
	}
	gaps := make(map[string]FileGap)
	var allDocs []FactMineDoc
	var mu sync.Mutex
	var wg sync.WaitGroup

	numCPU := runtime.NumCPU()
	if numCPU > 8 {
		numCPU = 8
	}
	sem := make(chan struct{}, numCPU)

	for lang, langFiles := range filesByLang {
		if lang == "generic" {
			continue
		}
		for i := 0; i < len(langFiles); i += 1000 {
			end := i + 1000
			if end > len(langFiles) {
				end = len(langFiles)
			}
			chunk := langFiles[i:end]

			wg.Add(1)
			go func(l string, filesSlice []string) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()

				var absSlice []string
				for _, f := range filesSlice {
					absSlice = append(absSlice, filepath.Join(absRepo, f))
				}

				args := append([]string{"syntax-facts", "--language", l}, absSlice...)
				cmd := exec.Command(bin, args...)
				var stdout bytes.Buffer
				var stderr bytes.Buffer
				cmd.Stdout = &stdout
				cmd.Stderr = &stderr

				if err := cmd.Run(); err != nil {
					if os.Getenv("BOOBYTRAP_DEBUG") != "" {
						fmt.Fprintf(os.Stderr, "Go helper batch_parse failed for %s slice: %v, stderr: %s\n", l, err, stderr.String())
					}
					return
				}

				var fmOut FactMineOutput
				if err := json.Unmarshal(stdout.Bytes(), &fmOut); err != nil {
					return
				}

				mu.Lock()
				defer mu.Unlock()
				for _, doc := range fmOut.Documents {
					allDocs = append(allDocs, doc)
					total := len(doc.BranchArms)
					if total > 0 {
						rel := relpathNoEval(doc.File, absRepo)
						gaps[rel] = FileGap{
							Total:     total,
							Uncovered: total,
							Gap:       1.0,
						}
					}
				}
			}(lang, chunk)
		}
	}
	wg.Wait()
	return gaps, allDocs, nil
}

func findFactMineRustBinary(repoRoot string) string {
	if envBin := os.Getenv("FACT_MINE_RUST_BINARY"); envBin != "" {
		return envBin
	}
	sibling := filepath.Join(repoRoot, "gems/fact-mine/target/release/fact-mine-rust")
	if _, err := os.Stat(sibling); err == nil {
		return sibling
	}
	return "fact-mine-rust"
}

func languageFor(file string) string {
	switch strings.ToLower(filepath.Ext(file)) {
	case ".rb":
		return "ruby"
	case ".py":
		return "python"
	case ".js":
		return "javascript"
	case ".ts":
		return "typescript"
	case ".go":
		return "go"
	case ".rs":
		return "rust"
	case ".zig":
		return "zig"
	case ".c":
		return "c"
	case ".cpp":
		return "cpp"
	case ".cs":
		return "csharp"
	case ".kt":
		return "kotlin"
	default:
		return "generic"
	}
}

type stringSlice []string

func (s *stringSlice) String() string {
	return strings.Join(*s, ",")
}

func (s *stringSlice) Set(value string) error {
	*s = append(*s, value)
	return nil
}

func getSourceFilesFromRuby(repo string, only []string, files string, exclude []string) ([]string, error) {
	inlineScript := `
      require "espalier/type_profile"
      require "json"
      repo = ARGV[0]
      only = ARGV[1] == "" ? [] : ARGV[1].split(",")
      files = ARGV[2] == "" ? [] : ARGV[2].split(",")
      exclude = ARGV[3] == "" ? [] : ARGV[3].split(",")
      if files.any?
        res = files.map { |f| File.expand_path(f, repo) }
                   .select { |f| File.file?(f) && Decomplex::SourceFilter.source_file?(f, root: repo, exclude: exclude) }
                   .map { |f| Decomplex::SourceFilter.relative_path(f, repo) }
      else
        res = Decomplex::SourceFilter.collect(repo, root: repo, exclude: exclude)
                                     .map { |f| Decomplex::SourceFilter.relative_path(f, repo) }
        if only.any?
          res = res.select { |rel| only.any? { |p| rel == p || rel.start_with?("#{p}/") } }
        end
      end
      puts JSON.dump(res)
	`
	var cmd *exec.Cmd
	if os.Getenv("BUNDLE_GEMFILE") != "" {
		cmd = exec.Command("bundle", "exec", "ruby", "-e", inlineScript,
			repo, strings.Join(only, ","), files, strings.Join(exclude, ","))
	} else {
		cmd = exec.Command("ruby", "-e", inlineScript,
			repo, strings.Join(only, ","), files, strings.Join(exclude, ","))
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("failed to get source files from ruby: %v, stderr: %s", err, stderr.String())
	}

	var res []string
	if err := json.Unmarshal(stdout.Bytes(), &res); err != nil {
		return nil, err
	}
	return res, nil
}

func inScope(rel string, only []string, files []string) bool {
	if len(files) > 0 {
		for _, f := range files {
			if rel == f {
				return true
			}
		}
		return false
	}
	if len(only) == 0 {
		return true
	}
	for _, p := range only {
		if rel == p || strings.HasPrefix(rel, p+"/") {
			return true
		}
	}
	return false
}

type PythonCoverageJson struct {
	Files map[string]PythonFileCoverage `json:"files"`
}

type PythonFileCoverage struct {
	ExecutedLines    []int   `json:"executed_lines"`
	MissingLines     []int   `json:"missing_lines"`
	ExecutedBranches [][]int `json:"executed_branches"`
	MissingBranches  [][]int `json:"missing_branches"`
}

type SyntaxFactsOutput struct {
	Documents []SyntaxFactsDoc `json:"documents"`
}

type SyntaxFactsDoc struct {
	BranchArms []SyntaxFactsArm `json:"branch_arms"`
}

type SyntaxFactsArm struct {
	BranchID     string `json:"branch_id"`
	ArmID        string `json:"arm_id"`
	Kind         string `json:"kind"`
	Member       string `json:"member"`
	DecisionLine int    `json:"decision_line"`
	DecisionSpan []int  `json:"decision_span"`
	ArmLine      int    `json:"line"`
	ArmSpan      []int  `json:"span"`
}

func findDecomplexBinary(repoRoot string) string {
	if envBin := os.Getenv("DECOMPLEX_RUST_BINARY"); envBin != "" {
		return envBin
	}
	sibling := filepath.Join(repoRoot, "gems/decomplex/target/release/decomplex-rust")
	if _, err := os.Stat(sibling); err == nil {
		return sibling
	}
	siblingDebug := filepath.Join(repoRoot, "gems/decomplex/target/debug/decomplex-rust")
	if _, err := os.Stat(siblingDebug); err == nil {
		return siblingDebug
	}

	if exePath, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exePath)
		gemsDir := filepath.Clean(filepath.Join(exeDir, "..", ".."))
		siblingRel := filepath.Join(gemsDir, "decomplex/target/release/decomplex-rust")
		if _, err := os.Stat(siblingRel); err == nil {
			return siblingRel
		}
		siblingRelDebug := filepath.Join(gemsDir, "decomplex/target/debug/decomplex-rust")
		if _, err := os.Stat(siblingRelDebug); err == nil {
			return siblingRelDebug
		}
	}

	return "decomplex-rust"
}

func isPythonCoverageJson(raw map[string]interface{}) bool {
	filesVal, ok := raw["files"]
	if !ok {
		return false
	}
	filesMap, ok := filesVal.(map[string]interface{})
	if !ok {
		return false
	}
	for _, v := range filesMap {
		entry, ok := v.(map[string]interface{})
		if !ok {
			continue
		}
		if _, ok := entry["executed_lines"]; ok {
			return true
		}
		if _, ok := entry["missing_lines"]; ok {
			return true
		}
		if _, ok := entry["executed_branches"]; ok {
			return true
		}
		if _, ok := entry["missing_branches"]; ok {
			return true
		}
	}
	return false
}

func parsePythonCoverageJson(data []byte, repo string, files map[string]FileCoverage) error {
	var pyCov PythonCoverageJson
	if err := json.Unmarshal(data, &pyCov); err != nil {
		return err
	}

	decomplexBin := findDecomplexBinary(repo)

	for file, entry := range pyCov.Files {
		absFile := file
		if !filepath.IsAbs(file) {
			absFile = filepath.Join(repo, file)
		}
		absFile = filepath.Clean(absFile)

		if _, err := os.Stat(absFile); err != nil {
			continue
		}

		dst, exists := files[absFile]
		if !exists {
			dst = FileCoverage{
				Lines:      []*int{},
				Branches:   make(map[string]map[string]int),
				SourcePath: relpathNoEval(absFile, repo),
				Format:     "coverage_py",
				Language:   "python",
			}
		}

		// Normalize lines
		for _, line := range entry.ExecutedLines {
			if line <= 0 {
				continue
			}
			for len(dst.Lines) < line {
				dst.Lines = append(dst.Lines, nil)
			}
			hits := 1
			if dst.Lines[line-1] == nil {
				dst.Lines[line-1] = &hits
			} else {
				*dst.Lines[line-1] += hits
			}
		}
		for _, line := range entry.MissingLines {
			if line <= 0 {
				continue
			}
			for len(dst.Lines) < line {
				dst.Lines = append(dst.Lines, nil)
			}
			if dst.Lines[line-1] == nil {
				hits := 0
				dst.Lines[line-1] = &hits
			}
		}

		executedArcs := normalizeArcs(entry.ExecutedBranches)
		missingArcs := normalizeArcs(entry.MissingBranches)

		if len(executedArcs) > 0 || len(missingArcs) > 0 {
			cmd := exec.Command(decomplexBin, "syntax-facts", "--language", "python", absFile)
			var stdout bytes.Buffer
			var stderr bytes.Buffer
			cmd.Stdout = &stdout
			cmd.Stderr = &stderr
			if err := cmd.Run(); err == nil {
				var facts SyntaxFactsOutput
				if json.Unmarshal(stdout.Bytes(), &facts) == nil && len(facts.Documents) > 0 {
					for _, arm := range facts.Documents[0].BranchArms {
						hitsVal, exists := getArmHits(arm, executedArcs, missingArcs)
						if !exists {
							continue
						}
						
						dst.BranchArms = append(dst.BranchArms, NativeBranchArm{
							BranchID:     arm.BranchID,
							ArmID:        arm.ArmID,
							Kind:         arm.Kind,
							Member:       arm.Member,
							DecisionSpan: arm.DecisionSpan,
							ArmSpan:      arm.ArmSpan,
							Hits:         hitsVal,
						})
					}
				}
			}
		}

		files[absFile] = dst
	}
	return nil
}

func normalizeArcs(arcs [][]int) [][2]int {
	var out [][2]int
	for _, arc := range arcs {
		if len(arc) == 2 && arc[0] > 0 && arc[1] > 0 {
			out = append(out, [2]int{arc[0], arc[1]})
		}
	}
	return out
}

func getArmHits(arm SyntaxFactsArm, executed, missing [][2]int) (int, bool) {
	decisionLine := arm.DecisionLine
	span := arm.ArmSpan
	
	for _, arc := range executed {
		if arc[0] == decisionLine && lineInSpan(arc[1], span) {
			return 1, true
		}
	}
	for _, arc := range missing {
		if arc[0] == decisionLine && lineInSpan(arc[1], span) {
			return 0, true
		}
	}
	return 0, false
}

func lineInSpan(line int, span []int) bool {
	if len(span) != 4 {
		return false
	}
	return line >= span[0] && line <= span[2]
}

