/* Copyright 2024 The OpenXLA Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/

#include "xla/service/gpu/transforms/transpose_dimension_grouper.h"

#include <cstddef>
#include <cstdint>
#include <functional>
#include <numeric>
#include <optional>
#include <vector>

#include "absl/container/flat_hash_set.h"
#include "absl/container/inlined_vector.h"
#include "absl/log/check.h"
#include "absl/log/log.h"
#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/string_view.h"
#include "absl/types/span.h"
#include "xla/hlo/ir/dfs_hlo_visitor_with_default.h"
#include "xla/hlo/ir/hlo_instruction.h"
#include "xla/layout_util.h"
#include "xla/permutation_util.h"
#include "xla/shape.h"
#include "xla/shape_util.h"
#include "tsl/platform/statusor.h"

namespace xla {
namespace gpu {

namespace {
// Returns the indices of the first elements of all consecutive subarrays of the
// given array. For example:
// ConsecutiveSegments({m, m+1, m+2, n, k, k+1}) = {0, 3, 4}
absl::InlinedVector<size_t, 3> ConsecutiveSegments(
    absl::Span<const int64_t> xs) {
  absl::InlinedVector<size_t, 3> is = {0};
  for (size_t i = 1; i < xs.size(); ++i) {
    if (1 != xs[i] - xs[i - 1]) {
      is.push_back(i);
    }
  }
  return is;
}

// Merges the sequences of dimensions of the given shape which start at the
// given indices `segs`.
Shape MergeDimensions(absl::Span<const size_t> segs, const Shape &shape) {
  std::vector<int64_t> dimensions;
  const auto size = segs.size();
  dimensions.reserve(size);
  for (size_t i = 1; i <= size; ++i) {
    dimensions.push_back(std::accumulate(
        shape.dimensions().begin() + segs[i - 1],
        shape.dimensions().begin() +
            (segs.size() == i ? shape.dimensions().size() : segs[i]),
        int64_t{1}, std::multiplies<int64_t>()));
  }
  return ShapeUtil::MakeShapeWithDescendingLayout(shape.element_type(),
                                                  dimensions);
}

std::optional<absl::InlinedVector<int64_t, 3>>
GetNormalizedTransposeShapeHelper(
    const Shape &output_shape, absl::Span<int64_t const> output_to_input,
    absl::InlinedVector<int64_t, 3> &permutation) {
  absl::InlinedVector<size_t, 3> segments =
      ConsecutiveSegments(output_to_input);
  // This means that after normalization there is actually no transpose.
  if (segments.size() == 1) {
    return std::nullopt;
  }
  Shape normalized_shape = MergeDimensions(segments, output_shape);
  if (segments.size() == 2) {
    // If we have two segments, we know that exactly two dimensions are swapped.
    // Insert a 1-dimension at the front and detect a 021 transpose.
    // TODO(b/328656780): Don't insert the extra 1-dimension once the emitter
    // supports any number of dimensions >= 2.
    permutation = {0, 2, 1};
    return absl::InlinedVector<int64_t, 3>{1, normalized_shape.dimensions(0),
                                           normalized_shape.dimensions(1)};
  }
  // We have at least 3 segments. Derive the permutation from the segments.
  std::vector<int64_t> segment_to_normalized_dim(output_shape.rank(), -1);
  for (size_t segment : segments) {
    segment_to_normalized_dim[output_to_input[segment]] = 0;
  }
  int64_t normalized_dim = 0;
  for (int64_t i = 0; i < segment_to_normalized_dim.size(); ++i) {
    if (segment_to_normalized_dim[i] >= 0) {
      segment_to_normalized_dim[i] = normalized_dim++;
    }
  }
  permutation.reserve(segments.size());
  for (int64_t i = 0; i < segments.size(); ++i) {
    permutation.push_back(
        segment_to_normalized_dim[output_to_input[segments[i]]]);
  }
  absl::InlinedVector<int64_t, 3> normalized_dims(
      normalized_shape.dimensions().begin(),
      normalized_shape.dimensions().end());
  return normalized_dims;
}

// In this case, we care about transposes that permute dimensions of a shape
// that can be viewed as several logical components in the order of major to
// minor. As an example, let's consider a 0-2-1 transpose:
//
// If a shape can be viewed as three logical components 0-1-2 in the order of
// major to minor, a 0-2-1-transpose changes the order of such logical
// components to 0-2-1. We call the shape being transposed the input shape and
// the transposed shape the output shape. The logical view of the input/output
// shapes for the transpose are called the 0-1-2/0-2-1 shapes or the normalized
// shapes. The original input/output shapes are called unnormalized shapes.
//
// 'output_shape' should have the default layout (descending minor to major),
// otherwise std::nullopt is returned.
//
// 'dimensions' specifies the kind of the unnormalized transpose and defines the
// permutation of the input shape that will result in the provided output shape.
// So to compute the input shape, we need to apply the inverse permutation of
// 'dimensions'.
//
// 'permutation' is an output parameter and specifies the kind of the normalized
// transpose. If the derived permutation is the identity permutation,
// std::nullopt is returned.
//
// The method returns the dimensions for the normalized transpose shape, or
// std::nullopt in the cases mentioned above.
//
// Example: Suppose the unnormalized output shape is [32, 1, 10, 11], and
// 'dimensions' is set to {3, 1, 0, 2}. This means the corresponding input shape
// is [10, 1, 11, 32]. The normalized output shape is [32, 110] with
// 'permutation' set to {1,0}.
std::optional<absl::InlinedVector<int64_t, 3>>
GetNormalizedLogicalTransposeShape(
    const Shape &output_shape, absl::Span<int64_t const> dimensions,
    absl::InlinedVector<int64_t, 3> &permutation) {
  permutation.clear();
  if (!LayoutUtil::IsMonotonicWithDim0Major(output_shape.layout())) {
    // Only works on default layouts.
    return std::nullopt;
  }
  // Drop degenerate dimensions.
  absl::InlinedVector<int64_t, 3> delta(output_shape.rank() + 1, 0);
  auto input_dimensions = ComposePermutations(output_shape.dimensions(),
                                              InversePermutation(dimensions));
  for (int i = 0; i < output_shape.rank(); ++i) {
    delta[i + 1] = delta[i];
    if (input_dimensions[i] == static_cast<int64_t>(1)) {
      ++delta[i + 1];
    }
  }
  absl::InlinedVector<int64_t, 3> new_dimensions;
  for (int i = 0; i < dimensions.size(); i++) {
    if (output_shape.dimensions(i) != 1) {
      new_dimensions.push_back(dimensions[i] - delta[dimensions[i]]);
    }
  }

  return GetNormalizedTransposeShapeHelper(
      ShapeUtil::DropDegenerateDimensions(output_shape), new_dimensions,
      permutation);
}

class TransposeDimensionGroupVisitor : public DfsHloRewriteVisitor {
 public:
  absl::Status HandleTranspose(HloInstruction *transpose) override {
    VLOG(4) << "Input: " << transpose->ToString();
    absl::InlinedVector<int64_t, 3> permutation;
    auto normalized_dims = GetNormalizedLogicalTransposeShape(
        transpose->shape(), transpose->dimensions(), permutation);
    if (!normalized_dims.has_value() ||
        normalized_dims == transpose->shape().dimensions()) {
      return absl::OkStatus();
    }
    auto normalized_operand_dims =
        ComposePermutations(*normalized_dims, InversePermutation(permutation));
    Shape grouped_operand_shape = ShapeUtil::MakeShapeWithDescendingLayout(
        transpose->shape().element_type(), normalized_operand_dims);
    auto new_operand = transpose->AddInstruction(HloInstruction::CreateBitcast(
        grouped_operand_shape, transpose->mutable_operand(0)));
    Shape grouped_shape = ShapeUtil::MakeShapeWithDescendingLayout(
        transpose->shape().element_type(), *normalized_dims);
    auto new_transpose =
        transpose->AddInstruction(HloInstruction::CreateTranspose(
            grouped_shape, new_operand, permutation));
    VLOG(5) << "Generated new transpose: " << new_transpose->ToString();
    return ReplaceWithNewInstruction(
        transpose,
        HloInstruction::CreateBitcast(transpose->shape(), new_transpose));
  }
};
}  // namespace

absl::StatusOr<bool> TransposeDimensionGrouper::Run(
    HloModule *module,
    const absl::flat_hash_set<absl::string_view> &execution_threads) {
  TF_ASSIGN_OR_RETURN(
      bool changed,
      TransposeDimensionGroupVisitor().RunOnModule(module, execution_threads));
  return changed;
}

}  // namespace gpu
}  // namespace xla
