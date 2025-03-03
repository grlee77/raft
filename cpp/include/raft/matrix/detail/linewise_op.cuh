/*
 * Copyright (c) 2021-2022, NVIDIA CORPORATION.
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

#include <raft/cuda_utils.cuh>
#include <raft/pow2_utils.cuh>
#include <raft/vectorized.cuh>

#include <algorithm>

namespace raft {
namespace matrix {
namespace detail {

template <typename Type, typename IdxType, std::size_t VecBytes, int BlockSize>
struct Linewise {
  static constexpr IdxType VecElems = VecBytes / sizeof(Type);

  typedef raft::TxN_t<Type, VecElems> Vec;
  typedef raft::Pow2<VecBytes> AlignBytes;
  typedef raft::Pow2<VecElems> AlignElems;
  typedef raft::Pow2<raft::WarpSize> AlignWarp;

  /**
   * Compute op(matrix_in, vec_1, vec_2, ...) where vectors are applied across the
   * matrix rows (one vector element per matrix row).
   *
   * It's assumed that `in` and `out` are aligned to the cuda-vector-size,
   * and their length is multiple of that.
   *
   * Block work arrangement: blocked;
   *     one warp works on a contiguous chunk of a matrix. Since the matrix is represented
   *     as a flat array, such an arangement minimizes the number of times when a single
   *     thread needs to reload the vector value at an index corresponding to the current
   *     matrix row. Ideally, a thread would load a value from a vector only once, but that
   *     is not possible if the vector size (= number of matrix rows) is too small or not
   *     aligned with the cuda-vector-size.
   *
   * Note about rowDiv/rowMod:
   *     these two represent the row/column indices in the original input matrices, before
   *     it was converted to (Vec::io_t*) type (which possibly involves shifting a pointer
   *     a bit to align to the cuda-vector-size). Thus, they are used to track the index for
   *     the argument vectors only (the vector pointers are not altered in any way).
   *
   *
   * @tparam Vecs a pack of pointers to vectors (Type*)
   * @param [out] out (aligned part of) the output matrix
   * @param [in] in (aligned part of) the input matrix
   * @param [in] in_end end of the (aligned part of the) input matrix
   * @param [in] rowLen number of elements in a row (NOT the vector size)
   * @param [in] rowDiv the index in the vectors (= row num in the original unaligned input matrix)
   * @param [in] rowMod the index within a row in the original unaligned input matrix.
   * @param [in] op the function to apply
   * @param [in] vecs pointers to the argument vectors.
   *
   */
  template <typename Lambda, typename... Vecs>
  static __device__ __forceinline__ void vectorCols(typename Vec::io_t* out,
                                                    const typename Vec::io_t* in,
                                                    const typename Vec::io_t* in_end,
                                                    const IdxType rowLen,
                                                    IdxType rowDiv,
                                                    IdxType rowMod,
                                                    Lambda op,
                                                    Vecs... vecs) noexcept
  {
    constexpr IdxType warpPad = (AlignWarp::Value - 1) * VecElems;
    Type args[sizeof...(Vecs)];
    Vec v, w;
    bool update = true;
    for (; in < in_end; in += AlignWarp::Value, out += AlignWarp::Value, rowMod += warpPad) {
      v.val.internal = __ldcv(in);
      while (rowMod >= rowLen) {
        rowMod -= rowLen;
        rowDiv++;
        update = true;
      }
      if (update) {
        int l = 0;
        ((args[l] = vecs[rowDiv], l++), ...);
        update = false;
      }
#pragma unroll VecElems
      for (int k = 0; k < VecElems; k++, rowMod++) {
        if (rowMod == rowLen) {
          rowMod = 0;
          rowDiv++;
          int l = 0;
          ((args[l] = vecs[rowDiv], l++), ...);
        }
        int l         = 0;
        w.val.data[k] = op(v.val.data[k], (std::ignore = vecs, args[l++])...);
      }
      *out = w.val.internal;
    }
  }

  /**
   * Compute op(matrix_in, vec_1, vec_2, ...) where vectors are applied along
   * matrix rows (vector and matrix indices are 1-1).
   *
   * It's assumed that `in` and `out` are aligned to the cuda-vector-size,
   * and their length is multiple of that.
   *
   * Block work arrangement: striped;
   *     the grid size is chosen in such a way, that one thread always processes
   *     the same vector elements. That's why there is no need to read the
   *     vector arguments multiple times.
   *
   * @tparam Args a pack of raft::TxN_t<Type, VecElems>
   * @param [out] out (aligned part of) the output matrix
   * @param [in] in (aligned part of) the input matrix
   * @param [in] len total length of (the aligned part of) the input/output matrices
   * @param [in] op the function to apply
   * @param [in] args the cuda-vector-sized chunks on input vectors (raft::TxN_t<Type, VecElems>)
   */
  template <typename Lambda, typename... Args>
  static __device__ __forceinline__ void vectorRows(typename Vec::io_t* out,
                                                    const typename Vec::io_t* in,
                                                    const IdxType len,
                                                    Lambda op,
                                                    Args... args) noexcept
  {
    Vec v;
    const IdxType d = BlockSize * gridDim.x;
    for (IdxType i = threadIdx.x + blockIdx.x * BlockSize; i < len; i += d) {
      v.val.internal = __ldcv(in + i);
#pragma unroll VecElems
      for (int k = 0; k < VecElems; k++)
        v.val.data[k] = op(v.val.data[k], args.val.data[k]...);
      __stwt(out + i, v.val.internal);
    }
  }

  /**
   * The helper for `vectorRows`. Loads the `raft::TxN_t<Type, VecElems>` chunk
   * of a vector. Most of the time this is not aligned, so we load it thread-striped
   * within a block and then use the shared memory to get a contiguous chunk.
   *
   * @param [in] shm a shared memory region for rearranging the data among threads
   * @param [in] p pointer to a vector
   * @param [in] blockOffset the offset of the current block into a vector.
   * @param [in] rowLen the length of a vector.
   * @return a contiguous chunk of a vector, suitable for `vectorRows`.
   */
  static __device__ __forceinline__ Vec loadVec(Type* shm,
                                                const Type* p,
                                                const IdxType blockOffset,
                                                const IdxType rowLen) noexcept
  {
    IdxType j = blockOffset + threadIdx.x;
#pragma unroll VecElems
    for (int k = threadIdx.x; k < VecElems * BlockSize; k += BlockSize, j += BlockSize) {
      while (j >= rowLen)
        j -= rowLen;
      shm[k] = p[j];
    }
    __syncthreads();
    {
      Vec out;
      out.val.internal = reinterpret_cast<typename Vec::io_t*>(shm)[threadIdx.x];
      return out;
    }
  }
};

/**
 * This kernel prepares the inputs for the `vectorCols` function where the most of the
 * work happens; see `vectorCols` for details.
 *
 * The work arrangement is blocked; a single block works on a contiguous chunk of flattened
 * matrix data and does not care about the gridDim.
 *
 * @param [out] out the output matrix
 * @param [in] in the input matrix
 * @param [in] arrOffset such an offset into the matrices that makes them aligned to the
 * cuda-vector-size
 * @param [in] rowLen number of elements in a row (NOT the vector size)
 * @param [in] len the total length of the aligned part of the matrices
 * @param [in] elemsPerThread how many elements are processed by a single thread in total
 * @param [in] op the function to apply
 * @param [in] vecs pointers to the argument vectors
 */
template <typename Type,
          typename IdxType,
          std::size_t VecBytes,
          int BlockSize,
          typename Lambda,
          typename... Vecs>
__global__ void __launch_bounds__(BlockSize)
  matrixLinewiseVecColsMainKernel(Type* out,
                                  const Type* in,
                                  const IdxType arrOffset,
                                  const IdxType rowLen,
                                  const IdxType len,
                                  const IdxType elemsPerThread,
                                  Lambda op,
                                  Vecs... vecs)
{
  typedef Linewise<Type, IdxType, VecBytes, BlockSize> L;

  IdxType t = L::AlignWarp::mod(threadIdx.x);
  t = arrOffset + elemsPerThread * (blockIdx.x * BlockSize + threadIdx.x - t) + t * L::VecElems;

  return L::vectorCols(reinterpret_cast<typename L::Vec::io_t*>(out + t),
                       reinterpret_cast<const typename L::Vec::io_t*>(in + t),
                       reinterpret_cast<const typename L::Vec::io_t*>(
                         in + min(t + elemsPerThread * L::AlignWarp::Value, len)),
                       rowLen,
                       t / rowLen,
                       t % rowLen,
                       op,
                       vecs...);
}

/**
 * This kernel is similar to `matrixLinewiseVecColsMainKernel`, but processes only the unaligned
 * head and tail parts of the matrix.
 * This kernel is always launched in just two blocks; the first block processes the head of the
 * matrix, the second block processes the tail. It uses the same `vectorCols` function, but
 * sets `VecElems = 1`
 *
 * @param [out] out the output matrix
 * @param [in] in the input matrix
 * @param [in] arrOffset the length of the unaligned head - such an offset into the matrices that
 * makes them aligned to the `VecBytes`
 * @param [in] arrTail the offset to the unaligned tail
 * @param [in] rowLen number of elements in a row (NOT the vector size)
 * @param [in] len the total length of the matrices (rowLen * nRows)
 * @param [in] op the function to apply
 * @param [in] vecs pointers to the argument vectors
 */
template <typename Type, typename IdxType, std::size_t MaxOffset, typename Lambda, typename... Vecs>
__global__ void __launch_bounds__(MaxOffset, 2)
  matrixLinewiseVecColsTailKernel(Type* out,
                                  const Type* in,
                                  const IdxType arrOffset,
                                  const IdxType arrTail,
                                  const IdxType rowLen,
                                  const IdxType len,
                                  Lambda op,
                                  Vecs... vecs)
{
  // Note, L::VecElems == 1
  typedef Linewise<Type, IdxType, sizeof(Type), MaxOffset> L;
  IdxType threadOffset, elemsPerWarp;
  if (blockIdx.x == 0) {
    // first block: offset = 0, length = arrOffset
    threadOffset = threadIdx.x;
    elemsPerWarp = threadOffset < arrOffset;
  } else {
    // second block: offset = arrTail, length = len - arrTail
    threadOffset = arrTail + threadIdx.x;
    elemsPerWarp = threadOffset < len;
  }
  const IdxType rowDiv = threadOffset / rowLen;
  const IdxType rowMod = threadOffset % rowLen;
  return L::vectorCols(
    reinterpret_cast<typename L::Vec::io_t*>(out + threadOffset),
    reinterpret_cast<const typename L::Vec::io_t*>(in + threadOffset),
    reinterpret_cast<const typename L::Vec::io_t*>(in + threadOffset + elemsPerWarp),
    rowLen,
    rowDiv,
    rowMod,
    op,
    vecs...);
}

/**
 * This kernel prepares the inputs for the `vectorRows` function where the most of the
 * work happens; see `vectorRows` for details.
 *
 * The work arrangement is striped; the gridDim should be selected in such a way, that
 * on each iteration a thread processes the same indices along rows:
 *   `(gridDim.x * BlockSize * VecElems) % rowLen == 0`.
 *
 * @param [out] out the start of the *aligned* part of the output matrix
 * @param [in] in the start of the *aligned* part of the input matrix
 * @param [in] arrOffset such an offset into the matrices that makes them aligned to `VecBytes`
 * @param [in] rowLen number of elements in a row (= the vector size)
 * @param [in] len the total length of the aligned part of the matrices
 * @param [in] op the function to apply
 * @param [in] vecs pointers to the argument vectors
 */
template <typename Type,
          typename IdxType,
          std::size_t VecBytes,
          int BlockSize,
          typename Lambda,
          typename... Vecs>
__global__ void __launch_bounds__(BlockSize)
  matrixLinewiseVecRowsMainKernel(Type* out,
                                  const Type* in,
                                  const IdxType arrOffset,
                                  const IdxType rowLen,
                                  const IdxType len,
                                  Lambda op,
                                  Vecs... vecs)
{
  typedef Linewise<Type, IdxType, VecBytes, BlockSize> L;
  constexpr uint workSize = L::VecElems * BlockSize;
  uint workOffset         = workSize;
  __shared__ __align__(sizeof(Type) * L::VecElems)
    Type shm[workSize * ((sizeof...(Vecs)) > 1 ? 2 : 1)];
  const IdxType blockOffset = (arrOffset + BlockSize * L::VecElems * blockIdx.x) % rowLen;
  return L::vectorRows(
    reinterpret_cast<typename L::Vec::io_t*>(out),
    reinterpret_cast<const typename L::Vec::io_t*>(in),
    L::AlignElems::div(len),
    op,
    (workOffset ^= workSize, L::loadVec(shm + workOffset, vecs, blockOffset, rowLen))...);
}

/**
 * This kernel is similar to `matrixLinewiseVecRowsMainKernel`, but processes only the unaligned
 * head and tail parts of the matrix.
 * This kernel is always launched in just two blocks; the first block processes the head of the
 * matrix, the second block processes the tail. It uses the same `vectorRows` function, but
 * sets `VecElems = 1`
 *
 * @param [out] out the output matrix
 * @param [in] in the input matrix
 * @param [in] arrOffset the length of the unaligned head - such an offset into the matrices that
 * makes them aligned to the `VecBytes`
 * @param [in] arrTail the offset to the unaligned tail
 * @param [in] rowLen number of elements in a row (= the vector size)
 * @param [in] len the total length of the matrices (rowLen * nRows)
 * @param [in] op the function to apply
 * @param [in] vecs pointers to the argument vectors
 */
template <typename Type, typename IdxType, std::size_t MaxOffset, typename Lambda, typename... Vecs>
__global__ void __launch_bounds__(MaxOffset, 2)
  matrixLinewiseVecRowsTailKernel(Type* out,
                                  const Type* in,
                                  const IdxType arrOffset,
                                  const IdxType arrTail,
                                  const IdxType rowLen,
                                  const IdxType len,
                                  Lambda op,
                                  Vecs... vecs)
{
  // Note, L::VecElems == 1
  constexpr uint workSize = MaxOffset;
  uint workOffset         = workSize;
  __shared__ Type shm[workSize * ((sizeof...(Vecs)) > 1 ? 2 : 1)];
  typedef Linewise<Type, IdxType, sizeof(Type), MaxOffset> L;
  if (blockIdx.x == 0) {
    // first block: offset = 0, length = arrOffset
    L::vectorRows(reinterpret_cast<typename L::Vec::io_t*>(out),
                  reinterpret_cast<const typename L::Vec::io_t*>(in),
                  arrOffset,
                  op,
                  (workOffset ^= workSize, L::loadVec(shm + workOffset, vecs, 0, rowLen))...);
  } else {
    // second block: offset = arrTail, length = len - arrTail
    // NB: I substract MaxOffset (= blockDim.x) to get the correct indexing for block 1
    L::vectorRows(
      reinterpret_cast<typename L::Vec::io_t*>(out + arrTail - MaxOffset),
      reinterpret_cast<const typename L::Vec::io_t*>(in + arrTail - MaxOffset),
      len - arrTail + MaxOffset,
      op,
      (workOffset ^= workSize, L::loadVec(shm + workOffset, vecs, arrTail % rowLen, rowLen))...);
  }
}

/** Fully occupy GPU this many times for better work balancing. */
static inline constexpr uint OptimalSmOccupancy = 16;

/**
 * Calculate the grid size to be `OptimalSmOccupancy * FullyOccupiedGPU`, where `FullyOccupiedGPU`
 * is the maximum number of blocks fitting in all available SMs.
 *
 * @tparam BlockSize blockDim of the kernel.
 * @return OptimalSmOccupancy * FullyOccupiedGPU
 */
template <int BlockSize>
inline uint getOptimalGridSize()
{
  int devId, smCount, maxBlockSize;
  RAFT_CUDA_TRY(cudaGetDevice(&devId));
  RAFT_CUDA_TRY(cudaDeviceGetAttribute(&smCount, cudaDevAttrMultiProcessorCount, devId));
  RAFT_CUDA_TRY(cudaDeviceGetAttribute(&maxBlockSize, cudaDevAttrMaxThreadsPerBlock, devId));
  return OptimalSmOccupancy * static_cast<uint>(smCount * maxBlockSize / BlockSize);
}

template <typename Type,
          typename IdxType,
          std::size_t VecBytes,
          int BlockSize,
          typename Lambda,
          typename... Vecs>
void matrixLinewiseVecCols(Type* out,
                           const Type* in,
                           const IdxType rowLen,
                           const IdxType nRows,
                           Lambda op,
                           cudaStream_t stream,
                           Vecs... vecs)
{
  typedef raft::Pow2<VecBytes> AlignBytes;
  constexpr std::size_t VecElems = VecBytes / sizeof(Type);
  const IdxType totalLen         = rowLen * nRows;
  const Type* alignedStart       = AlignBytes::roundUp(in);
  const IdxType alignedOff       = IdxType(alignedStart - in);
  const IdxType alignedEnd       = IdxType(AlignBytes::roundDown(in + totalLen) - in);
  const IdxType alignedLen       = alignedEnd - alignedOff;
  if (alignedLen > 0) {
    constexpr dim3 bs(BlockSize, 1, 1);
    // Minimum size of the grid to make the device well occupied
    const uint occupy = getOptimalGridSize<BlockSize>();
    // does not make sense to have more blocks than this
    const uint maxBlocks = raft::ceildiv<uint>(uint(alignedLen), bs.x * VecElems);
    const dim3 gs(std::min(maxBlocks, occupy), 1, 1);
    // The work arrangement is blocked on the block and warp levels;
    //   see more details at Linewise::vectorCols.
    // The value below determines how many scalar elements are processed by on thread in total.
    const IdxType elemsPerThread =
      raft::ceildiv<IdxType>(alignedLen, gs.x * VecElems * BlockSize) * VecElems;
    matrixLinewiseVecColsMainKernel<Type, IdxType, VecBytes, BlockSize, Lambda, Vecs...>
      <<<gs, bs, 0, stream>>>(out, in, alignedOff, rowLen, alignedLen, elemsPerThread, op, vecs...);
    RAFT_CUDA_TRY(cudaPeekAtLastError());
  }
  if (alignedLen < totalLen) {
    // should be not smaller than the warp size for better branching
    constexpr std::size_t MaxOffset = std::max(std::size_t(raft::WarpSize), VecBytes);
    matrixLinewiseVecColsTailKernel<Type, IdxType, MaxOffset, Lambda, Vecs...>
      <<<dim3(2, 1, 1), dim3(MaxOffset, 1, 1), 0, stream>>>(
        out, in, alignedOff, alignedEnd, rowLen, totalLen, op, vecs...);
    RAFT_CUDA_TRY(cudaPeekAtLastError());
  }
}

template <typename Type,
          typename IdxType,
          std::size_t VecBytes,
          int BlockSize,
          typename Lambda,
          typename... Vecs>
void matrixLinewiseVecRows(Type* out,
                           const Type* in,
                           const IdxType rowLen,
                           const IdxType nRows,
                           Lambda op,
                           cudaStream_t stream,
                           Vecs... vecs)
{
  typedef raft::Pow2<VecBytes> AlignBytes;
  constexpr std::size_t VecElems = VecBytes / sizeof(Type);
  const IdxType totalLen         = rowLen * nRows;
  const Type* alignedStart       = AlignBytes::roundUp(in);
  const IdxType alignedOff       = IdxType(alignedStart - in);
  const IdxType alignedEnd       = IdxType(AlignBytes::roundDown(in + totalLen) - in);
  const IdxType alignedLen       = alignedEnd - alignedOff;
  if (alignedLen > 0) {
    constexpr dim3 bs(BlockSize, 1, 1);
    // The work arrangement is striped;
    //   see more details at Linewise::vectorRows.
    // Below is the work amount performed by one block in one iteration.
    constexpr uint block_work_size = bs.x * uint(VecElems);
    /* Here I would define `grid_work_size = lcm(block_work_size, rowLen)` (Least Common Multiple)
       This way, the grid spans a set of one or more rows each iteration, and, most importantly,
       on every iteration each row processes the same set of indices within a row (= the same set
       of vector indices).
       This means, each block needs to load the values from the vector arguments only once.
       Sadly, sometimes `grid_work_size > rowLen*nRows`, and sometimes grid_work_size > UINT_MAX.
       That's why I don't declare it here explicitly.
       Instead, I straightaway compute the
         expected_grid_size = lcm(block_work_size, rowLen) / block_work_size
     */
    const uint expected_grid_size = rowLen / raft::gcd(block_work_size, uint(rowLen));
    // Minimum size of the grid to make the device well occupied
    const uint occupy = getOptimalGridSize<BlockSize>();
    const dim3 gs(std::min(
                    // does not make sense to have more blocks than this
                    raft::ceildiv<uint>(uint(totalLen), block_work_size),
                    // increase the grid size to be not less than `occupy` while
                    // still being the multiple of `expected_grid_size`
                    raft::ceildiv<uint>(occupy, expected_grid_size) * expected_grid_size),
                  1,
                  1);

    matrixLinewiseVecRowsMainKernel<Type, IdxType, VecBytes, BlockSize, Lambda, Vecs...>
      <<<gs, bs, 0, stream>>>(
        out + alignedOff, alignedStart, alignedOff, rowLen, alignedLen, op, vecs...);
    RAFT_CUDA_TRY(cudaPeekAtLastError());
  }
  if (alignedLen < totalLen) {
    // should be not smaller than the warp size for better branching
    constexpr std::size_t MaxOffset = std::max(std::size_t(raft::WarpSize), VecBytes);
    matrixLinewiseVecRowsTailKernel<Type, IdxType, MaxOffset, Lambda, Vecs...>
      <<<dim3(2, 1, 1), dim3(MaxOffset, 1, 1), 0, stream>>>(
        out, in, alignedOff, alignedEnd, rowLen, totalLen, op, vecs...);
    RAFT_CUDA_TRY(cudaPeekAtLastError());
  }
}

/**
 * Select one of the implementations:
 *   a. vectors applied along/across lines
 *   b. recursively try different VecBytes, such that alignments of `in` and `out`
 *      are the same.
 *
 * @tparam VecBytes - size of the load/store ops in bytes.
 * @tparam BlockSize - is fixed and should not affect the performance.
 */
template <std::size_t VecBytes = 16, int BlockSize = 256>
struct MatrixLinewiseOp {
  template <typename Type, typename IdxType, typename Lambda, typename... Vecs>
  static void run(Type* out,
                  const Type* in,
                  const IdxType lineLen,
                  const IdxType nLines,
                  const bool alongLines,
                  Lambda op,
                  cudaStream_t stream,
                  Vecs... vecs)
  {
    if constexpr (VecBytes > sizeof(Type)) {
      if (!raft::Pow2<VecBytes>::areSameAlignOffsets(in, out))
        return MatrixLinewiseOp<std::max((VecBytes >> 1), sizeof(Type)), BlockSize>::run(
          out, in, lineLen, nLines, alongLines, op, stream, vecs...);
    }
    if (alongLines)
      return matrixLinewiseVecRows<Type, IdxType, VecBytes, BlockSize, Lambda, Vecs...>(
        out, in, lineLen, nLines, op, stream, vecs...);
    else
      return matrixLinewiseVecCols<Type, IdxType, VecBytes, BlockSize, Lambda, Vecs...>(
        out, in, lineLen, nLines, op, stream, vecs...);
  }
};

}  // end namespace detail
}  // end namespace matrix
}  // end namespace raft
