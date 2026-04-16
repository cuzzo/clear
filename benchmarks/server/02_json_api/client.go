// Benchmark 24: Shared client for CLEAR and Go JSON API servers.
//
// Usage: ./client <server-pid> [port] [num-gets] [concurrency]
//
// Phase 1: 1000 SETs (sequential, single connection)
// Phase 2: N GETs (concurrent, C connections)
// Measures server peak RSS via /proc/<pid>/status.

package main

import (
	"bufio"
	"fmt"
	"math/rand"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func sizeForId(id int64) int64 {
	return ((id*7 + 13) % 997) + 10
}

func expectedSum(id int64) int64 {
	sz := sizeForId(id)
	return sz * (sz + 1) / 2
}

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

func sendCommand(conn net.Conn, reader *bufio.Reader, cmd string) (string, error) {
	fmt.Fprintf(conn, "%s\r\n", cmd)
	line, err := reader.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "Usage: %s <server-pid> [port] [num-gets] [concurrency]\n", os.Args[0])
		os.Exit(1)
	}

	pid := os.Args[1]
	port := "6390"
	numGets := 10000
	concurrency := 50

	if len(os.Args) > 2 {
		port = os.Args[2]
	}
	if len(os.Args) > 3 {
		numGets, _ = strconv.Atoi(os.Args[3])
	}
	if len(os.Args) > 4 {
		concurrency, _ = strconv.Atoi(os.Args[4])
	}

	addr := fmt.Sprintf("127.0.0.1:%s", port)

	// Wait for server to be ready
	for i := 0; i < 50; i++ {
		conn, err := net.DialTimeout("tcp", addr, 200*time.Millisecond)
		if err != nil {
			time.Sleep(100 * time.Millisecond)
			continue
		}
		reader := bufio.NewReader(conn)
		resp, err := sendCommand(conn, reader, "READY?")
		conn.Close()
		if err == nil && resp == "+READY" {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	_, rssBeforeSets := readServerRSS(pid)

	// ---- Phase 1: SET 1..1000 (sequential) ----
	fmt.Printf("Phase 1: SET 1..1000\n")
	t0 := time.Now()
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect error: %v\n", err)
		os.Exit(1)
	}
	reader := bufio.NewReader(conn)
	for id := int64(1); id <= 1000; id++ {
		resp, err := sendCommand(conn, reader, fmt.Sprintf("SET:%d", id))
		if err != nil || resp != "+OK" {
			fmt.Fprintf(os.Stderr, "SET:%d failed: resp=%q err=%v\n", id, resp, err)
			os.Exit(1)
		}
	}
	sendCommand(conn, reader, "QUIT")
	conn.Close()
	setMs := time.Since(t0).Milliseconds()
	fmt.Printf("  SET phase: %d ms\n", setMs)

	_, rssAfterSets := readServerRSS(pid)

	// ---- Phase 2: GET (concurrent) ----
	fmt.Printf("Phase 2: %d GETs (%d concurrent connections)\n", numGets, concurrency)
	t1 := time.Now()

	var errors atomic.Int64
	var verified atomic.Int64
	var wg sync.WaitGroup

	getsPerWorker := numGets / concurrency
	rng := rand.New(rand.NewSource(42))
	// Pre-generate random IDs for determinism
	allIDs := make([]int64, numGets)
	for i := range allIDs {
		allIDs[i] = int64(rng.Intn(1000)) + 1
	}

	for w := 0; w < concurrency; w++ {
		wg.Add(1)
		start := w * getsPerWorker
		end := start + getsPerWorker
		if w == concurrency-1 {
			end = numGets // last worker gets remainder
		}
		workerIDs := allIDs[start:end]

		go func(ids []int64) {
			defer wg.Done()
			c, err := net.Dial("tcp", addr)
			if err != nil {
				errors.Add(int64(len(ids)))
				return
			}
			defer c.Close()
			r := bufio.NewReader(c)
			for _, id := range ids {
				resp, err := sendCommand(c, r, fmt.Sprintf("GET:%d", id))
				if err != nil {
					errors.Add(1)
					continue
				}
				if !strings.HasPrefix(resp, ":") {
					errors.Add(1)
					continue
				}
				got, _ := strconv.ParseInt(resp[1:], 10, 64)
				want := expectedSum(id)
				if got == want {
					verified.Add(1)
				} else {
					fmt.Fprintf(os.Stderr, "MISMATCH id=%d got=%d want=%d\n", id, got, want)
					errors.Add(1)
				}
			}
			sendCommand(c, r, "QUIT")
		}(workerIDs)
	}

	wg.Wait()
	getMs := time.Since(t1).Milliseconds()

	hwmAfterGets, rssAfterGets := readServerRSS(pid)

	// ---- Report ----
	fmt.Printf("  GET phase: %d ms\n", getMs)
	fmt.Printf("  Verified:  %d / %d\n", verified.Load(), numGets)
	fmt.Printf("  Errors:    %d\n", errors.Load())
	fmt.Println()
	fmt.Printf("Server Memory:\n")
	fmt.Printf("  RSS before SETs:  %d KB\n", rssBeforeSets)
	fmt.Printf("  RSS after SETs:   %d KB\n", rssAfterSets)
	fmt.Printf("  RSS after GETs:   %d KB\n", rssAfterGets)
	fmt.Printf("  Peak RSS (VmHWM): %d KB\n", hwmAfterGets)
}
