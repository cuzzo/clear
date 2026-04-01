// Benchmark 25: Pathological workload client.
//
// Usage: ./client <server-pid> [port] [num-requests] [concurrency]
//
// Three phases:
//   1. Uniform:     all requests WORK:ID:100
//   2. Skewed:      0.5% WORK:ID:10000, 99.5% WORK:ID:10 (1-in-200 for p99)
//   3. Adversarial: connection 0 all WORK:ID:10000, rest all WORK:ID:10

package main

import (
	"bufio"
	"fmt"
	"math/rand"
	"net"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

func heavyCompute(seed int64, n int) int64 {
	x := seed
	for i := 0; i < n; i++ {
		x = x*6364136223846793005 + 1442695040888963407
		x = x*x + 1
	}
	if x < 0 {
		x = -x
	}
	return x % 1000000000
}

func readServerRSS(pid string) (hwm, rss int64) {
	data, err := os.ReadFile(fmt.Sprintf("/proc/%s/status", pid))
	if err != nil {
		return 0, 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "VmHWM:") {
			hwm = parseKB(line)
		}
		if strings.HasPrefix(line, "VmRSS:") {
			rss = parseKB(line)
		}
	}
	return
}

func parseKB(line string) int64 {
	f := strings.Fields(line)
	if len(f) >= 2 {
		v, _ := strconv.ParseInt(f[1], 10, 64)
		return v
	}
	return 0
}

func sendCommand(conn net.Conn, reader *bufio.Reader, cmd string) (string, error) {
	fmt.Fprintf(conn, "%s\r\n", cmd)
	line, err := reader.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

type latencyResult struct {
	latencies []time.Duration
	verified  int64
	errors    int64
}

// runPhase runs a workload phase with per-request latency tracking.
// workFn returns the WORK command for a given (workerIdx, requestIdx).
func runPhase(name string, addr string, numRequests int, concurrency int,
	workFn func(workerIdx, reqIdx int) (cmd string, expectedN int, expectedID string)) {

	requestsPerWorker := numRequests / concurrency

	var mu sync.Mutex
	allLatencies := make([]time.Duration, 0, numRequests)
	var totalVerified, totalErrors int64

	t0 := time.Now()
	var wg sync.WaitGroup
	wg.Add(concurrency)

	for w := 0; w < concurrency; w++ {
		go func(workerIdx int) {
			defer wg.Done()
			conn, err := net.Dial("tcp", addr)
			if err != nil {
				fmt.Fprintf(os.Stderr, "connect error: %v\n", err)
				return
			}
			defer conn.Close()
			reader := bufio.NewReader(conn)

			var localLats []time.Duration
			var verified, errs int64

			for r := 0; r < requestsPerWorker; r++ {
				cmd, expectedN, expectedID := workFn(workerIdx, r)
				idNum, _ := strconv.ParseInt(expectedID, 10, 64)
				expected := fmt.Sprintf("%d", heavyCompute(idNum, expectedN))

				start := time.Now()
				resp, err := sendCommand(conn, reader, cmd)
				elapsed := time.Since(start)

				if err != nil {
					errs++
					continue
				}
				localLats = append(localLats, elapsed)

				if len(resp) > 1 && resp[0] == ':' && resp[1:] == expected {
					verified++
				} else {
					errs++
				}
			}

			sendCommand(conn, reader, "QUIT")

			mu.Lock()
			allLatencies = append(allLatencies, localLats...)
			totalVerified += verified
			totalErrors += errs
			mu.Unlock()
		}(w)
	}

	wg.Wait()
	elapsed := time.Since(t0)

	// Compute percentiles
	sort.Slice(allLatencies, func(i, j int) bool { return allLatencies[i] < allLatencies[j] })
	n := len(allLatencies)
	p50 := time.Duration(0)
	p99 := time.Duration(0)
	p999 := time.Duration(0)
	if n > 0 {
		p50 = allLatencies[n*50/100]
		p99 = allLatencies[n*99/100]
		idx999 := n * 999 / 1000
		if idx999 >= n {
			idx999 = n - 1
		}
		p999 = allLatencies[idx999]
	}

	throughput := float64(n) / elapsed.Seconds()

	fmt.Printf("%s (%d requests, %d concurrent)\n", name, numRequests, concurrency)
	fmt.Printf("  Time: %d ms\n", elapsed.Milliseconds())
	fmt.Printf("  Throughput: %.0f req/s\n", throughput)
	fmt.Printf("  p50: %.2f ms  p99: %.2f ms  p99.9: %.2f ms\n",
		float64(p50.Microseconds())/1000.0,
		float64(p99.Microseconds())/1000.0,
		float64(p999.Microseconds())/1000.0)
	fmt.Printf("  Verified: %d / %d\n", totalVerified, int64(numRequests))
	if totalErrors > 0 {
		fmt.Printf("  Errors: %d\n", totalErrors)
	}
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: ./client <server-pid> [port] [num-requests] [concurrency]")
		os.Exit(1)
	}

	pid := os.Args[1]
	port := 6390
	numRequests := 5000
	concurrency := 50

	if len(os.Args) > 2 {
		port, _ = strconv.Atoi(os.Args[2])
	}
	if len(os.Args) > 3 {
		numRequests, _ = strconv.Atoi(os.Args[3])
	}
	if len(os.Args) > 4 {
		concurrency, _ = strconv.Atoi(os.Args[4])
	}

	addr := fmt.Sprintf("127.0.0.1:%d", port)

	// Wait for server
	for i := 0; i < 20; i++ {
		conn, err := net.Dial("tcp", addr)
		if err == nil {
			reader := bufio.NewReader(conn)
			resp, _ := sendCommand(conn, reader, "READY?")
			conn.Close()
			if resp == "+READY" {
				break
			}
		}
		time.Sleep(250 * time.Millisecond)
	}

	rng := rand.New(rand.NewSource(42))

	_, rssBeforePhases := readServerRSS(pid)
	fmt.Printf("\nServer Memory:\n  RSS before: %d KB\n", rssBeforePhases)

	// Phase 1: Uniform
	runPhase("Phase 1: Uniform", addr, numRequests, concurrency,
		func(workerIdx, reqIdx int) (string, int, string) {
			id := fmt.Sprintf("%d", workerIdx*10000+reqIdx)
			return fmt.Sprintf("WORK:%s:100", id), 100, id
		})

	// Phase 2: Skewed (0.5% heavy, 1-in-200 so p99 is meaningful)
	heavySet := make(map[int]bool)
	for i := 0; i < numRequests/200; i++ {
		heavySet[rng.Intn(numRequests)] = true
	}
	globalReqIdx := 0
	var idxMu sync.Mutex

	runPhase("Phase 2: Skewed (0.5% heavy)", addr, numRequests, concurrency,
		func(workerIdx, reqIdx int) (string, int, string) {
			idxMu.Lock()
			idx := globalReqIdx
			globalReqIdx++
			idxMu.Unlock()

			id := fmt.Sprintf("%d", idx)
			n := 10
			if heavySet[idx] {
				n = 10000
			}
			return fmt.Sprintf("WORK:%s:%d", id, n), n, id
		})

	// Phase 3: Adversarial (connection 0 = all heavy)
	runPhase("Phase 3: Adversarial (1 heavy conn)", addr, numRequests, concurrency,
		func(workerIdx, reqIdx int) (string, int, string) {
			id := fmt.Sprintf("adv_%d_%d", workerIdx, reqIdx)
			n := 10
			if workerIdx == 0 {
				n = 10000
			}
			return fmt.Sprintf("WORK:%s:%d", id, n), n, id
		})

	hwm, rssAfter := readServerRSS(pid)
	fmt.Printf("\nServer Memory:\n  RSS after: %d KB\n  Peak RSS (VmHWM): %d KB\n", rssAfter, hwm)
}
