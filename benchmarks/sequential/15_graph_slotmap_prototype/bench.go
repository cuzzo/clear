package main

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"time"
)

const edgeCount = 4

type Node struct {
	value uint64
	edges [edgeCount]*Node
}

func capacity() int {
	if raw := os.Getenv("BENCH_N"); raw != "" {
		if value, err := strconv.Atoi(raw); err == nil && value >= 4096 && value <= 1_048_576 {
			return value
		}
	}
	scale := 1.0
	if raw := os.Getenv("BENCH_SCALE"); raw != "" {
		if parsed, err := strconv.ParseFloat(raw, 64); err == nil {
			scale = parsed
		}
	}
	value := int(1_000_000 * scale)
	if value < 4096 {
		return 4096
	}
	return value
}

func evenAtLeast(value, minimum int) int {
	if value < minimum {
		value = minimum
	}
	return value + value&1
}

func localTarget(i, edge, core uint32) uint32 {
	return (i%core + edge + 1) % core
}

func randomTarget(i, edge, core uint32) uint32 {
	return (i*1664525 + (edge+1)*1013904223) % core
}

func milliseconds(value time.Duration) float64 {
	return float64(value.Nanoseconds()) / 1e6
}

func main() {
	capacity := capacity()
	core := capacity * 3 / 4
	churn := capacity - core
	readRounds := evenAtLeast(9_000_000/core, 12)
	writeRounds := evenAtLeast(1_000_000/capacity, 4)
	churnRounds := evenAtLeast(1_000_000/churn, 4)
	sparseRounds := 100_000_000 / capacity
	if sparseRounds < 100 {
		sparseRounds = 100
	}

	phase := time.Now()
	roots := make([]*Node, capacity)
	for i := range roots {
		roots[i] = &Node{value: uint64(i)}
	}
	for i := 0; i < capacity; i++ {
		for edge := 0; edge < edgeCount; edge++ {
			roots[i].edges[edge] = roots[localTarget(uint32(i), uint32(edge), uint32(core))]
		}
	}
	build := time.Since(phase)

	phase = time.Now()
	var localChecksum uint64
	for round := 0; round < readRounds; round++ {
		for i := 0; i < core; i++ {
			for edge := 0; edge < edgeCount; edge++ {
				localChecksum += roots[i].edges[edge].value
			}
		}
	}
	localRead := time.Since(phase)

	phase = time.Now()
	for round := 0; round < writeRounds; round++ {
		useRandom := round&1 != 0 || round+1 == writeRounds
		for i := 0; i < capacity; i++ {
			for edge := 0; edge < edgeCount; edge++ {
				target := localTarget(uint32(i), uint32(edge), uint32(core))
				if useRandom {
					target = randomTarget(uint32(i), uint32(edge), uint32(core))
				}
				roots[i].edges[edge] = roots[target]
			}
		}
	}
	edgeWrite := time.Since(phase)

	phase = time.Now()
	var randomChecksum uint64
	for round := 0; round < readRounds; round++ {
		for i := 0; i < core; i++ {
			for edge := 0; edge < edgeCount; edge++ {
				randomChecksum += roots[i].edges[edge].value
			}
		}
	}
	randomRead := time.Since(phase)

	phase = time.Now()
	for round := 0; round < churnRounds; round++ {
		for tail := 0; tail < churn; tail++ {
			node := &Node{value: uint64(tail + round)}
			for edge := 0; edge < edgeCount; edge++ {
				node.edges[edge] = roots[randomTarget(uint32(tail), uint32(edge), uint32(core))]
			}
			roots[core+tail] = node
		}
	}
	churnElapsed := time.Since(phase)

	var beforeCollapse runtime.MemStats
	runtime.ReadMemStats(&beforeCollapse)
	phase = time.Now()
	keep := capacity / 100
	if keep < 1 {
		keep = 1
	}
	for i := keep; i < capacity; i++ {
		roots[i] = nil
	}
	gcStart := time.Now()
	runtime.GC()
	gcElapsed := time.Since(gcStart)
	collapse := time.Since(phase)

	phase = time.Now()
	var sparseChecksum uint64
	for round := 0; round < sparseRounds; round++ {
		for _, root := range roots {
			if root != nil {
				sparseChecksum += root.value
			}
		}
	}
	sparseScan := time.Since(phase)

	var retained runtime.MemStats
	runtime.ReadMemStats(&retained)
	total := build + localRead + edgeWrite + randomRead + churnElapsed + collapse
	fmt.Printf("BENCH_RESULT: %.3f ms\n", milliseconds(total))
	fmt.Printf("BENCH_INFO: impl=go-tracing-gc nodes=%d roots_live=%d peak_heap_alloc_mib=%.2f retained_heap_alloc_mib=%.2f heap_sys_mib=%.2f gc_ms=%.3f local_checksum=%d random_checksum=%d\n",
		capacity, keep, float64(beforeCollapse.HeapAlloc)/(1024*1024),
		float64(retained.HeapAlloc)/(1024*1024), float64(retained.HeapSys)/(1024*1024),
		milliseconds(gcElapsed), localChecksum, randomChecksum)
	fmt.Printf("BENCH_PHASES: impl=go-tracing-gc build_ms=%.3f local_read_ms=%.3f edge_write_ms=%.3f random_read_ms=%.3f churn_ms=%.3f collapse_ms=%.3f sparse_scan_ms=%.3f sparse_checksum=%d\n",
		milliseconds(build), milliseconds(localRead), milliseconds(edgeWrite),
		milliseconds(randomRead), milliseconds(churnElapsed), milliseconds(collapse),
		milliseconds(sparseScan), sparseChecksum)
	runtime.KeepAlive(roots)
}
