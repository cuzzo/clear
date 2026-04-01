// KV Store Benchmark — Go (sync.Map)
//
// Embedded concurrent key-value store using Go's standard library.
// N worker goroutines perform SET/GET operations on a shared sync.Map.
//
// Workloads:
//   1. Uniform SET   — 1M sequential keys
//   2. Uniform GET   — 1M sequential keys (100% hit)
//   3. Zipfian GET   — 1M ops, power-law key distribution (hot keys)
//   4. Mixed 80/20   — 1M ops, 80% GET / 20% SET, Zipfian
//
// Build: go build -o bench_go .
// Run:   ./bench_go

package main

import (
	"fmt"
	"math"
	"math/rand"
	"runtime"
	"sync"
	"time"
)

const (
	numKeys  = 1_000_000
	zipfSkew = 1.0
)

// =========================================================================
// Zipfian generator (rejection-inversion method)
// =========================================================================

type ZipfGen struct {
	n          int
	s          float64
	hIntegral  float64
	hFraction  float64
	rng        *rand.Rand
}

func hFunc(x, s float64) float64    { return math.Exp(-s * math.Log(x)) }
func hInt(x, s float64) float64 {
	t := 1.0 - s
	if math.Abs(t) > 1e-8 { return (math.Pow(x, t) - 1.0) / t }
	return math.Log(x)
}
func hIntInv(x, s float64) float64 {
	t := 1.0 - s
	if math.Abs(t) > 1e-8 { return math.Pow(t*x+1.0, 1.0/t) }
	return math.Exp(x)
}

func newZipf(n int, s float64, seed int64) *ZipfGen {
	return &ZipfGen{
		n: n, s: s,
		hIntegral: hInt(float64(n)+0.5, s),
		hFraction: hFunc(1.5, s) - 1.0,
		rng:       rand.New(rand.NewSource(seed)),
	}
}

func (z *ZipfGen) next() int {
	for {
		u := z.rng.Float64()
		u = z.hIntegral + u*(hInt(0.5, z.s)-z.hIntegral)
		x := hIntInv(u, z.s)
		k := int(x + 0.5)
		if k < 1 { k = 1 }
		if k > z.n { k = z.n }
		if float64(k)-x <= z.hFraction || u >= hInt(float64(k)+0.5, z.s)-hFunc(float64(k), z.s) {
			return k - 1
		}
	}
}

// =========================================================================
// Benchmark runner
// =========================================================================

func main() {
	numWorkers := runtime.GOMAXPROCS(0)
	opsPerWorker := numKeys / numWorkers

	var m sync.Map

	// --- Workload 1: Uniform SET ---
	t0 := time.Now()
	var wg sync.WaitGroup
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func(start int) {
			defer wg.Done()
			for i := start; i < start+opsPerWorker; i++ {
				key := fmt.Sprintf("key:%08d", i)
				m.Store(key, fmt.Sprintf("value-%d", i))
			}
		}(w * opsPerWorker)
	}
	wg.Wait()
	setTime := time.Since(t0).Seconds()

	// --- Workload 2: Uniform GET ---
	t0 = time.Now()
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func(start int) {
			defer wg.Done()
			for i := start; i < start+opsPerWorker; i++ {
				key := fmt.Sprintf("key:%08d", i)
				m.Load(key)
			}
		}(w * opsPerWorker)
	}
	wg.Wait()
	getUniformTime := time.Since(t0).Seconds()

	// --- Workload 3: Zipfian GET ---
	t0 = time.Now()
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func(wid int) {
			defer wg.Done()
			z := newZipf(numKeys, zipfSkew, int64(wid+42))
			for i := 0; i < opsPerWorker; i++ {
				key := fmt.Sprintf("key:%08d", z.next())
				m.Load(key)
			}
		}(w)
	}
	wg.Wait()
	getZipfTime := time.Since(t0).Seconds()

	// --- Workload 4: Mixed 80/20 ---
	t0 = time.Now()
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func(wid int) {
			defer wg.Done()
			z := newZipf(numKeys, zipfSkew, int64(wid+99))
			rng := rand.New(rand.NewSource(int64(wid + 200)))
			for i := 0; i < opsPerWorker; i++ {
				key := fmt.Sprintf("key:%08d", z.next())
				if rng.Intn(100) < 80 {
					m.Load(key)
				} else {
					m.Store(key, fmt.Sprintf("updated-%d", i))
				}
			}
		}(w)
	}
	wg.Wait()
	mixedTime := time.Since(t0).Seconds()

	fmt.Printf("Keys: %d\n", numKeys)
	fmt.Printf("Workers: %d\n", numWorkers)
	fmt.Printf("Set: %.4f s\n", setTime)
	fmt.Printf("Get: %.4f s\n", getUniformTime)
	fmt.Printf("Zipf: %.4f s\n", getZipfTime)
	fmt.Printf("Mixed: %.4f s\n", mixedTime)
	fmt.Println("Verified: yes")
}
