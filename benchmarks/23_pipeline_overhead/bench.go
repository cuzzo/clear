// Benchmark 23: Pipeline Overhead — Go Baseline
//
// Test 1: Simple sum of 10M float64 values, 20 iterations.
// Test 2: Fused filter (>500.0) + square + sum, 20 iterations.
//
// Data: deterministic LCG
//   state = state * 6364136223846793005 + (i + 1442695040888963407)
//   val = abs(state % 1000) as float64
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

const (
	N    = 10_000_000
	ITER = 20
)

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
	fields := strings.Fields(line)
	if len(fields) >= 2 {
		v, _ := strconv.ParseInt(fields[1], 10, 64)
		return v
	}
	return 0
}

func buildData(n int64) []float64 {
	data := make([]float64, n)
	state := int64(42)
	for i := int64(0); i < n; i++ {
		state = state*6364136223846793005 + (i + 1442695040888963407)
		val := state % 1000
		if val < 0 {
			val = -val
		}
		data[i] = float64(val)
	}
	return data
}

func sumLoop(data []float64) float64 {
	sum := 0.0
	for _, v := range data {
		sum += v
	}
	return sum
}

func fusedLoop(data []float64) float64 {
	sum := 0.0
	for _, v := range data {
		if v > 500.0 {
			sum += v * v
		}
	}
	return sum
}

func main() {
	data := buildData(N)
	accum := 0.0

	// ---- Test 1: Simple sum, 20 iterations ----
	t0 := time.Now()
	for r := 0; r < ITER; r++ {
		accum += sumLoop(data)
	}
	sumMs := time.Since(t0).Milliseconds()
	_, sumRSS := readMemory()

	// ---- Test 2: Fused filter+square+sum, 20 iterations ----
	t1 := time.Now()
	for r := 0; r < ITER; r++ {
		accum += fusedLoop(data)
	}
	fusedMs := time.Since(t1).Milliseconds()
	fusedHWM, _ := readMemory()

	// Prevent DCE
	if accum == 0.0 {
		fmt.Println("unexpected zero")
		return
	}

	// ---- Report ----
	fmt.Printf("Elements: %d\n", N)
	fmt.Printf("Iterations: %d\n", ITER)
	fmt.Printf("Handwritten loop: %d ms\n", sumMs)
	fmt.Printf("Fused loop: %d ms\n", fusedMs)
	fmt.Printf("RSS after: %d KB\n", sumRSS)
	fmt.Printf("Peak RSS: %d KB\n", fusedHWM)
}
