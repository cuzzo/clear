package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
)

type SarifDoc struct {
	Version string     `json:"version"`
	Schema  string     `json:"$schema"`
	Runs    []SarifRun `json:"runs"`
}

type SarifRun struct {
	Tool       SarifTool              `json:"tool"`
	Results    []SarifResult          `json:"results"`
	Properties map[string]interface{} `json:"properties,omitempty"`
}

type SarifTool struct {
	Driver SarifDriver `json:"driver"`
}

type SarifDriver struct {
	Name           string      `json:"name"`
	InformationURI string      `json:"informationUri,omitempty"`
	Rules          []SarifRule `json:"rules"`
}

type SarifRule struct {
	ID                   string                 `json:"id"`
	Name                 string                 `json:"name"`
	ShortDescription     SarifText              `json:"shortDescription"`
	FullDescription      *SarifText             `json:"fullDescription,omitempty"`
	DefaultConfiguration SarifConfiguration     `json:"defaultConfiguration"`
	HelpURI              string                 `json:"helpUri,omitempty"`
	Properties           map[string]interface{} `json:"properties,omitempty"`
}

type SarifText struct {
	Text string `json:"text"`
}

type SarifConfiguration struct {
	Level string `json:"level"`
}

type SarifResult struct {
	RuleID             string                 `json:"ruleId"`
	RuleIndex          int                    `json:"ruleIndex"`
	Level              string                 `json:"level"`
	Message            SarifText              `json:"message"`
	Locations          []SarifLocation        `json:"locations,omitempty"`
	Properties         map[string]interface{} `json:"properties,omitempty"`
	PartialFingerprints map[string]string      `json:"partialFingerprints,omitempty"`
}

type SarifLocation struct {
	PhysicalLocation SarifPhysicalLocation `json:"physicalLocation"`
}

type SarifPhysicalLocation struct {
	ArtifactLocation SarifArtifactLocation `json:"artifactLocation"`
	Region           *SarifRegion          `json:"region,omitempty"`
}

type SarifArtifactLocation struct {
	URI string `json:"uri"`
}

type SarifRegion struct {
	StartLine   int `json:"startLine,omitempty"`
	StartColumn int `json:"startColumn,omitempty"`
	EndLine     int `json:"endLine,omitempty"`
	EndColumn   int `json:"endColumn,omitempty"`
}

// Markdown formatting constants

const HeaderText = "# Boobytrap Report\n\n" +
	"> Defect-risk hotspots: recurring bug-fix locality " +
	"(bugspots, time-decayed) x branch-coverage gap.\n" +
	"> A ranking to triage **top-down**, never a verdict. A\n" +
	"> hotspot is \"the code most likely to be a bug source,\"\n" +
	"> not \"a bug.\"\n\n"

const TocTemplate = "## Table of Contents\n" +
	"- [Project Prioritization](#project-prioritization)\n" +
	"- [Hotspots (%d)](#hotspots-%d)\n" +
	"- [Mostly Uncovered Methods (%d)](#mostly-uncovered-methods-%d)\n" +
	"- [State-Based Branch Hotspots (%d)](#statebased-branch-hotspots-%d)\n" +
	"- [Multi-File Fix Blast Radius (%d)](#multifile-fix-blast-radius-%d)\n" +
	"- [Lineage Unit Risk (%d)](#lineage-unit-risk-%d)\n" +
	"- [Fixed But Unmeasured (%d)](#fixed-but-unmeasured-%d)\n" +
	"- [Run Summary](#run-summary)\n\n"

const HotspotsIntro = "## Hotspots (%d)\n" +
	"_normalized fix-churn x branch-gap; highest = most likely " +
	"defect source._\n\n"

const DarkMethodsIntro = "## Mostly Uncovered Methods (%d)\n" +
	"_non-trivial methods (`>=5` executable lines) with very low line coverage; " +
	"risk = missed lines x gap, Decomplex detector score, " +
	"instance-state writes, dark branches, fix history, mutation " +
	"verification, and named-test exposure when supplied._\n\n"

const StateBranchIntro = "## State-Based Branch Hotspots (%d)\n" +
	"_Decomplex state-based branch density joined with fix-cache and branch coverage. " +
	"These are branches over mutable/object state that are uncovered and/or historically fixed._\n\n"

const BlastRadiusIntro = "## Multi-File Fix Blast Radius (%d)\n" +
	"_Time-decayed fix commits where a file repeatedly changes with many other files. " +
	"High rows are bug fixes whose blast radius is cross-module, not local._\n\n"

const LineageIntro = "## Lineage Unit Risk (%d)\n" +
	"_Optional Lineage SQLite overlay: time-decayed semantic `FIX`/`CHANGE` " +
	"events at logical-unit granularity. Pure moves are shown but do not add risk._\n\n"

const UnmeasuredIntro = "## Fixed But Unmeasured (%d)\n" +
	"_files with recurring fixes but NO branch-coverage data -- " +
	"recurring-fix code the corpus does not measure at all; " +
	"itself a risk._\n\n"

const HighestRiskTemplate = "- The single highest-risk file is **`%s`** (hotspot=%s: fix_norm=%s, branch gap=%.1f%%).\n"
const NearMatchesTemplate = "- %d file(s) are within 50%% of the top score (hotspot >= %.4f); triage those first.\n"
const StateHotspotTemplate = "- Highest state-based branch hotspot: `%s:%s` (score=%.2f, state branches=%d, fix_norm=%.3f, branch gap=%.1f%%).\n"
const BlastRadiusTemplate = "- Highest multi-file fix blast radius: `%s` (score=%s, avg files/fix=%s, max=%d).\n"
const DarkMethodTemplate  = "- Highest empirical method risk: `%s:%d` `%s` (risk=%.2f, fix_norm=%s, verification=%s, tests=%s).\n"
const LineageUnitTemplate = "- Highest lineage unit risk: `%s` `%s` (risk=%.1f, fixes=%d, changes=%d, moves=%d).\n"
const NoCoverageWarning   = "- WARNING: no branch-coverage resultset supplied; only fix-churn is shown (gap assumed unknown).\n"

const SummaryTemplate = "## Run Summary\n" +
	"- Repo: `%s`\n" +
	"- Scope: %s\n" +
	"- Fix commits matched: %d (time span over whole history, unfiltered)\n" +
	"- Files ranked: %d; fixed-but-unmeasured: %d\n" +
	"- State-based branch hotspots: %d; multi-file fix blast rows: %d\n" +
	"- Branch-coverage resultset: %s\n" +
	"- Mutation facts: %s\n" +
	"- Test exposure facts: %s\n" +
	"- Lineage DB: %s\n"

const SummaryMethodDesc = "- Method: vendored bugspots " +
	"([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) " +
	"x normalized coverage branch gap; method gaps use Decomplex detector scores, " +
	"fix history, mutation verification, and named-test exposure when supplied " +
	"(see [docs/agents/design.md](docs/agents/design.md))\n"

type StateBranchHotspotRow struct {
	File         string      `json:"file"`
	Method       string      `json:"method"`
	Score        float64     `json:"score"`
	Decisions    int         `json:"decisions"`
	At           interface{} `json:"at"`
	StateRefs    []string    `json:"state_refs"`
	Predicate    string      `json:"predicate"`
	FixNorm      float64     `json:"fix_norm"`
	BranchGap    float64     `json:"branch_gap"`
	LineGap      float64     `json:"line_gap"`
	DarkBranches int         `json:"dark_branches"`
	Risk         float64     `json:"risk"`
}

func buildStateBranchHotspots(
	findings []StateBranchDensityRow,
	methodGaps []MethodGapRow,
	fixScores map[string]float64,
	fixMax float64,
	gaps map[string]FileGap,
) []StateBranchHotspotRow {
	methodIndex := make(map[MethodKey]MethodGapRow)
	for _, m := range methodGaps {
		methodIndex[MethodKey{File: m.File, Method: m.Name}] = m
	}

	var res []StateBranchHotspotRow
	for _, h := range findings {
		m, hasMethod := methodIndex[MethodKey{File: h.File, Method: h.Method}]
		fixNorm := 0.0
		if fixMax > 0.0 {
			fixNorm = math.Round((fixScores[h.File]/fixMax)*1000) / 1000
		}
		branchGap := 0.0
		if g, exists := gaps[h.File]; exists {
			branchGap = g.Gap
		}
		lineGap := 0.0
		dark := 0
		tExpMultiplier := 1.0
		if hasMethod {
			lineGap = m.LineGap
			dark = m.UncoveredBranches
			tExpMultiplier = m.TestExposureMultiplier
		}

		risk := h.Score * (1.0 + fixNorm) * (1.0 + branchGap) * (1.0 + lineGap) * tExpMultiplier + float64(dark)

		res = append(res, StateBranchHotspotRow{
			File:         h.File,
			Method:       h.Method,
			Score:        h.Score,
			Decisions:    h.Decisions,
			At:           h.At,
			StateRefs:    h.StateRefs,
			Predicate:    h.Predicate,
			FixNorm:      fixNorm,
			BranchGap:    branchGap,
			LineGap:      lineGap,
			DarkBranches: dark,
			Risk:         risk,
		})
	}

	sort.Slice(res, func(i, j int) bool {
		if res[i].Risk != res[j].Risk {
			return res[i].Risk > res[j].Risk
		}
		if res[i].Decisions != res[j].Decisions {
			return res[i].Decisions > res[j].Decisions
		}
		if res[i].File != res[j].File {
			return res[i].File < res[j].File
		}
		return res[i].Method < res[j].Method
	})

	return res
}

func formatFloat(val float64, prec int) string {
	if val == float64(int(val)) {
		return fmt.Sprintf("%.1f", val)
	}
	return strconv.FormatFloat(val, 'f', -1, 64)
}

func scopeLabel(only []string, files []string) string {
	if len(files) > 0 {
		var quoted []string
		for _, f := range files {
			quoted = append(quoted, "`"+f+"`")
		}
		return strings.Join(quoted, ", ")
	}
	if len(only) == 0 {
		return "whole repo"
	}
	var quoted []string
	for _, o := range only {
		quoted = append(quoted, "`"+o+"/`")
	}
	return strings.Join(quoted, ", ")
}

func empiricalColumns(mutationActive bool, testExposureActive bool, lineageHasTestExposure bool) bool {
	return mutationActive || testExposureActive || lineageHasTestExposure
}

func empiricalProfile(row MethodGapRow) string {
	var profiles []string
	if row.RiskProfile != "" {
		profiles = append(profiles, row.RiskProfile)
	}
	if row.TestExposureProfile != "" {
		profiles = append(profiles, row.TestExposureProfile)
	}
	seen := make(map[string]bool)
	var unique []string
	for _, p := range profiles {
		if !seen[p] {
			seen[p] = true
			unique = append(unique, p)
		}
	}
	if len(unique) == 0 {
		return "not supplied"
	}
	return strings.Join(unique, "; ")
}

func lineageCell(row MethodGapRow) string {
	if row.LineageScore <= 0.0 {
		return "0"
	}
	return fmt.Sprintf("%.1f (f%d/c%d/m%d)", row.LineageScore, row.LineageFixes, row.LineageChanges, row.LineageMoves)
}

func formatFindings(findings []Finding) string {
	if len(findings) == 0 {
		return "[]"
	}
	var parts []string
	for _, f := range findings {
		parts = append(parts, fmt.Sprintf(`{"type"=>"%s"}`, f.Type))
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

func testExposureLabel(active bool, label string) string {
	if !active {
		return "not supplied"
	}
	if label != "" {
		return label
	}
	return "active"
}

func coverageMode(hasCoverage bool, covLabel string, static bool, hasGaps bool) string {
	if hasCoverage && static {
		return covLabel + " + tree-sitter static fallback"
	}
	if static && !hasCoverage {
		return "tree-sitter static fallback"
	}
	if hasCoverage {
		return covLabel
	}
	if !hasGaps {
		return "absent"
	}
	return "unknown"
}

func generateMarkdown(
	repo string,
	only []string,
	files []string,
	fixCommits int,
	ranked []HotspotRow,
	unmeasured []UnmeasuredEntry,
	methodGaps []MethodGapRow,
	stateBranchHotspots []StateBranchHotspotRow,
	blastRadius []BlastRow,
	lineage LineageIndex,
	haveCov bool,
	covLabel string,
	mutationFactsActive bool,
	mutationFactsLabel string,
	testExposureActive bool,
	testExposureLabelStr string,
	top int,
) string {
	var o bytes.Buffer
	o.WriteString(HeaderText)

	// Filter methodGaps for darkMethods (line_gap >= 0.80)
	var darkMethods []MethodGapRow
	for _, m := range methodGaps {
		if m.LineGap >= 0.80 {
			darkMethods = append(darkMethods, m)
		}
	}
	sort.Slice(darkMethods, func(i, j int) bool {
		if darkMethods[i].Risk != darkMethods[j].Risk {
			return darkMethods[i].Risk > darkMethods[j].Risk
		}
		if darkMethods[i].MissedLines != darkMethods[j].MissedLines {
			return darkMethods[i].MissedLines > darkMethods[j].MissedLines
		}
		if darkMethods[i].File != darkMethods[j].File {
			return darkMethods[i].File < darkMethods[j].File
		}
		return darkMethods[i].FirstLine < darkMethods[j].FirstLine
	})

	o.WriteString(fmt.Sprintf(TocTemplate,
		len(ranked), len(ranked),
		len(darkMethods), len(darkMethods),
		len(stateBranchHotspots), len(stateBranchHotspots),
		len(blastRadius), len(blastRadius),
		len(lineage.Units), len(lineage.Units),
		len(unmeasured), len(unmeasured)))

	o.WriteString("## Project Prioritization\n")
	if len(ranked) == 0 {
		o.WriteString("_No hotspots: no fix-churn x coverage-gap overlap found._\n\n")
	} else {
		firstRanked := ranked[0]
		cutoffScore := firstRanked.Hotspot * 0.5
		nearCount := 0
		for _, r := range ranked {
			if r.Hotspot >= cutoffScore {
				nearCount++
			}
		}
		o.WriteString(fmt.Sprintf(HighestRiskTemplate, firstRanked.File, formatFloat(firstRanked.Hotspot, 4),
			formatFloat(firstRanked.FixNorm, 3), firstRanked.Gap*100))
		o.WriteString(fmt.Sprintf(NearMatchesTemplate, nearCount, cutoffScore))

		if len(stateBranchHotspots) > 0 {
			firstSB := stateBranchHotspots[0]
			o.WriteString(fmt.Sprintf(StateHotspotTemplate, firstSB.File, firstSB.Method,
				firstSB.Risk, firstSB.Decisions, firstSB.FixNorm, firstSB.BranchGap*100))
		}
		if len(blastRadius) > 0 {
			firstBR := blastRadius[0]
			o.WriteString(fmt.Sprintf(BlastRadiusTemplate, firstBR.File, formatFloat(firstBR.Score, 3),
				formatFloat(firstBR.AvgTouched, 3), firstBR.MaxTouched))
		}
		if len(darkMethods) > 0 {
			firstDM := darkMethods[0]
			ver := firstDM.VerificationStatus
			if ver == "" {
				ver = "not supplied"
			}
			tExp := firstDM.TestExposureStatus
			if tExp == "" {
				tExp = "not supplied"
			}
			o.WriteString(fmt.Sprintf(DarkMethodTemplate, firstDM.File, firstDM.FirstLine,
				firstDM.Name, firstDM.Risk, formatFloat(firstDM.FixNorm, 3), ver, tExp))
		}
		if len(lineage.Units) > 0 {
			firstLU := lineage.Units[0]
			o.WriteString(fmt.Sprintf(LineageUnitTemplate, firstLU.File, firstLU.Name,
				firstLU.RiskScore, firstLU.Fixes, firstLU.Changes, firstLU.Moves))
		}
		if !haveCov {
			o.WriteString(NoCoverageWarning)
		}
		o.WriteString("\n")
	}

	o.WriteString(fmt.Sprintf(HotspotsIntro, len(ranked)))
	if len(ranked) == 0 {
		o.WriteString("None.\n\n")
	} else {
		o.WriteString("| # | file | hotspot | fix_norm | branch gap | uncovered/total |\n")
		o.WriteString("|---|------|---------|----------|-----------|-----------------|\n")
		limit := top
		if len(ranked) < limit {
			limit = len(ranked)
		}
		for i, h := range ranked[:limit] {
			o.WriteString(fmt.Sprintf("| %d | `%s` | %s | %s | %.1f%% | %d/%d |\n",
				i+1, h.File, formatFloat(h.Hotspot, 4), formatFloat(h.FixNorm, 3), h.Gap*100, h.Uncovered, h.TotalBranches))
		}
		if len(ranked) > top {
			o.WriteString(fmt.Sprintf("\n- ...(+" + strconv.Itoa(len(ranked)-top) + " more)\n"))
		}
		o.WriteString("\n")
	}

	o.WriteString(fmt.Sprintf(DarkMethodsIntro, len(darkMethods)))
	if len(methodGaps) == 0 {
		o.WriteString("_No line-coverage method data available._\n\n")
	} else if len(darkMethods) == 0 {
		o.WriteString("None.\n\n")
	} else {
		uncovered := 0
		le10 := 0
		le20 := len(darkMethods)
		le50 := 0
		for _, m := range methodGaps {
			if m.CoveredLines == 0 {
				uncovered++
			}
			if m.LineGap >= 0.90 {
				le10++
			}
			if m.LineGap >= 0.50 {
				le50++
			}
		}
		o.WriteString(fmt.Sprintf("- Completely uncovered: %d\n", uncovered))
		o.WriteString(fmt.Sprintf("- <=10%% covered: %d\n", le10))
		o.WriteString(fmt.Sprintf("- <=20%% covered: %d\n", le20))
		o.WriteString(fmt.Sprintf("- <=50%% covered: %d\n\n", le50))

		empCol := empiricalColumns(mutationFactsActive, testExposureActive, lineage.HasTestExposure)
		if empCol {
			o.WriteString("| # | method | risk | covered | missed | fix_norm | lineage | decomplex | verification | tests | profile | writes | dark branches |\n")
			o.WriteString("|---|--------|------|---------|--------|----------|---------|-----------|--------------|-------|---------|--------|---------------|\n")
		} else {
			o.WriteString("| # | method | risk | covered | missed | fix_norm | lineage | decomplex | findings | writes | dark branches |\n")
			o.WriteString("|---|--------|------|---------|--------|----------|---------|-----------|----------|--------|---------------|\n")
		}

		limit := top
		if len(darkMethods) < limit {
			limit = len(darkMethods)
		}
		for i, m := range darkMethods[:limit] {
			common := fmt.Sprintf("| %d | `%s:%d` `%s` | %.2f | %d/%d | %d | %s | %s | %d ",
				i+1, m.File, m.FirstLine, m.Name, m.Risk, m.CoveredLines, m.ExecutableLines, m.MissedLines, formatFloat(m.FixNorm, 3), lineageCell(m), m.DecomplexScore)
			if empCol {
				ver := m.VerificationStatus
				if ver == "" {
					ver = "not supplied"
				}
				tExp := m.TestExposureStatus
				if tExp == "" {
					tExp = "not supplied"
				}
				o.WriteString(common)
				o.WriteString(fmt.Sprintf("| %s | %s | %s | %d | %d |\n",
					ver, tExp, empiricalProfile(m), m.StateWrites, m.UncoveredBranches))
			} else {
				o.WriteString(common)
				o.WriteString(fmt.Sprintf("| %s | %d | %d |\n",
					formatFindings(m.DecomplexFindings), m.StateWrites, m.UncoveredBranches))
			}
		}
		if len(darkMethods) > top {
			o.WriteString(fmt.Sprintf("\n- ...(+" + strconv.Itoa(len(darkMethods)-top) + " more)\n"))
		}
		o.WriteString("\n")
	}

	o.WriteString(fmt.Sprintf(StateBranchIntro, len(stateBranchHotspots)))
	if len(stateBranchHotspots) == 0 {
		o.WriteString("None.\n\n")
	} else {
		o.WriteString("| # | method | risk | state branches | refs | fix_norm | branch gap | line gap | dark branches |\n")
		o.WriteString("|---|--------|------|----------------|------|----------|------------|----------|---------------|\n")
		limit := top
		if len(stateBranchHotspots) < limit {
			limit = len(stateBranchHotspots)
		}
		for i, sb := range stateBranchHotspots[:limit] {
			var refs []string
			for _, r := range sb.StateRefs {
				refs = append(refs, r)
			}
			if len(refs) > 5 {
				refs = refs[:5]
			}
			o.WriteString(fmt.Sprintf("| %d | `%s:%s` | %.2f | %d | `%s` | %s | %.1f%% | %.1f%% | %d |\n",
				i+1, sb.File, sb.Method, sb.Risk, sb.Decisions, strings.Join(refs, " | "), formatFloat(sb.FixNorm, 3), sb.BranchGap*100, sb.LineGap*100, sb.DarkBranches))
		}
		if len(stateBranchHotspots) > top {
			o.WriteString(fmt.Sprintf("\n- ...(+" + strconv.Itoa(len(stateBranchHotspots)-top) + " more)\n"))
		}
		o.WriteString("\n")
	}

	o.WriteString(fmt.Sprintf(BlastRadiusIntro, len(blastRadius)))
	if len(blastRadius) == 0 {
		o.WriteString("None.\n\n")
	} else {
		o.WriteString("| # | file | score | fixes | avg files/fix | max files | top co-touched files |\n")
		o.WriteString("|---|------|-------|-------|---------------|-----------|----------------------|\n")
		limit := top
		if len(blastRadius) < limit {
			limit = len(blastRadius)
		}
		for i, br := range blastRadius[:limit] {
			var partners []string
			for _, p := range br.Partners {
				partners = append(partners, fmt.Sprintf("%s (%v)", p[0], p[1]))
			}
			o.WriteString(fmt.Sprintf("| %d | `%s` | %s | %d | %s | %d | %s |\n",
				i+1, br.File, formatFloat(br.Score, 3), br.Fixes, formatFloat(br.AvgTouched, 3), br.MaxTouched, strings.Join(partners, "; ")))
		}
		if len(blastRadius) > top {
			o.WriteString(fmt.Sprintf("\n- ...(+" + strconv.Itoa(len(blastRadius)-top) + " more)\n"))
		}
		o.WriteString("\n")
	}

	o.WriteString(fmt.Sprintf(LineageIntro, len(lineage.Units)))
	if lineage.Status != "ok" {
		o.WriteString("_No Lineage database supplied._\n\n")
	} else if len(lineage.Units) == 0 {
		o.WriteString("None.\n\n")
	} else {
		o.WriteString("| # | unit | risk | fixes | changes | moves | events |\n")
		o.WriteString("|---|------|------|-------|---------|-------|--------|\n")
		limit := top
		if len(lineage.Units) < limit {
			limit = len(lineage.Units)
		}
		for i, lu := range lineage.Units[:limit] {
			o.WriteString(fmt.Sprintf("| %d | `%s` `%s` | %.1f | %d | %d | %d | %d |\n",
				i+1, lu.File, lu.Name, lu.RiskScore, lu.Fixes, lu.Changes, lu.Moves, lu.TotalEvents))
		}
		if len(lineage.Units) > top {
			o.WriteString(fmt.Sprintf("\n- ...(+" + strconv.Itoa(len(lineage.Units)-top) + " more)\n"))
		}
		o.WriteString("\n")
	}

	o.WriteString(fmt.Sprintf(UnmeasuredIntro, len(unmeasured)))
	if len(unmeasured) == 0 {
		o.WriteString("None.\n\n")
	} else {
		limit := top
		if len(unmeasured) < limit {
			limit = len(unmeasured)
		}
		for _, unm := range unmeasured[:limit] {
			o.WriteString(fmt.Sprintf("- `%s` (fix_norm=%s)\n", unm.File, formatFloat(unm.FixNorm, 3)))
		}
		o.WriteString("\n")
	}

	covMode := "absent"
	if haveCov {
		covMode = coverageMode(haveCov, covLabel, true, len(ranked) > 0)
	} else if len(ranked) > 0 {
		covMode = "ABSENT (fix-churn only)"
	}

	mutationLabel := "not supplied"
	if mutationFactsActive {
		mutationLabel = mutationFactsLabel
	}
	tExpLabel := testExposureLabel(testExposureActive, testExposureLabelStr)
	linLabel := "not supplied"
	if lineage.Status == "ok" {
		linLabel = lineage.Label
	}

	o.WriteString(fmt.Sprintf(SummaryTemplate,
		repo,
		scopeLabel(only, files),
		fixCommits,
		len(ranked),
		len(unmeasured),
		len(stateBranchHotspots),
		len(blastRadius),
		covMode,
		mutationLabel,
		tExpLabel,
		linLabel,
	))
	o.WriteString(SummaryMethodDesc)

	return o.String()
}

func generateSarif(
	repo string,
	only []string,
	files []string,
	fixCommits int,
	ranked []HotspotRow,
	unmeasured []UnmeasuredEntry,
	methodGaps []MethodGapRow,
	stateBranchHotspots []StateBranchHotspotRow,
	blastRadius []BlastRow,
	lineage LineageIndex,
	haveCov bool,
	covLabel string,
	mutationFactsActive bool,
	mutationFactsLabel string,
	testExposureActive bool,
	testExposureLabelStr string,
	top int,
) string {
	rules := []SarifRule{
		{
			ID:                   "boobytrap.file-hotspot",
			Name:                 "File Hotspot",
			ShortDescription:     SarifText{Text: "Time-decayed fix churn overlaps with branch coverage gap"},
			DefaultConfiguration: SarifConfiguration{Level: "warning"},
		},
		{
			ID:                   "boobytrap.dark-method",
			Name:                 "Mostly Uncovered Method",
			ShortDescription:     SarifText{Text: "Non-trivial method has very low executable line coverage"},
			DefaultConfiguration: SarifConfiguration{Level: "warning"},
		},
		{
			ID:                   "boobytrap.state-branch-hotspot",
			Name:                 "State Branch Hotspot",
			ShortDescription:     SarifText{Text: "State-based branch density overlaps with fix history or coverage gaps"},
			DefaultConfiguration: SarifConfiguration{Level: "warning"},
		},
		{
			ID:                   "boobytrap.fix-blast-radius",
			Name:                 "Fix Blast Radius",
			ShortDescription:     SarifText{Text: "File repeatedly participates in multi-file bug fixes"},
			DefaultConfiguration: SarifConfiguration{Level: "note"},
		},
		{
			ID:                   "boobytrap.lineage-unit-risk",
			Name:                 "Lineage Unit Risk",
			ShortDescription:     SarifText{Text: "Logical unit has decayed semantic change/fix risk"},
			DefaultConfiguration: SarifConfiguration{Level: "note"},
		},
		{
			ID:                   "boobytrap.fixed-unmeasured",
			Name:                 "Fixed But Unmeasured",
			ShortDescription:     SarifText{Text: "Historically fixed source file has no branch coverage data"},
			DefaultConfiguration: SarifConfiguration{Level: "warning"},
		},
	}

	results := []SarifResult{}

	// Helper to convert struct to map[string]interface{}
	structToMap := func(val interface{}) map[string]interface{} {
		data, _ := json.Marshal(val)
		var m map[string]interface{}
		json.Unmarshal(data, &m)
		return m
	}

	// 1. Hotspots
	limitRanked := top
	if len(ranked) < limitRanked {
		limitRanked = len(ranked)
	}
	for _, row := range ranked[:limitRanked] {
		level := "note"
		if row.Hotspot > 0.0 {
			level = "warning"
		}
		props := structToMap(row)
		props["source_format"] = "boobytrap.report.v1"
		results = append(results, SarifResult{
			RuleID:    "boobytrap.file-hotspot",
			RuleIndex: 0,
			Level:     level,
			Message:   SarifText{Text: fmt.Sprintf("file hotspot: %s hotspot=%v branch_gap=%v", row.File, row.Hotspot, row.Gap)},
			Locations: []SarifLocation{
				{
					PhysicalLocation: SarifPhysicalLocation{
						ArtifactLocation: SarifArtifactLocation{URI: row.File},
						Region:           &SarifRegion{StartLine: 1},
					},
				},
			},
			Properties: props,
		})
	}

	// 2. Dark Methods
	var darkMethods []MethodGapRow
	for _, m := range methodGaps {
		if m.LineGap >= 0.80 {
			darkMethods = append(darkMethods, m)
		}
	}
	sort.Slice(darkMethods, func(i, j int) bool {
		if darkMethods[i].Risk != darkMethods[j].Risk {
			return darkMethods[i].Risk > darkMethods[j].Risk
		}
		if darkMethods[i].MissedLines != darkMethods[j].MissedLines {
			return darkMethods[i].MissedLines > darkMethods[j].MissedLines
		}
		if darkMethods[i].File != darkMethods[j].File {
			return darkMethods[i].File < darkMethods[j].File
		}
		return darkMethods[i].FirstLine < darkMethods[j].FirstLine
	})

	limitDM := top
	if len(darkMethods) < limitDM {
		limitDM = len(darkMethods)
	}
	for _, row := range darkMethods[:limitDM] {
		props := structToMap(row)
		props["dark_arm"] = row.UncoveredBranches > 0
		props["source_format"] = "boobytrap.report.v1"
		results = append(results, SarifResult{
			RuleID:    "boobytrap.dark-method",
			RuleIndex: 1,
			Level:     "warning",
			Message:   SarifText{Text: fmt.Sprintf("mostly uncovered method: %s:%d %s risk=%.2f", row.File, row.FirstLine, row.Name, row.Risk)},
			Locations: []SarifLocation{
				{
					PhysicalLocation: SarifPhysicalLocation{
						ArtifactLocation: SarifArtifactLocation{URI: row.File},
						Region:           &SarifRegion{StartLine: row.FirstLine, EndLine: row.LastLine},
					},
				},
			},
			Properties: props,
		})
	}

	// 3. State branch hotspots
	limitSB := top
	if len(stateBranchHotspots) < limitSB {
		limitSB = len(stateBranchHotspots)
	}
	for _, row := range stateBranchHotspots[:limitSB] {
		props := structToMap(row)
		props["source_format"] = "boobytrap.report.v1"
		line := 1
		atStr := ""
		if row.At != nil {
			if s, ok := row.At.(string); ok {
				atStr = s
			} else {
				atStr = fmt.Sprintf("%v", row.At)
			}
		}
		parts := strings.Split(atStr, ":")
		if len(parts) > 0 {
			if l, err := strconv.Atoi(parts[len(parts)-1]); err == nil && l > 0 {
				line = l
			}
		}
		results = append(results, SarifResult{
			RuleID:    "boobytrap.state-branch-hotspot",
			RuleIndex: 2,
			Level:     "warning",
			Message:   SarifText{Text: fmt.Sprintf("state branch hotspot: %s %s risk=%.2f", row.File, row.Method, row.Risk)},
			Locations: []SarifLocation{
				{
					PhysicalLocation: SarifPhysicalLocation{
						ArtifactLocation: SarifArtifactLocation{URI: row.File},
						Region:           &SarifRegion{StartLine: line},
					},
				},
			},
			Properties: props,
		})
	}

	// 4. Blast radius
	limitBR := top
	if len(blastRadius) < limitBR {
		limitBR = len(blastRadius)
	}
	for _, row := range blastRadius[:limitBR] {
		props := structToMap(row)
		props["source_format"] = "boobytrap.report.v1"
		results = append(results, SarifResult{
			RuleID:    "boobytrap.fix-blast-radius",
			RuleIndex: 3,
			Level:     "note",
			Message:   SarifText{Text: fmt.Sprintf("fix blast radius: %s score=%v", row.File, row.Score)},
			Locations: []SarifLocation{
				{
					PhysicalLocation: SarifPhysicalLocation{
						ArtifactLocation: SarifArtifactLocation{URI: row.File},
						Region:           &SarifRegion{StartLine: 1},
					},
				},
			},
			Properties: props,
		})
	}

	// 5. Lineage unit risk
	if lineage.Status == "ok" {
		limitLU := top
		if len(lineage.Units) < limitLU {
			limitLU = len(lineage.Units)
		}
		for _, unit := range lineage.Units[:limitLU] {
			props := structToMap(unit)
			props["source_format"] = "boobytrap.report.v1"
			results = append(results, SarifResult{
				RuleID:    "boobytrap.lineage-unit-risk",
				RuleIndex: 4,
				Level:     "note",
				Message:   SarifText{Text: fmt.Sprintf("lineage unit risk: %s %s risk=%.1f", unit.File, unit.Name, unit.RiskScore)},
				Locations: []SarifLocation{
					{
						PhysicalLocation: SarifPhysicalLocation{
							ArtifactLocation: SarifArtifactLocation{URI: unit.File},
							Region:           &SarifRegion{StartLine: 1},
						},
					},
				},
				Properties: props,
			})
		}
	}

	// 6. Unmeasured
	limitUnm := top
	if len(unmeasured) < limitUnm {
		limitUnm = len(unmeasured)
	}
	for _, row := range unmeasured[:limitUnm] {
		props := structToMap(row)
		props["source_format"] = "boobytrap.report.v1"
		results = append(results, SarifResult{
			RuleID:    "boobytrap.fixed-unmeasured",
			RuleIndex: 5,
			Level:     "warning",
			Message:   SarifText{Text: fmt.Sprintf("fixed but unmeasured: %s fix_norm=%v", row.File, row.FixNorm)},
			Locations: []SarifLocation{
				{
					PhysicalLocation: SarifPhysicalLocation{
						ArtifactLocation: SarifArtifactLocation{URI: row.File},
						Region:           &SarifRegion{StartLine: 1},
					},
				},
			},
			Properties: props,
		})
	}

	covMode := "absent"
	if haveCov {
		covMode = coverageMode(haveCov, covLabel, true, len(ranked) > 0)
	} else if len(ranked) > 0 {
		covMode = "ABSENT (fix-churn only)"
	}

	mutationLabel := "not supplied"
	if mutationFactsActive {
		mutationLabel = mutationFactsLabel
	}
	tExpLabel := testExposureLabel(testExposureActive, testExposureLabelStr)
	linLabel := "not supplied"
	if lineage.Status == "ok" {
		linLabel = lineage.Label
	}

	summary := map[string]interface{}{
		"repo":                  repo,
		"scope":                 map[string]interface{}{"only": only, "files": files},
		"fix_commits":           fixCommits,
		"files_ranked":          len(ranked),
		"fixed_but_unmeasured":  len(unmeasured),
		"state_branch_hotspots": len(stateBranchHotspots),
		"coverage_mode":         covMode,
		"mutation_facts":        mutationLabel,
		"test_exposure_facts":   tExpLabel,
		"lineage":               linLabel,
	}

	doc := SarifDoc{
		Version: "2.1.0",
		Schema:  "https://json.schemastore.org/sarif-2.1.0.json",
		Runs: []SarifRun{
			{
				Tool: SarifTool{
					Driver: SarifDriver{
						Name:           "Boobytrap",
						InformationURI: "https://github.com/codeforreno/litedb",
						Rules:          rules,
					},
				},
				Results: results,
				Properties: map[string]interface{}{
					"format":  "boobytrap.report.sarif.v1",
					"summary": summary,
				},
			},
		},
	}

	data, _ := json.MarshalIndent(doc, "", "  ")
	return string(data)
}
