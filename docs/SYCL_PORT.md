# Porting the 971 CUDA AprilTag detector to SYCL (Intel Arc)

Scoping notes for running the detector on an Intel GPU, such as the Arc 140V in a Core Ultra 7
256V (Lunar Lake) mini PC. Nothing here has been built yet; this is what the port would involve.

Source surveyed: frc971/bos `62e93b4` `third_party/971apriltag`, with our `patches/bos-*.patch`
applied (all apply cleanly), plus our `detector/` directory.

## Size

About 6,100 lines in total. The GPU code is in 5 files:

| File | Lines | Kernels | What it does |
| --- | --- | --- | --- |
| `threshold.cc` | 330 | 5 | colour/gray conversion, decimation, min/max tiles, threshold |
| `labeling_allegretti_2019_BKE.cc` | 499 | 4 | connected-component labelling (5 launches) |
| `apriltag.cc` | 1497 | 3 | mask, blob diff, pipeline orchestration, CUDA graph |
| `line_fit_filter.cc` | 1238 | 2 | line fitting and quad fitting |
| `cuda.h` / `cuda.cc` | 369 | – | stream, event and memory wrappers |

`apriltag_detect.cc`, `points.*` and the rest are host code or plain math that SYCL compiles unchanged.

## NVIDIA-specific pieces, from easiest to hardest

**1. Kernel launches and indexing (18 launches): easy, mechanical.**
`<<<grid, block, 0, stream>>>` becomes `queue.parallel_for(nd_range, ...)`, and
`threadIdx`/`blockIdx`/`blockDim` become `nd_item` calls. SYCLomatic does this automatically.
Note that CUDA's grid order is x,y while SYCL's is y,x, which SYCLomatic handles.

**2. Shared memory, `__syncthreads`, atomics (10 / 11 / 8 uses): easy.**
They become `local_accessor` / `group_barrier` / `atomic_ref`. `atomicMin` on local memory
is supported on Xe2.

**3. Runtime API (streams, events, memcpy, malloc): easy.**
- `cudaStream_t` → in-order `sycl::queue`
- `cudaMemcpyAsync` → `queue.memcpy`
- `cudaMalloc` / `cudaMallocHost` / `cudaMallocManaged` → `malloc_device` / `malloc_host` /
  `malloc_shared`
- events → `sycl::event` with profiling enabled

Lunar Lake's GPU shares memory with the processor like the Jetson's, so the zero-copy
approach still applies. Most of this lives in `cuda.h`, so rewriting that one file covers it.

**4. CUB device-wide algorithms (about 35 calls): medium.** Needs oneDPL replacements:

| CUB | oneDPL |
| --- | --- |
| `DeviceRadixSort::SortKeys` (7) | `oneapi::dpl::experimental::kt::gpu::esimd::radix_sort` or `std::sort` with a device policy |
| `DeviceSelect::If` (8) | `oneapi::dpl::copy_if` (the count comes from the returned iterator) |
| `DeviceScan::InclusiveScan` (3) | `oneapi::dpl::inclusive_scan` |
| `DeviceScan::InclusiveScanByKey` (3) | `oneapi::dpl::inclusive_scan_by_segment` |
| `DeviceReduce::ReduceByKey` (4) | `oneapi::dpl::reduce_by_segment` |
| `TransformInputIterator` / `ArgIndexInputIterator` / `DiscardOutputIterator` / `KeyValuePair` | `oneapi::dpl::transform_iterator` / `zip_iterator` + `counting_iterator` / `discard_iterator` / `std::pair` |

This isn't a copy-paste swap:
- CUB's two-phase "ask for temp storage size, then run" calls go away, so the scratch buffer
  code in `apriltag.cc` gets simpler, but its allocation and ordering logic has to change to match.
- oneDPL algorithms may synchronize the queue inside each call. That matters for latency
  (see 6), so measure it.

**5. Block- and warp-level CUB inside `DoFitQuads` (`line_fit_filter.cc:1107-1174`): medium, needs care.**
- `cub::BlockReduce<QuadError, ...>` → `sycl::reduce_over_group` with a custom minimum
  operation (it's a struct reduction, so pass the struct and the operation explicitly).
- `cub::WarpMergeSort<uint16_t, kItemsPerThread, kItems>` has no direct SYCL equivalent.
  Intel sub-groups are 16 or 32 wide (Xe2 prefers 16), versus NVIDIA's fixed 32. Options:
  - force `[[sycl::reqd_sub_group_size(32)]]` and write a small bitonic sort with
    `select_from_group`
  - or use the sort from `sycl::ext::oneapi::experimental` (joint_sort)

  Either one has to be checked against the CUDA output. This is the single hardest piece.

**6. CUDA graph capture (`bos-05-first-stage-graph.patch`): medium, optional at first.**
We record the first stage as a graph to cut launch overhead. SYCL has
`sycl_ext_oneapi_graph` (supported on Level Zero). For the first port, drop the graph and
launch kernels directly on an in-order queue, then add the graph back if launch overhead shows
up in the timing.

**7. Warp-size assumptions: check.**
There's only a comment mention of `__syncwarp` (`line_fit_filter.cc:357`), and no `__shfl` or
`__ballot`, which is good. Any kernel that assumes 32 threads work in lockstep needs checking,
and the `WarpMergeSort` in `DoFitQuads` is the known one.

## Outside the detector (in `detector/`)

- **`GpuDetectorJNI.cc`:** only light CUDA use (device setup, error checks, `cudaFree`,
  and the `cuda_capture_lock` for graph capture). Straightforward to port.
- **`NvJpgDecoder.cc` / `nvjpg_bgr.cu`:** Jetson hardware JPEG decode, which won't carry over.
  Replace it with libjpeg-turbo (already a dependency via `decodeMjpegGray`), or VA-API /
  oneVPL for hardware decode later.
- **`fault_kernel.cu`:** a test hook. Rewrite it trivially or drop it.
- **`TensorRtYoloJNI.cu`:** object detection is out of scope here. On Intel that would be
  OpenVINO on the NPU or GPU, as a separate project.
- **`CMakeLists.txt`:** a new build using `icpx -fsycl`. It also has to drop
  `-march=armv8-a+simd` and the NEON threshold flag, since this is an x86 chip.

## Suggested order

1. **Build set-up:** a new `detector-sycl/` CMake project with `icpx -fsycl`, reusing the bos
   host code. Start with the processor backend (OpenCL CPU or `SYCL_DEVICE_FILTER=cpu`), so
   the port can be built and checked on any x86 machine before the mini PC arrives.
2. **Automatic conversion:** run SYCLomatic (`c2s`) on the 5 GPU files, then fix what it can't
   convert. Expect the CUB calls and `WarpMergeSort` to be flagged.
3. **Rewrite `cuda.h`:** turn it into a thin SYCL wrapper so the rest of the code changes as
   little as possible.
4. **Correctness check:** compare the SYCL build against the CUDA build (or against CPU
   AprilTag 3) on recorded frames, checking tag IDs, corner positions to under 0.1 px, and
   decision margins. Rewind recordings from the Jetson are ideal test inputs.
5. **Speed:** profile on the Arc 140V (Level Zero backend), tune the sub-group size and
   work-group shapes, then add SYCL graphs back if launch overhead matters.
6. **PhotonVision:** keep the same JNI interface, so the 4143 PhotonVision fork loads
   `lib971apriltag.so` unchanged.

## Risks

- **Drivers:** Lunar Lake needs the `xe` kernel driver plus a recent Intel compute-runtime and
  Level Zero; Ubuntu 24.04 with a 6.8 or newer kernel at minimum.
- **Sorting speed:** oneDPL sort and scan performance on small arrays (a few thousand
  elements per frame) may be dominated by launch and synchronization overhead. This is
  where the 2 ms-per-frame budget is most at risk.
- **Upkeep:** we'd maintain a fork of Austin's detector, so his upstream changes would have
  to be carried over by hand.
