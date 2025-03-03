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

#include <common/nvtx.hpp>
#include <raft/common/nvtx.hpp>
#include <raft/cudart_utils.h>
#include <raft/linalg/detail/cublas_wrappers.hpp>
#include <raft/linalg/detail/cusolver_wrappers.hpp>
#include <raft/linalg/eig.cuh>
#include <raft/linalg/eltwise.cuh>
#include <raft/linalg/gemm.cuh>
#include <raft/linalg/gemv.cuh>
#include <raft/linalg/qr.cuh>
#include <raft/linalg/svd.cuh>
#include <raft/linalg/transpose.cuh>
#include <raft/matrix/math.cuh>
#include <raft/matrix/matrix.cuh>
#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_scalar.hpp>
#include <rmm/device_uvector.hpp>

namespace raft {
namespace linalg {
namespace detail {

namespace {

/** Operate a CUDA event if we're in the concurrent mode; no-op otherwise. */
struct DeviceEvent {
 private:
  cudaEvent_t e;

 public:
  DeviceEvent(bool concurrent)
  {
    if (concurrent)
      RAFT_CUDA_TRY(cudaEventCreateWithFlags(&e, cudaEventDisableTiming));
    else
      e = nullptr;
  }

  ~DeviceEvent()
  {
    if (e != nullptr) RAFT_CUDA_TRY_NO_THROW(cudaEventDestroy(e));
  }

  void record(cudaStream_t stream)
  {
    if (e != nullptr) RAFT_CUDA_TRY(cudaEventRecord(e, stream));
  }

  void wait_by(cudaStream_t stream)
  {
    if (e != nullptr) RAFT_CUDA_TRY(cudaStreamWaitEvent(stream, e, 0u));
  }

  DeviceEvent& operator=(const DeviceEvent& other) = delete;
};

/**
 *  @brief Tells if the viewed CUDA stream is implicitly synchronized with the given stream.
 *
 *  This can happen e.g.
 *   if the two views point to the same stream
 *   or sometimes when one of them is the legacy default stream.
 */
bool are_implicitly_synchronized(rmm::cuda_stream_view a, rmm::cuda_stream_view b)
{
  // any stream is "synchronized" with itself
  if (a.value() == b.value()) return true;
  // legacy + blocking streams
  unsigned int flags = 0;
  if (a.is_default()) {
    RAFT_CUDA_TRY(cudaStreamGetFlags(b.value(), &flags));
    if ((flags & cudaStreamNonBlocking) == 0) return true;
  }
  if (b.is_default()) {
    RAFT_CUDA_TRY(cudaStreamGetFlags(a.value(), &flags));
    if ((flags & cudaStreamNonBlocking) == 0) return true;
  }
  return false;
}

template <typename math_t>
struct DivideByNonZero {
  constexpr static const math_t eps = math_t(1e-10);

  __device__ math_t

  operator()(const math_t a, const math_t b) const
  {
    return raft::myAbs<math_t>(b) >= eps ? a / b : a;
  }
};

}  // namespace

/** Solves the linear ordinary least squares problem `Aw = b`
 *  Via SVD decomposition of `A = U S Vt` using default cuSOLVER routine.
 *
 *  @param A - input feature matrix; it's marked [in/out] in the used cuSOLVER routines,
 *             so it's not guaranteed to stay unmodified.
 */
template <typename math_t>
void lstsqSvdQR(const raft::handle_t& handle,
                math_t* A,
                const int n_rows,
                const int n_cols,
                const math_t* b,
                math_t* w,
                cudaStream_t stream)
{
  const int minmn              = min(n_rows, n_cols);
  cusolverDnHandle_t cusolverH = handle.get_cusolver_dn_handle();
  int cusolverWorkSetSize      = 0;
  // #TODO: Call from public API when ready
  RAFT_CUSOLVER_TRY(raft::linalg::detail::cusolverDngesvd_bufferSize<math_t>(
    cusolverH, n_rows, n_cols, &cusolverWorkSetSize));

  rmm::device_uvector<math_t> workset(cusolverWorkSetSize  // cuSolver
                                        + n_rows * minmn   // U
                                        + n_cols * n_cols  // V
                                        + minmn            // S
                                        + minmn            // U^T * b
                                        + 1                // devInfo
                                      ,
                                      stream);
  math_t* cusolverWorkSet = workset.data();
  math_t* U               = cusolverWorkSet + cusolverWorkSetSize;
  math_t* Vt              = U + n_rows * minmn;
  math_t* S               = Vt + n_cols * n_cols;
  math_t* Ub              = S + minmn;
  int* devInfo            = reinterpret_cast<int*>(Ub + minmn);

  // #TODO: Call from public API when ready
  RAFT_CUSOLVER_TRY(raft::linalg::detail::cusolverDngesvd<math_t>(cusolverH,
                                                                  'S',
                                                                  'S',
                                                                  n_rows,
                                                                  n_cols,
                                                                  A,
                                                                  n_rows,
                                                                  S,
                                                                  U,
                                                                  n_rows,
                                                                  Vt,
                                                                  n_cols,
                                                                  cusolverWorkSet,
                                                                  cusolverWorkSetSize,
                                                                  nullptr,
                                                                  devInfo,
                                                                  stream));
  raft::linalg::gemv(handle, U, n_rows, minmn, b, Ub, true, stream);
  raft::linalg::binaryOp(Ub, Ub, S, minmn, DivideByNonZero<math_t>(), stream);
  raft::linalg::gemv(handle, Vt, minmn, n_cols, n_cols, Ub, w, true, stream);
}

/** Solves the linear ordinary least squares problem `Aw = b`
 *  Via SVD decomposition of `A = U S V^T` using Jacobi iterations (cuSOLVER).
 *
 *  @param A - input feature matrix; it's marked [in/out] in the used cuSOLVER routines,
 *             so it's not guaranteed to stay unmodified.
 */
template <typename math_t>
void lstsqSvdJacobi(const raft::handle_t& handle,
                    math_t* A,
                    const int n_rows,
                    const int n_cols,
                    const math_t* b,
                    math_t* w,
                    cudaStream_t stream)
{
  const int minmn = min(n_rows, n_cols);
  gesvdjInfo_t gesvdj_params;
  RAFT_CUSOLVER_TRY(cusolverDnCreateGesvdjInfo(&gesvdj_params));
  int cusolverWorkSetSize      = 0;
  cusolverDnHandle_t cusolverH = handle.get_cusolver_dn_handle();
  // #TODO: Call from public API when ready
  RAFT_CUSOLVER_TRY(
    raft::linalg::detail::cusolverDngesvdj_bufferSize<math_t>(cusolverH,
                                                              CUSOLVER_EIG_MODE_VECTOR,
                                                              1,
                                                              n_rows,
                                                              n_cols,
                                                              A,
                                                              n_rows,
                                                              nullptr,
                                                              nullptr,
                                                              n_rows,
                                                              nullptr,
                                                              n_cols,
                                                              &cusolverWorkSetSize,
                                                              gesvdj_params));
  rmm::device_uvector<math_t> workset(cusolverWorkSetSize  // cuSolver
                                        + n_rows * minmn   // U
                                        + n_cols * minmn   // V
                                        + minmn            // S
                                        + minmn            // U^T * b
                                        + 1                // devInfo
                                      ,
                                      stream);
  math_t* cusolverWorkSet = workset.data();
  math_t* U               = cusolverWorkSet + cusolverWorkSetSize;
  math_t* V               = U + n_rows * minmn;
  math_t* S               = V + n_cols * minmn;
  math_t* Ub              = S + minmn;
  int* devInfo            = reinterpret_cast<int*>(Ub + minmn);
  // #TODO: Call from public API when ready
  RAFT_CUSOLVER_TRY(raft::linalg::detail::cusolverDngesvdj<math_t>(cusolverH,
                                                                   CUSOLVER_EIG_MODE_VECTOR,
                                                                   1,
                                                                   n_rows,
                                                                   n_cols,
                                                                   A,
                                                                   n_rows,
                                                                   S,
                                                                   U,
                                                                   n_rows,
                                                                   V,
                                                                   n_cols,
                                                                   cusolverWorkSet,
                                                                   cusolverWorkSetSize,
                                                                   devInfo,
                                                                   gesvdj_params,
                                                                   stream));
  raft::linalg::gemv(handle, U, n_rows, minmn, b, Ub, true, stream);
  raft::linalg::binaryOp(Ub, Ub, S, minmn, DivideByNonZero<math_t>(), stream);
  raft::linalg::gemv(handle, V, n_cols, minmn, Ub, w, false, stream);
}

/** Solves the linear ordinary least squares problem `Aw = b`
 *  via eigenvalue decomposition of `A^T * A` (covariance matrix for dataset A).
 *  (`w = (A^T A)^-1  A^T b`)
 */
template <typename math_t>
void lstsqEig(const raft::handle_t& handle,
              const math_t* A,
              const int n_rows,
              const int n_cols,
              const math_t* b,
              math_t* w,
              cudaStream_t stream)
{
  rmm::cuda_stream_view mainStream   = rmm::cuda_stream_view(stream);
  rmm::cuda_stream_view multAbStream = handle.get_next_usable_stream();
  bool concurrent;
  // Check if the two streams can run concurrently. This is needed because a legacy default stream
  // would synchronize with other blocking streams. To avoid synchronization in such case, we try to
  // use an additional stream from the pool.
  if (!are_implicitly_synchronized(mainStream, multAbStream)) {
    concurrent = true;
  } else if (handle.get_stream_pool_size() > 1) {
    mainStream = handle.get_next_usable_stream();
    concurrent = true;
  } else {
    multAbStream = mainStream;
    concurrent   = false;
  }

  rmm::device_uvector<math_t> workset(n_cols * n_cols * 3 + n_cols * 2, mainStream);
  // the event is created only if the given raft handle is capable of running
  // at least two CUDA streams without implicit synchronization.
  DeviceEvent worksetDone(concurrent);
  worksetDone.record(mainStream);
  math_t* Q    = workset.data();
  math_t* QS   = Q + n_cols * n_cols;
  math_t* covA = QS + n_cols * n_cols;
  math_t* S    = covA + n_cols * n_cols;
  math_t* Ab   = S + n_cols;

  // covA <- A* A
  math_t alpha = math_t(1);
  math_t beta  = math_t(0);
  raft::linalg::gemm(handle,
                     A,
                     n_rows,
                     n_cols,
                     A,
                     covA,
                     n_cols,
                     n_cols,
                     CUBLAS_OP_T,
                     CUBLAS_OP_N,
                     alpha,
                     beta,
                     mainStream);

  // Ab <- A* b
  worksetDone.wait_by(multAbStream);
  raft::linalg::gemv(handle, A, n_rows, n_cols, b, Ab, true, multAbStream);
  DeviceEvent multAbDone(concurrent);
  multAbDone.record(multAbStream);

  // Q S Q* <- covA
  raft::common::nvtx::push_range("raft::linalg::eigDC");
  raft::linalg::eigDC(handle, covA, n_cols, n_cols, Q, S, mainStream);
  raft::common::nvtx::pop_range();

  // QS  <- Q invS
  raft::linalg::matrixVectorOp(
    QS, Q, S, n_cols, n_cols, false, true, DivideByNonZero<math_t>(), mainStream);
  // covA <- QS Q* == Q invS Q* == inv(A* A)
  raft::linalg::gemm(handle,
                     QS,
                     n_cols,
                     n_cols,
                     Q,
                     covA,
                     n_cols,
                     n_cols,
                     CUBLAS_OP_N,
                     CUBLAS_OP_T,
                     alpha,
                     beta,
                     mainStream);

  multAbDone.wait_by(mainStream);
  // w <- covA Ab == Q invS Q* A b == inv(A* A) A b
  raft::linalg::gemv(handle, covA, n_cols, n_cols, Ab, w, false, mainStream);

  // This event is created only if we use two worker streams, and `stream` is not the legacy stream,
  // and `mainStream` is not a non-blocking stream. In fact, with the current logic these conditions
  // are impossible together, but it still makes sense to put this construct here to emphasize that
  // `stream` must wait till the work here is done (for future refactorings).
  DeviceEvent mainDone(!are_implicitly_synchronized(mainStream, stream));
  mainDone.record(mainStream);
  mainDone.wait_by(stream);
}

/** Solves the linear ordinary least squares problem `Aw = b`
 *  via QR decomposition of `A = QR`.
 *  (triangular system of equations `Rw = Q^T b`)
 *
 * @param A[in/out] - input feature matrix.
 *            Warning: the content of this matrix is modified by the cuSOLVER routines.
 * @param b[in/out] - input target vector.
 *            Warning: the content of this vector is modified by the cuSOLVER routines.
 */
template <typename math_t>
void lstsqQR(const raft::handle_t& handle,
             math_t* A,
             const int n_rows,
             const int n_cols,
             math_t* b,
             math_t* w,
             cudaStream_t stream)
{
  cublasHandle_t cublasH       = handle.get_cublas_handle();
  cusolverDnHandle_t cusolverH = handle.get_cusolver_dn_handle();

  int m = n_rows;
  int n = n_cols;

  int info = 0;
  rmm::device_uvector<math_t> d_tau(n, stream);
  rmm::device_scalar<int> d_info(stream);

  const cublasSideMode_t side   = CUBLAS_SIDE_LEFT;
  const cublasOperation_t trans = CUBLAS_OP_T;

  int lwork_geqrf = 0;
  int lwork_ormqr = 0;
  int lwork       = 0;

  const int lda = m;
  const int ldb = m;

  // #TODO: Call from public API when ready
  RAFT_CUSOLVER_TRY(
    raft::linalg::detail::cusolverDngeqrf_bufferSize(cusolverH, m, n, A, lda, &lwork_geqrf));

  // #TODO: Call from public API when ready
  RAFT_CUSOLVER_TRY(raft::linalg::detail::cusolverDnormqr_bufferSize(cusolverH,
                                                                     side,
                                                                     trans,
                                                                     m,
                                                                     1,
                                                                     n,
                                                                     A,
                                                                     lda,
                                                                     d_tau.data(),
                                                                     b,    // C,
                                                                     lda,  // ldc,
                                                                     &lwork_ormqr));

  lwork = (lwork_geqrf > lwork_ormqr) ? lwork_geqrf : lwork_ormqr;

  rmm::device_uvector<math_t> d_work(lwork, stream);

  // #TODO: Call from public API when ready
  RAFT_CUSOLVER_TRY(raft::linalg::detail::cusolverDngeqrf(
    cusolverH, m, n, A, lda, d_tau.data(), d_work.data(), lwork, d_info.data(), stream));

  RAFT_CUDA_TRY(cudaMemcpyAsync(&info, d_info.data(), sizeof(int), cudaMemcpyDeviceToHost, stream));
  RAFT_CUDA_TRY(cudaStreamSynchronize(stream));
  ASSERT(0 == info, "lstsq.h: QR wasn't successful");

  // #TODO: Call from public API when ready
  RAFT_CUSOLVER_TRY(raft::linalg::detail::cusolverDnormqr(cusolverH,
                                                          side,
                                                          trans,
                                                          m,
                                                          1,
                                                          n,
                                                          A,
                                                          lda,
                                                          d_tau.data(),
                                                          b,
                                                          ldb,
                                                          d_work.data(),
                                                          lwork,
                                                          d_info.data(),
                                                          stream));

  RAFT_CUDA_TRY(cudaMemcpyAsync(&info, d_info.data(), sizeof(int), cudaMemcpyDeviceToHost, stream));
  RAFT_CUDA_TRY(cudaStreamSynchronize(stream));
  ASSERT(0 == info, "lstsq.h: QR wasn't successful");

  const math_t one = 1;

  // #TODO: Call from public API when ready
  RAFT_CUBLAS_TRY(raft::linalg::detail::cublastrsm(cublasH,
                                                   side,
                                                   CUBLAS_FILL_MODE_UPPER,
                                                   CUBLAS_OP_N,
                                                   CUBLAS_DIAG_NON_UNIT,
                                                   n,
                                                   1,
                                                   &one,
                                                   A,
                                                   lda,
                                                   b,
                                                   ldb,
                                                   stream));

  RAFT_CUDA_TRY(cudaMemcpyAsync(w, b, sizeof(math_t) * n, cudaMemcpyDeviceToDevice, stream));
}
};  // namespace detail
};  // namespace linalg
};  // namespace raft
