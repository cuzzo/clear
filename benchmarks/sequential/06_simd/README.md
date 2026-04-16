# Benchmark 07: SIMD / Auto-vectorization

Vec4 dot product, 100 million iterations. `b` is constant `{1,2,3,4}`, `a.xyzw = {i, i+1, i+2, i+3}`.

- C: explicit AVX2 intrinsics (`_mm256_set_pd`, `_mm256_mul_pd`, `_mm_hadd_pd`)
- CLEAR: plain struct field access — `a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w`

## Results

| Language | Time | vs C |
|----------|------|------|
| C (`gcc -O3`, explicit AVX2) | ~209ms | baseline |
| CLEAR (`--optimized`, LLVM auto-vec) | ~152ms | -27% |

CLEAR beats C. LLVM's auto-vectorizer tiles the outer loop across 4 loop iterations using `vmulpd ymm`, and avoids the horizontal-reduction latency that the C explicit-AVX2 path incurs via `_mm_hadd_pd`. GCC's explicit intrinsic approach is suboptimal here.

CLEAR has no SIMD vector types. The win is purely from LLVM's loop vectorizer recognizing the induction structure of `a` and the loop-invariant `b`.
