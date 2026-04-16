package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

const N = 10000000
const ITER = 20

func readMemory() (vmHWM, vmRSS int64) {
	data, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0, 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "VmHWM:") {
			vmHWM = parseKB(line)
		} else if strings.HasPrefix(line, "VmRSS:") {
			vmRSS = parseKB(line)
		}
	}
	return
}

func parseKB(line string) int64 {
	parts := strings.Fields(line)
	if len(parts) >= 2 {
		v, _ := strconv.ParseInt(parts[1], 10, 64)
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

func longFusedLoop(data []float64) float64 {
	sum := 0.0
	for _, v := range data {
		if v > 200.0 {
			doubled := v * 2.0
			if doubled < 1500.0 {
				sum += doubled
			}
		}
	}
	return sum
}

func main() {
	data := buildData(N)
	accum := 0.0

	t0 := time.Now()
	for r := 0; r < ITER; r++ {
		accum += sumLoop(data)
	}
	sumLoopMs := time.Since(t0).Milliseconds()

	t1 := time.Now()
	for r := 0; r < ITER; r++ {
		accum += fusedLoop(data)
	}
	fusedMs := time.Since(t1).Milliseconds()

	t2 := time.Now()
	for r := 0; r < ITER; r++ {
		accum += longFusedLoop(data)
	}
	longFusedMs := time.Since(t2).Milliseconds()

	if accum == 0.0 {
		fmt.Println("unexpected zero")
		os.Exit(1)
	}

	hwm, _ := readMemory()

	// BENCH_RESULT = sum loop (cross-language baseline for CLEAR pipeline comparison)
	fmt.Printf("BENCH_RESULT: %d ms\n", sumLoopMs)
	fmt.Printf("Pipeline overhead (%d elements x %d iters) -- Go baseline\n", N, ITER)
	fmt.Printf("  Sum loop (handwritten):    %d ms\n", sumLoopMs)
	fmt.Printf("  Fused loop (2-stage):      %d ms\n", fusedMs)
	fmt.Printf("  Fused loop (4-stage):      %d ms\n", longFusedMs)
	fmt.Printf("  Peak RSS: %d KB\n", hwm)
}
