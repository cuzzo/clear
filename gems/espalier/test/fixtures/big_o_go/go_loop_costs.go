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
