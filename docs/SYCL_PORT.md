# Porting the 971 CUDA AprilTag detector to SYCL (Intel Arc)

Scoping notes for running the detector on an Intel GPU, such as the Arc 140V in a Core Ultra 7
256V (Lunar Lake) mini PC. Nothing here has been built yet; this is what the port would involve.

Source surveyed: frc971/bos `62e93b4` `third_party/971apriltag`, with our `patches/bos-*.patch`
applied (all apply cleanly), plus our `detector/` directory.

## Target

The bar is the Jetson's measured numbers (README, Performance, 2026-09-29), with Thriftiest
Cams at 1280x800:

| Cameras | fps each | Detect time | GPU | CPU | Power |
| --- | --- | --- | --- | --- | --- |
| 4 | 122 | 1.2 ms | 25.7% | 1.14 cores | – |
| 5 | 122 | 2.1 ms | 44% | 1.9 cores | 11.1 W |

End-to-end latency is about 14.5 ms from mid-exposure. Of that, 8.1 ms is the camera sending
the frame, 2.8 ms is JPEG decode and 1.2 ms is detection, so a faster GPU can only win back a
few milliseconds; the decode path matters as much. What these numbers mean for the port:

- **GPU:** 5 cameras at 44% on the Orin leaves room, and the Arc 140V has about twice the
  compute, so the detector itself should fit. With 4 cameras, the Jetson's slowest frames take
  6-12 ms because cameras queue for one GPU. Expect the same on Arc, and compare slowest
  frames, not just averages.
- **Keep frames on the GPU:** on the Jetson, passing the hardware-decoded frame straight to the
  detector took detection from 1.9 to 1.3 ms. So the VA-API → Level Zero zero-copy path is
  needed to match it, not optional.
- **Graphs:** the CUDA graph (`bos-05`) was worth only about 0.1 ms, so leaving SYCL graphs out
  of the first port is fine.
- **CPU:** the Jetson uses 1.9 cores for 5 cameras, mostly inside NVIDIA's libraries. The Intel
  processor should do better, but it has to decode in hardware: libjpeg-turbo at 610 frames/s
  would take about 2 performance cores.
- **Power:** the Jetson draws 11.1 W with 5 cameras. The mini PC will likely draw 2-3x that and
  needs a higher-voltage supply.
- **USB:** the Jetson is full at 5 capped cameras (6,400 of ~6,720 bytes of its shared USB 2.0
  budget). Check the mini PC's internal wiring with `lsusb -t`. Cameras on separate USB
  controllers each get their own budget, which could allow a 6th camera. Our capped camera
  driver (`11-uvcvideo-payload-cap.sh`) works on x86 too.
- **Processor-only fallback:** stock PhotonVision on the processor won't manage 5 cameras at
  122 fps, so the GPU port is required for this PC to match the Jetson.

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
  The Intel equivalent is the Lunar Lake media engine's hardware JPEG decoder, reached through
  VA-API (`intel-media-driver`, iHD) or oneVPL. It decodes into NV12 or Y800, and the Y
  (brightness) plane is the gray image the detector wants, so there's no colour conversion step.
  The decoded surface can also be handed to SYCL without a copy (VA-API → dma-buf →
  Level Zero external memory). Check two things on the real hardware:
  - that the iHD driver decodes the Thriftiest Cam's MJPEG sampling format (4:2:0 or 4:0:0)
  - the decode latency per frame compared with libjpeg-turbo
  libjpeg-turbo (already a dependency via `decodeMjpegGray`) is the fallback, and on this
  processor it's likely fast enough for a couple of cameras.
- **`fault_kernel.cu`:** a test hook. Rewrite it trivially or drop it.
- **`TensorRtYoloJNI.cu`:** object detection becomes an OpenVINO library; see
  [Object detection with OpenVINO](#object-detection-with-openvino) below.
- **`CMakeLists.txt`:** a new build using `icpx -fsycl`. It also has to drop
  `-march=armv8-a+simd` and the NEON threshold flag, since this is an x86 chip.

## Object detection with OpenVINO

Replaces the TensorRT YOLO library (`detector/TensorRtYoloJNI.cu`, Java side in
`photonvision-14`) on Lunar Lake. Target machine: GMKtec K13 (Core Ultra 7 256V).

### Why the NPU

Lunar Lake has two devices that can run the model:
- **the NPU:** Intel quotes about 47 TOPS for the 256V
- **the Arc 140V GPU**

On the Jetson, object detection shares the GPU with the AprilTag detector. Uncapped FUEL (76 fps)
pushed an AprilTag camera's worst detect time from 3.75 to 28 ms, which is why
`SPECTRUM_OD_FPS_LIMIT` caps it at 30 fps. On Lunar Lake the model runs on the NPU and AprilTags
on the GPU, so they shouldn't compete. That's the main thing to confirm on the hardware.

### Plan

1. **Model:** export the same YOLO model with `yolo export format=openvino` (FP16 IR), then an
   INT8 version with `int8=True` and a calibration set of our own FUEL frames. Keep the input
   size the same as the TensorRT engine.
2. **Library:** write `detector/OpenVinoYoloJNI.cc` → `libspectrumov.so`.
   - Keep the exact JNI surface of `TensorRtJNI`: `create(path)`, `inputSize(ptr)`,
     `detect(ptr, mat_ptr, box_thresh, nms_thresh, num_classes)`, `destroy(ptr)`.
   - Use the same output layout, so the Java side and `photonvision-14` change as little as
     possible. Either keep the `TensorRtJNI` class name and swap the library underneath, or add
     a small `OpenVinoJNI` twin, whichever makes the smaller patch.
   - Inside:
     - `ov::Core::compile_model(model, "NPU")`, falling back to `"GPU"`, then `"CPU"`
     - pick the device with `SPECTRUM_OV_DEVICE`, and log which one loaded
     - letterbox and normalise with `ov::preprocess::PrePostProcessor`, so it runs in the
       compiled graph and not on the processor
     - reuse the existing YOLO decode and NMS code from `TensorRtYoloJNI.cu`, which is plain
       C++ once the CUDA pieces are removed
     - one `ov::InferRequest` per camera, run asynchronously so a camera thread doesn't block
       the others
3. **Frames:** colour cameras use the same VA-API hardware JPEG decode as the AprilTag path.
   Start by copying the decoded frame into the model's input buffer, and add zero-copy only if
   the copy shows up in the timing.
4. **Build:** a CMake option next to the SYCL build that finds OpenVINO (`find_package(OpenVINO)`)
   and builds `libspectrumov.so` only if it's installed, like the TensorRT library today.
5. **Set-up script:** Ubuntu 24.04 needs `intel-npu-driver` (the NPU runtime and firmware), the
   OpenVINO runtime (apt or pip), and the user added to the `render` group for `/dev/accel`.

### Tests

- **Correct results:** replay recorded FUEL frames through TensorRT on the Jetson and OpenVINO on
  the K13, then compare boxes, classes and confidences (INT8 will differ slightly; boxes
  should overlap by an IoU of 0.9 or more).
- **Whole model on the NPU:** check no layers fell back to the processor
  (`ov::CompiledModel::get_runtime_model()` shows where each layer runs). A fallback is silent
  and slow.
- **Speed:** time each frame on NPU vs GPU, and the fps with no cap.
- **The main test:** run 5 AprilTag cameras at 122 fps with object detection uncapped, and
  compare the AprilTag worst-case detect time with the Jetson's 28 ms. If it stays near the
  no-detection worst case, the 30 fps cap can be raised on this PC.
- **Power:** measure the draw with the NPU busy, to stay within the 50 W budget.

### Risks

- **NPU latency:** for small models, a few milliseconds per frame is fine at 30 fps but could
  limit the uncapped rate. Compare with the GPU.
- **Unsupported layers:** some YOLO versions have layers the NPU compiler doesn't support. Pick a
  YOLO version that compiles fully for the NPU (check before training a new model).
- **INT8 accuracy:** INT8 can lose accuracy on our mono or colour frames, so calibrate on real
  field images. FP16 on the NPU is the fallback.
- **Upkeep:** the NPU driver and OpenVINO versions have to match; pin both in the set-up script.

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
