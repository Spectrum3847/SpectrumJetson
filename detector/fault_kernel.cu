// TEST ONLY (SpectrumJetson): a kernel that writes through a null pointer. The resulting illegal
// address is a *sticky* CUDA error: it poisons the whole context, which is the one failure the
// JNI watchdog restarts PhotonVision for. Triggered by writing "sticky" to
// /tmp/spectrum-detector-fault-every; never runs otherwise.
#include <cuda_runtime.h>

__global__ void SpectrumFaultKernel(int *p) { *p = 1; }

void SpectrumInjectStickyCudaFault() {
  SpectrumFaultKernel<<<1, 1>>>(nullptr);
  cudaDeviceSynchronize();
}
