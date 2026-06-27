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
	FixCommits int                 `json:"fix_commits"`
	FixScores  map[string]float64  `json:"fix_scores"`
	Blast      []BlastRow          `json:"blast_radius"`
	Coverage   *CoverageDataset    `json:"coverage,omitempty"`
	Gaps       map[string]FileGap  `json:"gaps,omitempty"`
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

	out := Output{
		FixCommits: len(events),
		FixScores:  scores,
		Blast:      blast,
		Coverage:   covDataset,
		Gaps:       gaps,
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

func relpath(abs, root string) string {
	absClean := filepath.Clean(abs)
	rootClean := filepath.Clean(root)
	if absClean == rootClean {
		return ""
	}
	rel, err := filepath.Rel(rootClean, absClean)
	if err != nil {
		return abs
	}
	return rel
}
