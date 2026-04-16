// Benchmark 22: Slice vs Pointer-based — Insert Cost (Go baseline)
//
// Variant A: Append structs to a slice (like CLEAR's @list / dense array).
// Variant B: Allocate each struct with new(), store pointers in a slice (like @multiowned / Rc).
//
// Run: go run bench.go

package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

const N = 5000000

type Entity struct {
	x      int64
	y      int64
	health int64
}

func readMemory() (vmHWM, vmRSS int64) {
	f, err := os.Open("/proc/self/status")
	if err != nil {
		return 0, 0
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "VmHWM:") {
			vmHWM = parseKB(line)
		} else if strings.HasPrefix(line, "VmRSS:") {
			vmRSS = parseKB(line)
		}
	}
	return
}

func parseKB(line string) int64 {
	// Line format: "VmHWM:    12345 kB"
	fields := strings.Fields(line)
	if len(fields) >= 2 {
		v, _ := strconv.ParseInt(fields[1], 10, 64)
		return v
	}
	return 0
}

// Variant A: append structs to a slice (dense array, like CLEAR @list)
func benchSlice() int64 {
	items := make([]Entity, 0, N)
	for i := int64(0); i < N; i++ {
		items = append(items, Entity{x: i, y: i * 2, health: 100})
	}
	var sum int64
	for _, e := range items {
		sum += e.health
	}
	return sum
}

// Variant B: allocate each struct with new(), store pointers (like CLEAR @pool / Rc)
func benchPointer() int64 {
	ptrs := make([]*Entity, 0, N)
	for i := int64(0); i < N; i++ {
		e := new(Entity)
		e.x = i
		e.y = i * 2
		e.health = 100
		ptrs = append(ptrs, e)
	}
	var sum int64
	for _, e := range ptrs {
		sum += e.health
	}
	return sum
}

func main() {
	// Variant A: slice (dense) — BENCH_RESULT
	t0 := time.Now()
	sliceSum := benchSlice()
	sliceMs := time.Since(t0).Milliseconds()
	_, sliceRSS := readMemory()

	// Variant B: pointer-based
	t1 := time.Now()
	ptrSum := benchPointer()
	ptrMs := time.Since(t1).Milliseconds()
	ptrHWM, ptrRSS := readMemory()

	if sliceSum != ptrSum {
		fmt.Fprintf(os.Stderr, "sum mismatch: %d != %d\n", sliceSum, ptrSum)
		os.Exit(1)
	}

	fmt.Printf("BENCH_RESULT: %d ms\n", sliceMs)
	fmt.Printf("Pool vs List (%d entities, insert + sum health) -- Go baseline\n", N)
	fmt.Printf("  Slice (dense):    %d ms  RSS %d KB\n", sliceMs, sliceRSS)
	fmt.Printf("  Pointer (N news): %d ms  RSS %d KB\n", ptrMs, ptrRSS)
	fmt.Printf("  Pointer overhead: %d ms\n", ptrMs-sliceMs)
	fmt.Printf("  Peak RSS (VmHWM): %d KB\n", ptrHWM)
}
