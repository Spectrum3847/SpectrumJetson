// SpectrumJetson: CUB 3 (CUDA 13) removed cub::TransformInputIterator. bos's 971apriltag still
// uses it, so this stands in at the removed header's path, as an alias for its replacement,
// thrust::transform_iterator (same constructor: (input iterator, op), dereferencing to op(*it)).
// CMakeLists.txt adds cub13/ to the include path only when the CUDA toolkit lacks the original.
#pragma once

#include <cstddef>

#include <cub/config.cuh>
#include <thrust/iterator/transform_iterator.h>

namespace cub {
template <typename ValueType, typename ConversionOp, typename InputIteratorT,
          typename OffsetT = std::ptrdiff_t>
using TransformInputIterator =
    thrust::transform_iterator<ConversionOp, InputIteratorT, ValueType, ValueType>;
}  // namespace cub
