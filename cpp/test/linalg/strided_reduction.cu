/*
 * Copyright (c) 2018-2022, NVIDIA CORPORATION.
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
#include "reduce.cuh"
#include <gtest/gtest.h>
#include <raft/cudart_utils.h>
#include <raft/linalg/strided_reduction.cuh>
#include <raft/random/rng.cuh>

namespace raft {
namespace linalg {

template <typename T>
struct stridedReductionInputs {
  T tolerance;
  int rows, cols;
  unsigned long long int seed;
};

template <typename T>
void stridedReductionLaunch(T* dots, const T* data, int cols, int rows, cudaStream_t stream)
{
  stridedReduction(
    dots, data, cols, rows, (T)0, stream, false, [] __device__(T in, int i) { return in * in; });
}

template <typename T>
class stridedReductionTest : public ::testing::TestWithParam<stridedReductionInputs<T>> {
 public:
  stridedReductionTest()
    : params(::testing::TestWithParam<stridedReductionInputs<T>>::GetParam()),
      stream(handle.get_stream()),
      data(params.rows * params.cols, stream),
      dots_exp(params.cols, stream),  // expected dot products (from test)
      dots_act(params.cols, stream)   // actual dot products (from prim)
  {
  }

 protected:
  void SetUp() override
  {
    raft::random::RngState r(params.seed);
    int rows = params.rows, cols = params.cols;
    int len = rows * cols;
    uniform(handle, r, data.data(), len, T(-1.0), T(1.0));  // initialize matrix to random

    unaryAndGemv(dots_exp.data(), data.data(), cols, rows, stream);
    stridedReductionLaunch(dots_act.data(), data.data(), cols, rows, stream);
    handle.sync_stream(stream);
  }

 protected:
  raft::handle_t handle;
  cudaStream_t stream;

  stridedReductionInputs<T> params;
  rmm::device_uvector<T> data, dots_exp, dots_act;
};

const std::vector<stridedReductionInputs<float>> inputsf = {{0.00001f, 1024, 32, 1234ULL},
                                                            {0.00001f, 1024, 64, 1234ULL},
                                                            {0.00001f, 1024, 128, 1234ULL},
                                                            {0.00001f, 1024, 256, 1234ULL}};

const std::vector<stridedReductionInputs<double>> inputsd = {{0.000000001, 1024, 32, 1234ULL},
                                                             {0.000000001, 1024, 64, 1234ULL},
                                                             {0.000000001, 1024, 128, 1234ULL},
                                                             {0.000000001, 1024, 256, 1234ULL}};

typedef stridedReductionTest<float> stridedReductionTestF;
TEST_P(stridedReductionTestF, Result)
{
  ASSERT_TRUE(devArrMatch(
    dots_exp.data(), dots_act.data(), params.cols, raft::CompareApprox<float>(params.tolerance)));
}

typedef stridedReductionTest<double> stridedReductionTestD;
TEST_P(stridedReductionTestD, Result)
{
  ASSERT_TRUE(devArrMatch(
    dots_exp.data(), dots_act.data(), params.cols, raft::CompareApprox<double>(params.tolerance)));
}

INSTANTIATE_TEST_CASE_P(stridedReductionTests, stridedReductionTestF, ::testing::ValuesIn(inputsf));

INSTANTIATE_TEST_CASE_P(stridedReductionTests, stridedReductionTestD, ::testing::ValuesIn(inputsd));

}  // end namespace linalg
}  // end namespace raft
