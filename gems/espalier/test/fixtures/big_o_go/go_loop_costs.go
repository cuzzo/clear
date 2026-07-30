package gologcosts

import "strings"

var fixedPatterns = []string{"a", "b", "c"}

// O(N): the Join runs at most once.
func EscapeByReturn(path string) string {
	parts := strings.Split(path, "/")
	for i, part := range parts {
		if part == "x" {
			return strings.Join(parts[:i+1], "/")
		}
	}
	return ""
}

// O(N): same, via break.
func EscapeByBreak(path string) string {
	parts := strings.Split(path, "/")
	out := ""
	for i, part := range parts {
		if part == "x" {
			out = strings.Join(parts[:i+1], "/")
			break
		}
	}
	return out
}

// O(N^2): the Join runs every iteration.
func JoinEveryIteration(path string) string {
	parts := strings.Split(path, "/")
	out := ""
	for i, part := range parts {
		if part == "x" {
			out = strings.Join(parts[:i+1], "/")
		}
	}
	return out
}

// O(N): per-element cost summed over the collection is its total size.
func PartitionedElementCost(lines []string) int {
	count := 0
	for _, line := range lines {
		if strings.Contains(line, "x") {
			count++
		}
	}
	return count
}

// O(N): a fixed-size inner loop adds no input dimension.
func PartitionedUnderFixedLoop(lines []string) int {
	count := 0
	for _, line := range lines {
		for _, pattern := range fixedPatterns {
			if strings.Contains(line, pattern) {
				count++
			}
		}
	}
	return count
}

// O(N): the write is constant, the loop is not.
func ConstantArgumentWrite(width int) string {
	var sb strings.Builder
	for i := 0; i < width; i++ {
		sb.WriteString("=")
	}
	return sb.String()
}

// O(N): input-sized writes summed over the collection.
func VariableArgumentWrite(parts []string) string {
	var sb strings.Builder
	for _, part := range parts {
		sb.WriteString(part)
	}
	return sb.String()
}

// O(N): tags is declared fresh per iteration and appended a fixed number of
// times, so the join over it does not grow with the input.
func BoundedTagsPerRow(rows []string) []string {
	out := make([]string, 0, len(rows))
	for _, row := range rows {
		var tags []string
		if row == "a" {
			tags = append(tags, "[A]")
		}
		if row == "b" {
			tags = append(tags, "[B]")
		}
		out = append(out, strings.Join(tags, " ")+row)
	}
	return out
}

// O(N^2): the same join, but the accumulator outlives the iteration.
func AccumulatedTagsPerRow(rows []string) []string {
	var tags []string
	out := make([]string, 0, len(rows))
	for _, row := range rows {
		tags = append(tags, row)
		out = append(out, strings.Join(tags, " "))
	}
	return out
}
