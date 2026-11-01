# Non-tag quads in the GPU detector (2026-11-01)

How many of the quads the 971 GPU detector hands to corner refinement and decode turn out to be tags? And how
much CPU would a cheap early decode save (border + code checked with slack, NAPA-style; `../napa-eval`) if it
rejected non-tags before `RefineEdges` and undistortion?

## Files

| File | What |
|---|---|
| `instrument.py` | Adds counters to a **copy** of bos's `third_party/971apriltag`: quads reaching `QuadDecodeTask`, per-quad `RefineEdges` and decode time, and whether each quad decoded to a tag. With `SPECTRUM_QS_EARLY=1`, each quad is also decoded on its unrefined corners first: a stand-in for the early decode (a full decode, no slack), so an upper bound on its cost and on the tags it would lose. One line per frame to `$SPECTRUM_QS_OUT` |
| `build.sh` | Builds the instrumented `detector-replay` on the Jetson (`~/build/nontag-quads`). It never touches the installed library or `~/build/gpu-detector` |
| `run.sh` | All TXMAN1 sessions, with the settings as installed: mwbd 20, mse 10, CPU refine (`GPU_REFINE` unset, ladder level 3), calibrations, far search off |
| `analyze.py` | Per session and camera, and totals |
| `results/analyze.txt` | This run |

## Results (all 13 TXMAN1 sessions, 54,400 frames)

Per busy frame (one with at least one quad: 100% of field frames). CPU is the decode workers' CPU time,
summed over quads (the workers run 4 threads, so wall time is lower).

| | Quads | Tags | Non-tag | RefineEdges CPU (non-tag) | Decode CPU (non-tag) | Early decode CPU | Tags kept by the early decode | Saved |
|---|---|---|---|---|---|---|---|---|
| All | 14.9 | 0.71 | **95.2%** | 394 µs (378) | 72 µs (68) | 99 µs | 96.5% | **347 µs (74%)** |
| orin-left | 13.9 | 0.73 | 94.7% | 310 µs (293) | 67 µs (62) | 94 µs | 95.6% | 261 µs (69%) |
| orin-right | 16.1 | 0.69 | 95.7% | 492 µs (476) | 79 µs (74) | 105 µs | 97.5% | 445 µs (78%) |

- Per session, 91–100% of quads are non-tags. Quads per frame range from 8 to 24, with the most in crowded,
  well-lit scenes (Test_r19 orin-right: 24).
- The early decode on unrefined corners lets through only 0.10% of non-tags. With no slack it loses 3.5% of
  real tags. A NAPA-style decode with 2 bits of slack on the border and code would keep most of them; the
  final decode after refinement still enforces hamming 1.
- Saved = non-tag refine + decode − early decode = **~350 µs of worker CPU per busy frame per camera**, ~4%
  of a core at 122 fps, ~0.17 cores for 4 cameras. The workers' wall time (178 µs a frame) should drop roughly in proportion; it
  wasn't measured with the early check in place.
- The replay's refine + decode is 466 µs a frame, against ~850 µs measured live (`docs/TECHNICAL.md`,
  `detector-13`: live adds contention, CUDA waits and cache misses). Live savings should scale with it, to
  ~600 µs.
- **GPU refine modes (ladder levels 4/5):** the refine kernel (~70 µs a frame) and the float decode kernel
  (~87 µs) run one thread block per quad, and 95% of those quads are non-tags. With ~15 quads, though, the
  kernels are latency-bound (a few SMs busy, launch and sync dominate). Rejecting non-tags first would save
  well under 95% of ~160 µs, likely tens of µs, and only if the early check itself ran on the GPU in the same
  graph. At level 5 the CPU is already down to 134 µs a frame.

## Recommendation

- **Worth building for the CPU path (ladder level 3, uncalibrated cameras, and any CPU-only target running
  the 971 code):** ~350–600 µs of worker CPU per busy frame per camera, for a ~100-line change in
  `QuadDecodeTask`. Use a cheap check rather than a full decode (border ring + payload sampled through the
  quad's homography, 2 bits of slack), then the normal refine + hamming-1 decode on survivors. Check on
  TXMAN1 that no tags are lost, with `run.sh` and the judge.
- **Not worth it for levels 4/5:** the GPU work non-tags cost is small in absolute terms (tens of µs), and
  level 5 has already moved the CPU cost off the CPU.
- Since the recommended default is moving to level 5, this is low priority unless the robot stays on
  level 3.
