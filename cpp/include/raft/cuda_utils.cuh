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

#pragma once

#include <math_constants.h>
#include <stdint.h>

#include <raft/cudart_utils.h>

#ifndef ENABLE_MEMCPY_ASYNC
// enable memcpy_async interface by default for newer GPUs
#if __CUDA_ARCH__ >= 800
#define ENABLE_MEMCPY_ASYNC 1
#endif
#else  // ENABLE_MEMCPY_ASYNC
// disable memcpy_async for all older GPUs
#if __CUDA_ARCH__ < 800
#define ENABLE_MEMCPY_ASYNC 0
#endif
#endif  // ENABLE_MEMCPY_ASYNC

namespace raft {

/** helper macro for device inlined functions */
#define DI  inline __device__
#define HDI inline __host__ __device__
#define HD  __host__ __device__

/**
 * @brief Provide a ceiling division operation ie. ceil(a / b)
 * @tparam IntType supposed to be only integers for now!
 */
template <typename IntType>
constexpr HDI IntType ceildiv(IntType a, IntType b)
{
  return (a + b - 1) / b;
}

/**
 * @brief Provide an alignment function ie. ceil(a / b) * b
 * @tparam IntType supposed to be only integers for now!
 */
template <typename IntType>
constexpr HDI IntType alignTo(IntType a, IntType b)
{
  return ceildiv(a, b) * b;
}

/**
 * @brief Provide an alignment function ie. (a / b) * b
 * @tparam IntType supposed to be only integers for now!
 */
template <typename IntType>
constexpr HDI IntType alignDown(IntType a, IntType b)
{
  return (a / b) * b;
}

/**
 * @brief Check if the input is a power of 2
 * @tparam IntType data type (checked only for integers)
 */
template <typename IntType>
constexpr HDI bool isPo2(IntType num)
{
  return (num && !(num & (num - 1)));
}

/**
 * @brief Give logarithm of the number to base-2
 * @tparam IntType data type (checked only for integers)
 */
template <typename IntType>
constexpr HDI IntType log2(IntType num, IntType ret = IntType(0))
{
  return num <= IntType(1) ? ret : log2(num >> IntType(1), ++ret);
}

/** Device function to apply the input lambda across threads in the grid */
template <int ItemsPerThread, typename L>
DI void forEach(int num, L lambda)
{
  int idx              = (blockDim.x * blockIdx.x) + threadIdx.x;
  const int numThreads = blockDim.x * gridDim.x;
#pragma unroll
  for (int itr = 0; itr < ItemsPerThread; ++itr, idx += numThreads) {
    if (idx < num) lambda(idx, itr);
  }
}

/** number of threads per warp */
static const int WarpSize = 32;

/** get the laneId of the current thread */
DI int laneId()
{
  int id;
  asm("mov.s32 %0, %%laneid;" : "=r"(id));
  return id;
}

/**
 * @brief Swap two values
 * @tparam T the datatype of the values
 * @param a first input
 * @param b second input
 */
template <typename T>
HDI void swapVals(T& a, T& b)
{
  T tmp = a;
  a     = b;
  b     = tmp;
}

/** Device function to have atomic add support for older archs */
template <typename Type>
DI void myAtomicAdd(Type* address, Type val)
{
  atomicAdd(address, val);
}

#if defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 600)
// Ref:
// http://on-demand.gputechconf.com/gtc/2013/presentations/S3101-Atomic-Memory-Operations.pdf
template <>
DI void myAtomicAdd(double* address, double val)
{
  unsigned long long int* address_as_ull = (unsigned long long int*)address;
  unsigned long long int old             = *address_as_ull, assumed;
  do {
    assumed = old;
    old =
      atomicCAS(address_as_ull, assumed, __double_as_longlong(val + __longlong_as_double(assumed)));
  } while (assumed != old);
}
#endif

template <typename T, typename ReduceLambda>
DI void myAtomicReduce(T* address, T val, ReduceLambda op);

template <typename ReduceLambda>
DI void myAtomicReduce(double* address, double val, ReduceLambda op)
{
  unsigned long long int* address_as_ull = (unsigned long long int*)address;
  unsigned long long int old             = *address_as_ull, assumed;
  do {
    assumed = old;
    old     = atomicCAS(
      address_as_ull, assumed, __double_as_longlong(op(val, __longlong_as_double(assumed))));
  } while (assumed != old);
}

template <typename ReduceLambda>
DI void myAtomicReduce(float* address, float val, ReduceLambda op)
{
  unsigned int* address_as_uint = (unsigned int*)address;
  unsigned int old              = *address_as_uint, assumed;
  do {
    assumed = old;
    old = atomicCAS(address_as_uint, assumed, __float_as_uint(op(val, __uint_as_float(assumed))));
  } while (assumed != old);
}

template <typename ReduceLambda>
DI void myAtomicReduce(int* address, int val, ReduceLambda op)
{
  int old = *address, assumed;
  do {
    assumed = old;
    old     = atomicCAS(address, assumed, op(val, assumed));
  } while (assumed != old);
}

template <typename ReduceLambda>
DI void myAtomicReduce(long long* address, long long val, ReduceLambda op)
{
  long long old = *address, assumed;
  do {
    assumed = old;
    old     = atomicCAS(address, assumed, op(val, assumed));
  } while (assumed != old);
}

template <typename ReduceLambda>
DI void myAtomicReduce(unsigned long long* address, unsigned long long val, ReduceLambda op)
{
  unsigned long long old = *address, assumed;
  do {
    assumed = old;
    old     = atomicCAS(address, assumed, op(val, assumed));
  } while (assumed != old);
}

/**
 * @brief Provide atomic min operation.
 * @tparam T: data type for input data (float or double).
 * @param[in] address: address to read old value from, and to atomically update w/ min(old value,
 * val)
 * @param[in] val: new value to compare with old
 */
template <typename T>
DI T myAtomicMin(T* address, T val);

/**
 * @brief Provide atomic max operation.
 * @tparam T: data type for input data (float or double).
 * @param[in] address: address to read old value from, and to atomically update w/ max(old value,
 * val)
 * @param[in] val: new value to compare with old
 */
template <typename T>
DI T myAtomicMax(T* address, T val);

DI float myAtomicMin(float* address, float val)
{
  myAtomicReduce<float(float, float)>(address, val, fminf);
  return *address;
}

DI float myAtomicMax(float* address, float val)
{
  myAtomicReduce<float(float, float)>(address, val, fmaxf);
  return *address;
}

DI double myAtomicMin(double* address, double val)
{
  myAtomicReduce<double(double, double)>(address, val, fmin);
  return *address;
}

DI double myAtomicMax(double* address, double val)
{
  myAtomicReduce<double(double, double)>(address, val, fmax);
  return *address;
}

/**
 * @defgroup Max maximum of two numbers
 * @{
 */
template <typename T>
HDI T myMax(T x, T y);
template <>
HDI float myMax<float>(float x, float y)
{
  return fmaxf(x, y);
}
template <>
HDI double myMax<double>(double x, double y)
{
  return fmax(x, y);
}
/** @} */

/**
 * @defgroup Min minimum of two numbers
 * @{
 */
template <typename T>
HDI T myMin(T x, T y);
template <>
HDI float myMin<float>(float x, float y)
{
  return fminf(x, y);
}
template <>
HDI double myMin<double>(double x, double y)
{
  return fmin(x, y);
}
/** @} */

/**
 * @brief Provide atomic min operation.
 * @tparam T: data type for input data (float or double).
 * @param[in] address: address to read old value from, and to atomically update w/ min(old value,
 * val)
 * @param[in] val: new value to compare with old
 */
template <typename T>
DI T myAtomicMin(T* address, T val)
{
  myAtomicReduce(address, val, myMin<T>);
  return *address;
}

/**
 * @brief Provide atomic max operation.
 * @tparam T: data type for input data (float or double).
 * @param[in] address: address to read old value from, and to atomically update w/ max(old value,
 * val)
 * @param[in] val: new value to compare with old
 */
template <typename T>
DI T myAtomicMax(T* address, T val)
{
  myAtomicReduce(address, val, myMax<T>);
  return *address;
}

/**
 * Sign function
 */
template <typename T>
HDI int sgn(const T val)
{
  return (T(0) < val) - (val < T(0));
}

/**
 * @defgroup Exp Exponential function
 * @{
 */
template <typename T>
HDI T myExp(T x);
template <>
HDI float myExp(float x)
{
  return expf(x);
}
template <>
HDI double myExp(double x)
{
  return exp(x);
}
/** @} */

/**
 * @defgroup Cuda infinity values
 * @{
 */
template <typename T>
inline __device__ T myInf();
template <>
inline __device__ float myInf<float>()
{
  return CUDART_INF_F;
}
template <>
inline __device__ double myInf<double>()
{
  return CUDART_INF;
}
/** @} */

/**
 * @defgroup Log Natural logarithm
 * @{
 */
template <typename T>
HDI T myLog(T x);
template <>
HDI float myLog(float x)
{
  return logf(x);
}
template <>
HDI double myLog(double x)
{
  return log(x);
}
/** @} */

/**
 * @defgroup Sqrt Square root
 * @{
 */
template <typename T>
HDI T mySqrt(T x);
template <>
HDI float mySqrt(float x)
{
  return sqrtf(x);
}
template <>
HDI double mySqrt(double x)
{
  return sqrt(x);
}
/** @} */

/**
 * @defgroup SineCosine Sine and cosine calculation
 * @{
 */
template <typename T>
DI void mySinCos(T x, T& s, T& c);
template <>
DI void mySinCos(float x, float& s, float& c)
{
  sincosf(x, &s, &c);
}
template <>
DI void mySinCos(double x, double& s, double& c)
{
  sincos(x, &s, &c);
}
/** @} */

/**
 * @defgroup Sine Sine calculation
 * @{
 */
template <typename T>
DI T mySin(T x);
template <>
DI float mySin(float x)
{
  return sinf(x);
}
template <>
DI double mySin(double x)
{
  return sin(x);
}
/** @} */

/**
 * @defgroup Abs Absolute value
 * @{
 */
template <typename T>
DI T myAbs(T x)
{
  return x < 0 ? -x : x;
}
template <>
DI float myAbs(float x)
{
  return fabsf(x);
}
template <>
DI double myAbs(double x)
{
  return fabs(x);
}
/** @} */

/**
 * @defgroup Pow Power function
 * @{
 */
template <typename T>
HDI T myPow(T x, T power);
template <>
HDI float myPow(float x, float power)
{
  return powf(x, power);
}
template <>
HDI double myPow(double x, double power)
{
  return pow(x, power);
}
/** @} */

/**
 * @defgroup myTanh tanh function
 * @{
 */
template <typename T>
HDI T myTanh(T x);
template <>
HDI float myTanh(float x)
{
  return tanhf(x);
}
template <>
HDI double myTanh(double x)
{
  return tanh(x);
}
/** @} */

/**
 * @defgroup myATanh arctanh function
 * @{
 */
template <typename T>
HDI T myATanh(T x);
template <>
HDI float myATanh(float x)
{
  return atanhf(x);
}
template <>
HDI double myATanh(double x)
{
  return atanh(x);
}
/** @} */

/**
 * @defgroup LambdaOps Lambda operations in reduction kernels
 * @{
 */
// IdxType mostly to be used for MainLambda in *Reduction kernels
template <typename Type, typename IdxType = int>
struct Nop {
  HDI Type operator()(Type in, IdxType i = 0) { return in; }
};

template <typename Type, typename IdxType = int>
struct L1Op {
  HDI Type operator()(Type in, IdxType i = 0) { return myAbs(in); }
};

template <typename Type, typename IdxType = int>
struct L2Op {
  HDI Type operator()(Type in, IdxType i = 0) { return in * in; }
};

template <typename Type>
struct Sum {
  HDI Type operator()(Type a, Type b) { return a + b; }
};
/** @} */

/**
 * @defgroup Sign Obtain sign value
 * @brief Obtain sign of x
 * @param x input
 * @return +1 if x >= 0 and -1 otherwise
 * @{
 */
template <typename T>
DI T signPrim(T x)
{
  return x < 0 ? -1 : +1;
}
template <>
DI float signPrim(float x)
{
  return signbit(x) == true ? -1.0f : +1.0f;
}
template <>
DI double signPrim(double x)
{
  return signbit(x) == true ? -1.0 : +1.0;
}
/** @} */

/**
 * @defgroup Max maximum of two numbers
 * @brief Obtain maximum of two values
 * @param x one item
 * @param y second item
 * @return maximum of two items
 * @{
 */
template <typename T>
DI T maxPrim(T x, T y)
{
  return x > y ? x : y;
}
template <>
DI float maxPrim(float x, float y)
{
  return fmaxf(x, y);
}
template <>
DI double maxPrim(double x, double y)
{
  return fmax(x, y);
}
/** @} */

/** apply a warp-wide fence (useful from Volta+ archs) */
DI void warpFence()
{
#if __CUDA_ARCH__ >= 700
  __syncwarp();
#endif
}

/** warp-wide any boolean aggregator */
DI bool any(bool inFlag, uint32_t mask = 0xffffffffu)
{
#if CUDART_VERSION >= 9000
  inFlag = __any_sync(mask, inFlag);
#else
  inFlag = __any(inFlag);
#endif
  return inFlag;
}

/** warp-wide all boolean aggregator */
DI bool all(bool inFlag, uint32_t mask = 0xffffffffu)
{
#if CUDART_VERSION >= 9000
  inFlag = __all_sync(mask, inFlag);
#else
  inFlag = __all(inFlag);
#endif
  return inFlag;
}

/**
 * @brief Shuffle the data inside a warp
 * @tparam T the data type (currently assumed to be 4B)
 * @param val value to be shuffled
 * @param srcLane lane from where to shuffle
 * @param width lane width
 * @param mask mask of participating threads (Volta+)
 * @return the shuffled data
 */
template <typename T>
DI T shfl(T val, int srcLane, int width = WarpSize, uint32_t mask = 0xffffffffu)
{
#if CUDART_VERSION >= 9000
  return __shfl_sync(mask, val, srcLane, width);
#else
  return __shfl(val, srcLane, width);
#endif
}

/**
 * @brief Shuffle the data inside a warp
 * @tparam T the data type (currently assumed to be 4B)
 * @param val value to be shuffled
 * @param laneMask mask to be applied in order to perform xor shuffle
 * @param width lane width
 * @param mask mask of participating threads (Volta+)
 * @return the shuffled data
 */
template <typename T>
DI T shfl_xor(T val, int laneMask, int width = WarpSize, uint32_t mask = 0xffffffffu)
{
#if CUDART_VERSION >= 9000
  return __shfl_xor_sync(mask, val, laneMask, width);
#else
  return __shfl_xor(val, laneMask, width);
#endif
}

/**
 * @brief Warp-level sum reduction
 * @param val input value
 * @tparam T Value type to be reduced
 * @return Reduction result. All lanes will have the valid result.
 * @note Why not cub? Because cub doesn't seem to allow working with arbitrary
 *       number of warps in a block. All threads in the warp must enter this
 *       function together
 * @todo Expand this to support arbitrary reduction ops
 */
template <typename T>
DI T warpReduce(T val)
{
#pragma unroll
  for (int i = WarpSize / 2; i > 0; i >>= 1) {
    T tmp = shfl_xor(val, i);
    val += tmp;
  }
  return val;
}

/**
 * @brief 1-D block-level sum reduction
 * @param val input value
 * @param smem shared memory region needed for storing intermediate results. It
 *             must alteast be of size: `sizeof(T) * nWarps`
 * @return only the thread0 will contain valid reduced result
 * @note Why not cub? Because cub doesn't seem to allow working with arbitrary
 *       number of warps in a block. All threads in the block must enter this
 *       function together
 * @todo Expand this to support arbitrary reduction ops
 */
template <typename T>
DI T blockReduce(T val, char* smem)
{
  auto* sTemp = reinterpret_cast<T*>(smem);
  int nWarps  = (blockDim.x + WarpSize - 1) / WarpSize;
  int lid     = laneId();
  int wid     = threadIdx.x / WarpSize;
  val         = warpReduce(val);
  if (lid == 0) sTemp[wid] = val;
  __syncthreads();
  val = lid < nWarps ? sTemp[lid] : T(0);
  return warpReduce(val);
}

/**
 * @brief Simple utility function to determine whether user_stream or one of the
 * internal streams should be used.
 * @param user_stream main user stream
 * @param int_streams array of internal streams
 * @param n_int_streams number of internal streams
 * @param idx the index for which to query the stream
 */
inline cudaStream_t select_stream(cudaStream_t user_stream,
                                  cudaStream_t* int_streams,
                                  int n_int_streams,
                                  int idx)
{
  return n_int_streams > 0 ? int_streams[idx % n_int_streams] : user_stream;
}

}  // namespace raft
