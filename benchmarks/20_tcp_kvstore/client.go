// Benchmark 20: RESP client for TCP KV Store servers.
//
// Usage: ./client <server-pid> [port] [num-gets] [concurrency]
//
// Phase 1: SET 1..1000 keys (sequential, pipelined RESP)
// Phase 2: N GETs (concurrent, C connections, pipelined RESP)
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

// RESP protocol helpers
func respCmd(args ...string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "*%d\r\n", len(args))
	for _, a := range args {
		fmt.Fprintf(&b, "$%d\r\n%s\r\n", len(a), a)
	}
	return b.String()
}

func readResp(reader *bufio.Reader) (string, error) {
	line, err := reader.ReadString('\n')
	if err != nil {
		return "", err
	}
	line = strings.TrimRight(line, "\r\n")
	if len(line) == 0 {
		return "", fmt.Errorf("empty response")
	}
	switch line[0] {
	case '+', '-', ':':
		return line, nil
	case '$':
		n, _ := strconv.Atoi(line[1:])
		if n < 0 {
			return "$-1", nil
		}
		buf := make([]byte, n+2) // data + \r\n
		_, err := reader.Read(buf)
		if err != nil {
			return "", err
		}
		return string(buf[:n]), nil
	default:
		return line, nil
	}
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

	// Wait for server to be ready (inline READY? command)
	for i := 0; i < 50; i++ {
		conn, err := net.DialTimeout("tcp", addr, 200*time.Millisecond)
		if err != nil {
			time.Sleep(100 * time.Millisecond)
			continue
		}
		reader := bufio.NewReader(conn)
		fmt.Fprintf(conn, "READY?\r\n")
		resp, err := readResp(reader)
		conn.Close()
		if err == nil && resp == "+READY" {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	_, rssBeforeSets := readServerRSS(pid)

	// ---- Phase 1: SET 1..1000 (sequential, pipelined) ----
	fmt.Printf("Phase 1: SET 1..1000\n")
	t0 := time.Now()
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "connect error: %v\n", err)
		os.Exit(1)
	}
	reader := bufio.NewReader(conn)
	for id := 1; id <= 1000; id++ {
		key := fmt.Sprintf("key:%d", id)
		val := fmt.Sprintf("value:%d", id)
		fmt.Fprint(conn, respCmd("SET", key, val))
		resp, err := readResp(reader)
		if err != nil || resp != "+OK" {
			fmt.Fprintf(os.Stderr, "SET %s failed: resp=%q err=%v\n", key, resp, err)
			os.Exit(1)
		}
	}
	fmt.Fprint(conn, respCmd("QUIT"))
	readResp(reader)
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
	allIDs := make([]int, numGets)
	for i := range allIDs {
		allIDs[i] = rng.Intn(1000) + 1
	}

	for w := 0; w < concurrency; w++ {
		wg.Add(1)
		start := w * getsPerWorker
		end := start + getsPerWorker
		if w == concurrency-1 {
			end = numGets
		}
		workerIDs := allIDs[start:end]

		go func(ids []int) {
			defer wg.Done()
			c, err := net.Dial("tcp", addr)
			if err != nil {
				errors.Add(int64(len(ids)))
				return
			}
			defer c.Close()
			r := bufio.NewReader(c)
			for _, id := range ids {
				key := fmt.Sprintf("key:%d", id)
				fmt.Fprint(c, respCmd("GET", key))
				resp, err := readResp(r)
				if err != nil {
					errors.Add(1)
					continue
				}
				expected := fmt.Sprintf("value:%d", id)
				if resp == expected {
					verified.Add(1)
				} else if resp == "$-1" {
					errors.Add(1)
				} else {
					errors.Add(1)
				}
			}
			fmt.Fprint(c, respCmd("QUIT"))
			readResp(r)
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
