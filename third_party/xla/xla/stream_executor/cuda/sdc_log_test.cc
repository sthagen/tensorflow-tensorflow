/* Copyright 2025 The OpenXLA Authors.

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

#include "xla/stream_executor/cuda/sdc_log.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "xla/backends/gpu/runtime/sdc_log_structs.h"
#include "xla/stream_executor/device_memory.h"
#include "xla/stream_executor/platform.h"
#include "xla/stream_executor/platform_manager.h"
#include "xla/stream_executor/stream.h"
#include "xla/stream_executor/stream_executor.h"
#include "xla/stream_executor/stream_executor_memory_allocator.h"
#include "xla/tsl/platform/statusor.h"

namespace stream_executor::cuda {
namespace {

using ::xla::gpu::SdcLogEntry;
using ::xla::gpu::SdcLogHeader;

class SdcLogTest : public ::testing::Test {
 protected:
  void SetUp() override {
    TF_ASSERT_OK_AND_ASSIGN(platform_,
                            PlatformManager::PlatformWithName("CUDA"));
    TF_ASSERT_OK_AND_ASSIGN(executor_, platform_->ExecutorForDevice(0));
    TF_ASSERT_OK_AND_ASSIGN(stream_, executor_->CreateStream(std::nullopt));
    allocator_ =
        std::make_unique<StreamExecutorMemoryAllocator>(stream_->parent());
  }

  Platform* platform_;
  StreamExecutor* executor_;
  std::unique_ptr<Stream> stream_;
  std::unique_ptr<StreamExecutorMemoryAllocator> allocator_;
};

TEST_F(SdcLogTest, CreateSdcLogOnDevice_InitializesEmptyLog) {
  DeviceMemory<uint8_t> log_buffer = executor_->AllocateArray<uint8_t>(1024);

  TF_ASSERT_OK_AND_ASSIGN(SdcLog device_log,
                          SdcLog::CreateOnDevice(*stream_, log_buffer));
  TF_ASSERT_OK_AND_ASSIGN(auto host_log, device_log.ReadFromDevice(*stream_));

  EXPECT_EQ(host_log.size(), 0);
}

TEST_F(SdcLogTest, CreateSdcLogOnDevice_InitializesLogWithCorrectCapacity) {
  constexpr size_t kMaxEntries = 10;
  constexpr size_t kExpectedHeaderSize = sizeof(SdcLogHeader);
  constexpr size_t kExpectedEntriesSize = sizeof(SdcLogEntry) * kMaxEntries;
  DeviceMemory<uint8_t> log_buffer = executor_->AllocateArray<uint8_t>(
      kExpectedHeaderSize + kExpectedEntriesSize);

  TF_ASSERT_OK_AND_ASSIGN(SdcLog device_log,
                          SdcLog::CreateOnDevice(*stream_, log_buffer));

  EXPECT_EQ(device_log.GetDeviceHeader().size(), kExpectedHeaderSize);
  EXPECT_EQ(device_log.GetDeviceEntries().size(), kExpectedEntriesSize);
}

TEST_F(SdcLogTest, CreateSdcLogOnDevice_InitializesHeader) {
  constexpr size_t kMaxEntries = 123;
  DeviceMemory<uint8_t> log_buffer = executor_->AllocateArray<uint8_t>(
      SdcLog::RequiredSizeForEntries(kMaxEntries));

  TF_ASSERT_OK_AND_ASSIGN(SdcLog device_log,
                          SdcLog::CreateOnDevice(*stream_, log_buffer));
  TF_ASSERT_OK_AND_ASSIGN(SdcLogHeader header,
                          device_log.ReadHeaderFromDevice(*stream_));

  EXPECT_EQ(header.write_idx, 0);
  EXPECT_EQ(header.capacity, kMaxEntries);
}

TEST_F(SdcLogTest, CreateSdcLogOnDevice_FailsForNullBuffer) {
  EXPECT_THAT(SdcLog::CreateOnDevice(*stream_, DeviceMemory<uint8_t>()),
              absl_testing::StatusIs(absl::StatusCode::kInvalidArgument));
}

TEST_F(SdcLogTest, CreateSdcLogOnDevice_FailsForTooSmallBuffer) {
  DeviceMemory<uint8_t> log_buffer =
      executor_->AllocateArray<uint8_t>(SdcLog::RequiredSizeForEntries(1) - 1);

  EXPECT_THAT(SdcLog::CreateOnDevice(*stream_, log_buffer),
              absl_testing::StatusIs(absl::StatusCode::kInvalidArgument));
}

}  // namespace
}  // namespace stream_executor::cuda
