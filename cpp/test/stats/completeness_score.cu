/*
 * Copyright (c) 2019-2022, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include "../test_utils.h"
#include <algorithm>
#include <gtest/gtest.h>
#include <iostream>
#include <raft/cudart_utils.h>
#include <raft/stats/completeness_score.cuh>
#include <raft/stats/entropy.cuh>
#include <raft/stats/mutual_info_score.cuh>
#include <random>

namespace raft {
namespace stats {

// parameter structure definition
struct completenessParam {
  int nElements;
  int lowerLabelRange;
  int upperLabelRange;
  bool sameArrays;
  double tolerance;
};

// test fixture class
template <typename T>
class completenessTest : public ::testing::TestWithParam<completenessParam> {
 protected:
  // the constructor
  void SetUp() override
  {
    // getting the parameters
    params = ::testing::TestWithParam<completenessParam>::GetParam();

    nElements       = params.nElements;
    lowerLabelRange = params.lowerLabelRange;
    upperLabelRange = params.upperLabelRange;

    // generating random value test input
    std::vector<int> arr1(nElements, 0);
    std::vector<int> arr2(nElements, 0);
    std::random_device rd;
    std::default_random_engine dre(rd());
    std::uniform_int_distribution<int> intGenerator(lowerLabelRange, upperLabelRange);

    std::generate(arr1.begin(), arr1.end(), [&]() { return intGenerator(dre); });
    if (params.sameArrays) {
      arr2 = arr1;
    } else {
      std::generate(arr2.begin(), arr2.end(), [&]() { return intGenerator(dre); });
    }

    // allocating and initializing memory to the GPU

    RAFT_CUDA_TRY(cudaStreamCreate(&stream));

    rmm::device_uvector<T> truthClusterArray(nElements, stream);
    rmm::device_uvector<T> predClusterArray(nElements, stream);
    raft::update_device(truthClusterArray.data(), arr1.data(), (int)nElements, stream);
    raft::update_device(predClusterArray.data(), arr2.data(), (int)nElements, stream);

    // calculating the golden output
    double truthMI, truthEntropy;

    truthMI      = raft::stats::mutual_info_score(truthClusterArray.data(),
                                             predClusterArray.data(),
                                             nElements,
                                             lowerLabelRange,
                                             upperLabelRange,
                                             stream);
    truthEntropy = raft::stats::entropy(
      predClusterArray.data(), nElements, lowerLabelRange, upperLabelRange, stream);

    if (truthEntropy) {
      truthCompleteness = truthMI / truthEntropy;
    } else
      truthCompleteness = 1.0;

    if (nElements == 0) truthCompleteness = 1.0;

    // calling the completeness CUDA implementation
    computedCompleteness = raft::stats::completeness_score(truthClusterArray.data(),
                                                           predClusterArray.data(),
                                                           nElements,
                                                           lowerLabelRange,
                                                           upperLabelRange,
                                                           stream);
  }

  // the destructor
  void TearDown() override { RAFT_CUDA_TRY(cudaStreamDestroy(stream)); }

  // declaring the data values
  completenessParam params;
  T lowerLabelRange, upperLabelRange;
  int nElements               = 0;
  double truthCompleteness    = 0;
  double computedCompleteness = 0;
  cudaStream_t stream         = 0;
};

// setting test parameter values
const std::vector<completenessParam> inputs = {{199, 1, 10, false, 0.000001},
                                               {200, 15, 100, false, 0.000001},
                                               {100, 1, 20, false, 0.000001},
                                               {10, 1, 10, false, 0.000001},
                                               {198, 1, 100, false, 0.000001},
                                               {300, 3, 99, false, 0.000001},
                                               {199, 1, 10, true, 0.000001},
                                               {200, 15, 100, true, 0.000001},
                                               {100, 1, 20, true, 0.000001},
                                               {10, 1, 10, true, 0.000001},
                                               {198, 1, 100, true, 0.000001},
                                               {300, 3, 99, true, 0.000001}};

// writing the test suite
typedef completenessTest<int> completenessTestClass;
TEST_P(completenessTestClass, Result)
{
  ASSERT_NEAR(computedCompleteness, truthCompleteness, params.tolerance);
}
INSTANTIATE_TEST_CASE_P(completeness, completenessTestClass, ::testing::ValuesIn(inputs));

}  // end namespace stats
}  // end namespace raft
