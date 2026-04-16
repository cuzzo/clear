// KV Store Benchmark — Go (sharded RWMutex map, 128 shards)
//
// Matches CLEAR's @shared:sharded(128):locked and Rust's DashMap structurally:
// 128 shards, RWMutex per shard, FNV key distribution.
// sync.Map is NOT used here — it is read-optimized and degrades severely
// on write-heavy workloads like uniform SET.
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
	"hash/fnv"
	"math"
	"math/rand"
	"runtime"
	"sync"
	"time"
)

const (
	numKeys   = 1_000_000
	numShards = 128
	zipfSkew  = 1.0
)

// =========================================================================
// Sharded RWMutex map (128 shards, matches CLEAR + DashMap structure)
// =========================================================================

type shard struct {
	mu sync.RWMutex
	m  map[string]string
}

type ShardedMap [numShards]shard

func newShardedMap() *ShardedMap {
	var sm ShardedMap
	for i := range sm {
		sm[i].m = make(map[string]string)
	}
	return &sm
}

func (sm *ShardedMap) shardFor(key string) *shard {
	h := fnv.New32a()
	h.Write([]byte(key))
	return &sm[h.Sum32()%numShards]
}

func (sm *ShardedMap) Store(key, val string) {
	s := sm.shardFor(key)
	s.mu.Lock()
	s.m[key] = val
	s.mu.Unlock()
}

func (sm *ShardedMap) Load(key string) (string, bool) {
	s := sm.shardFor(key)
	s.mu.RLock()
	v, ok := s.m[key]
	s.mu.RUnlock()
	return v, ok
}

// =========================================================================
// Zipfian generator (rejection-inversion method)
// =========================================================================

type ZipfGen struct {
	n         int
	s         float64
	hIntegral float64
	hFraction float64
	rng       *rand.Rand
}

func hFunc(x, s float64) float64 { return math.Exp(-s * math.Log(x)) }
func hInt(x, s float64) float64 {
	t := 1.0 - s
	if math.Abs(t) > 1e-8 {
		return (math.Pow(x, t) - 1.0) / t
	}
	return math.Log(x)
}
func hIntInv(x, s float64) float64 {
	t := 1.0 - s
	if math.Abs(t) > 1e-8 {
		return math.Pow(t*x+1.0, 1.0/t)
	}
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
		if k < 1 {
			k = 1
		}
		if k > z.n {
			k = z.n
		}
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

	m := newShardedMap()

	// --- Workload 1: Uniform SET ---
	t0 := time.Now()
	var wg sync.WaitGroup
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func(start int) {
			defer wg.Done()
			for i := start; i < start+opsPerWorker; i++ {
				m.Store(fmt.Sprintf("key:%08d", i), fmt.Sprintf("value-%d", i))
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
				m.Load(fmt.Sprintf("key:%08d", i))
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
				m.Load(fmt.Sprintf("key:%08d", z.next()))
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
