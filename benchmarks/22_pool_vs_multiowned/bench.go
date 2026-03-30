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

const N = 1000000

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

// Variant A: append structs to a slice (dense array, like @list)
func benchSlice() int64 {
	items := make([]Entity, 0, N)

	for i := int64(0); i < N; i++ {
		items = append(items, Entity{x: i, y: i * 2, health: 100})
	}

	return int64(len(items))
}

// Variant B: allocate each struct with new(), store pointers (like @multiowned / Rc)
func benchPointer() int64 {
	ptrs := make([]*Entity, 0, N)

	for i := int64(0); i < N; i++ {
		e := new(Entity)
		e.x = i
		e.y = i * 2
		e.health = 100
		ptrs = append(ptrs, e)
	}

	return int64(len(ptrs))
}

func main() {
	// Variant A: slice (dense)
	t0 := time.Now()
	sliceCount := benchSlice()
	sliceMs := time.Since(t0).Milliseconds()
	_, sliceRSS := readMemory()

	// Variant B: pointer-based
	t1 := time.Now()
	ptrCount := benchPointer()
	ptrMs := time.Since(t1).Milliseconds()
	ptrHWM, ptrRSS := readMemory()

	fmt.Printf("Pool vs Pointer insert (%d entities) — Go baseline\n", N)
	fmt.Printf("  Slice (dense array): %d ms  RSS %d KB\n", sliceMs, sliceRSS)
	fmt.Printf("  Pointer (scattered): %d ms  RSS %d KB\n", ptrMs, ptrRSS)
	fmt.Printf("  Peak RSS (VmHWM):    %d KB\n", ptrHWM)
	fmt.Printf("  slice_count=%d  ptr_count=%d\n", sliceCount, ptrCount)
}
