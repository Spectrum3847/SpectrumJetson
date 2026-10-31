// SpectrumJetson: CUB 3 (CUDA 13) removed cub::DiscardOutputIterator. bos's 971apriltag still
// uses it (output keys nobody reads), so this stands in at the removed header's path, as an alias
// for thrust::discard_iterator, which also swallows every write.
// CMakeLists.txt adds cub13/ to the include path only when the CUDA toolkit lacks the original.
#pragma once

#include <cstddef>

#include <cub/config.cuh>
#include <thrust/iterator/discard_iterator.h>

namespace cub {
template <typename OffsetT = std::ptrdiff_t>
using DiscardOutputIterator = thrust::discard_iterator<>;
}  // namespace cub
