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

#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "absl/log/check.h"
#include "absl/status/status.h"
#include "absl/strings/str_replace.h"
#include "absl/types/span.h"
#include "nanobind/nanobind.h"
#include "nanobind/stl/optional.h"  // IWYU pragma: keep
#include "nanobind/stl/unique_ptr.h"  // IWYU pragma: keep
#include "nanobind/stl/vector.h"  // IWYU pragma: keep
#include "xla/codegen/kernel_emitter.h"
#include "xla/codegen/kernel_spec.h"
#include "xla/codegen/testlib/kernel_runner.h"
#include "xla/hlo/ir/hlo_opcode.h"
#include "xla/literal.h"

namespace xla {

namespace {

// Use `std::vector<Literal*>` instead of `absl::Span<Literal*>` to take
// advantage of the built in bindings.
void KernelRunnerCall(KernelRunner* kernel_runner,
                      std::vector<Literal*> literals) {
  absl::Status status = kernel_runner->Call(absl::MakeSpan(literals));
  if (!status.ok()) {
    throw std::runtime_error(std::string(status.message()));
  }
}

// A dummy kernel runner that implements a simple elementwise add.
class DummyAddKernelRunner final : public KernelRunner {
 public:
  absl::Status Call(absl::Span<const Argument> arguments) override {
    if (arguments.size() != 3) {
      return InvalidArgument("Expected 3 arguments, got %u", arguments.size());
    }

    if (arguments[0].size() != arguments[1].size()) {
      return InvalidArgument(
          "Expected argument 0 to be the same size as argument "
          "1, got %u and %u",
          arguments[0].size(), arguments[1].size());
    }

    if (arguments[1].size() != arguments[2].size()) {
      return InvalidArgument(
          "Expected argument 1 to be the same size as argument "
          "2, got %u and %u",
          arguments[1].size(), arguments[2].size());
    }

    constexpr size_t element_bytes = sizeof(int32_t);

    if ((arguments[0].size() % element_bytes) != 0) {
      return InvalidArgument(
          "Expected arguments to be a multiple of %u bytes, got %u",
          element_bytes, arguments[0].size());
    }

    size_t num_elements = arguments[0].size() / element_bytes;

    auto* in_arg1 = reinterpret_cast<const int32_t*>(arguments[0].data());
    auto* in_arg2 = reinterpret_cast<const int32_t*>(arguments[1].data());
    auto* out_arg = reinterpret_cast<int32_t*>(arguments[2].data());

    for (int i = 0; i < num_elements; ++i) {
      out_arg[i] = in_arg1[i] + in_arg2[i];
    }

    return absl::OkStatus();
  }
};

}  // namespace

NB_MODULE(kernel_runner_extention, kernel_runner_module) {
  namespace nb = nanobind;

  nb::class_<KernelSpec>(kernel_runner_module, "KernelSpec");

  nb::class_<KernelEmitter>(kernel_runner_module, "KernelEmitter")
      .def("emit_kernel_spec", [](KernelEmitter* self) {
        absl::StatusOr<std::unique_ptr<KernelSpec>> spec =
            self->EmitKernelSpec();
        if (!spec.ok()) {
          throw std::runtime_error(std::string(spec.status().message()));
        }
        return std::move(spec).value();
      });

  nb::class_<KernelRunner>(kernel_runner_module, "KernelRunner")
      .def("call", &KernelRunnerCall);

  nb::class_<DummyAddKernelRunner, KernelRunner>(kernel_runner_module,
                                                 "DummyAddKernelRunner")
      .def(nb::init<>());

  nb::enum_<HloOpcode> hlo_opcode(kernel_runner_module, "HloOpcode");
#define DECLARE_ENUM(enum_name, opcode_name, ...)                          \
  hlo_opcode.value(absl::StrReplaceAll(opcode_name, {{"-", "_"}}).c_str(), \
                   HloOpcode::enum_name);
  HLO_OPCODE_LIST(DECLARE_ENUM)
#undef DECLARE_ENUM

  kernel_runner_module.def("opcode_arity", &HloOpcodeArity);
}

}  // namespace xla
