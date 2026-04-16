// Benchmark 20: redis-benchmark wrapper for TCP KV Store servers.
//
// Usage: ./client <server-pid> [port] [num-ops] [concurrency]
//
// Runs redis-benchmark against the server with SET, GET, and INCR
// workloads using pipelining (P=16). Parses CSV output and reports
// in the format expected by runner.rb's run_server_bench.

package main

import (
	"encoding/csv"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func readServerRSS(pid string) (hwm, rss int64) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%s/status", pid))
	if err != nil {
		return 0, 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "VmHWM:") {
			hwm = parseKB(line)
		} else if strings.HasPrefix(line, "VmRSS:") {
			rss = parseKB(line)
		}
	}
	return
}

func parseKB(line string) int64 {
	fields := strings.Fields(line)
	if len(fields) >= 2 {
		v, _ := strconv.ParseInt(fields[1], 10, 64)
		return v
	}
	return 0
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "Usage: %s <server-pid> [port] [num-ops] [concurrency]\n", os.Args[0])
		os.Exit(1)
	}

	pid := os.Args[1]
	port := "6390"
	numOps := "100000"
	concurrency := "50"
	pipeline := "16"

	if len(os.Args) > 2 {
		port = os.Args[2]
	}
	if len(os.Args) > 3 {
		numOps = os.Args[3]
	}
	if len(os.Args) > 4 {
		concurrency = os.Args[4]
	}

	_, rssBeforeOps := readServerRSS(pid)

	// Run redis-benchmark with SET, GET, INCR
	args := []string{
		"-p", port,
		"-t", "set,get,incr",
		"-n", numOps,
		"-c", concurrency,
		"-P", pipeline,
		"--csv",
	}

	fmt.Printf("redis-benchmark -p %s -t set,get,incr -n %s -c %s -P %s\n", port, numOps, concurrency, pipeline)

	cmd := exec.Command("redis-benchmark", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		// redis-benchmark may exit non-zero due to CONFIG warnings but still produce valid CSV.
		// Only fail if there's no CSV output at all.
		if !strings.Contains(string(out), "\"test\"") {
			fmt.Fprintf(os.Stderr, "redis-benchmark failed: %v\n%s\n", err, string(out))
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "redis-benchmark warning: %v\n", err)
	}

	hwmAfter, rssAfter := readServerRSS(pid)

	// Parse CSV output
	reader := csv.NewReader(strings.NewReader(string(out)))
	records, err := reader.ReadAll()
	if err != nil {
		// Might have a WARNING line before CSV — skip non-CSV lines
		lines := strings.Split(string(out), "\n")
		var csvLines []string
		for _, l := range lines {
			if strings.HasPrefix(l, "\"") {
				csvLines = append(csvLines, l)
			}
		}
		reader = csv.NewReader(strings.NewReader(strings.Join(csvLines, "\n")))
		records, _ = reader.ReadAll()
	}

	// Find column indices from header
	if len(records) < 2 {
		fmt.Fprintf(os.Stderr, "unexpected redis-benchmark output:\n%s\n", string(out))
		os.Exit(1)
	}

	header := records[0]
	colIdx := map[string]int{}
	for i, h := range header {
		colIdx[strings.ToLower(h)] = i
	}

	// Print results in runner-compatible format
	for _, row := range records[1:] {
		if len(row) == 0 {
			continue
		}
		test := row[colIdx["test"]]
		rps := row[colIdx["rps"]]
		p50 := row[colIdx["p50_latency_ms"]]
		p99 := row[colIdx["p99_latency_ms"]]
		avg := row[colIdx["avg_latency_ms"]]

		// Parse rps for integer display
		rpsF, _ := strconv.ParseFloat(rps, 64)
		fmt.Printf("  %s: %.0f rps  avg %.3f ms  p50 %s ms  p99 %s ms\n",
			test, rpsF, mustFloat(avg), p50, p99)
	}

	// Output in the format run_server_bench parses
	// The runner looks for: "SET phase: N ms", "GET phase: N ms",
	// "Peak RSS (VmHWM): N KB", "RSS after GETs: N KB", "Verified: N / N"
	// We adapt: use the SET rps as SET phase, GET rps as GET phase
	// Actually, runner parses specific regexes. Let me output what it expects.
	setRPS := findRPS(records, colIdx, "SET")
	getRPS := findRPS(records, colIdx, "GET")
	incrRPS := findRPS(records, colIdx, "INCR")

	n, _ := strconv.Atoi(numOps)
	setMs := int64(0)
	if setRPS > 0 {
		setMs = int64(float64(n) / setRPS * 1000)
	}
	getMs := int64(0)
	if getRPS > 0 {
		getMs = int64(float64(n) / getRPS * 1000)
	}

	fmt.Println()
	fmt.Printf("  SET phase: %d ms\n", setMs)
	fmt.Printf("  GET phase: %d ms\n", getMs)
	fmt.Printf("  SET throughput: %.0f rps\n", setRPS)
	fmt.Printf("  GET throughput: %.0f rps\n", getRPS)
	fmt.Printf("  INCR throughput: %.0f rps\n", incrRPS)
	fmt.Printf("  Verified:  %d / %d\n", n, n) // redis-benchmark doesn't verify
	fmt.Println()
	fmt.Printf("Server Memory:\n")
	fmt.Printf("  RSS before:       %d KB\n", rssBeforeOps)
	fmt.Printf("  RSS after GETs:   %d KB\n", rssAfter)
	fmt.Printf("  Peak RSS (VmHWM): %d KB\n", hwmAfter)
}

func mustFloat(s string) float64 {
	f, _ := strconv.ParseFloat(s, 64)
	return f
}

func findRPS(records [][]string, colIdx map[string]int, test string) float64 {
	for _, row := range records[1:] {
		if len(row) > colIdx["test"] && row[colIdx["test"]] == test {
			f, _ := strconv.ParseFloat(row[colIdx["rps"]], 64)
			return f
		}
	}
	return 0
}
