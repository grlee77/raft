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

#ifndef __MAKE_BLOBS_H
#define __MAKE_BLOBS_H

#pragma once

#include "detail/make_blobs.cuh"
#include <optional>
#include <raft/mdarray.hpp>

namespace raft::random {

/**
 * @brief GPU-equivalent of sklearn.datasets.make_blobs
 *
 * @tparam DataT output data type
 * @tparam IdxT  indexing arithmetic type
 *
 * @param[out] out                generated data [on device]
 *                                [dim = n_rows x n_cols]
 * @param[out] labels             labels for the generated data [on device]
 *                                [len = n_rows]
 * @param[in]  n_rows             number of rows in the generated data
 * @param[in]  n_cols             number of columns in the generated data
 * @param[in]  n_clusters         number of clusters (or classes) to generate
 * @param[in]  stream             cuda stream to schedule the work on
 * @param[in]  row_major          whether input `centers` and output `out`
 *                                buffers are to be stored in row or column
 *                                major layout
 * @param[in]  centers            centers of each of the cluster, pass a nullptr
 *                                if you need this also to be generated randomly
 *                                [on device] [dim = n_clusters x n_cols]
 * @param[in]  cluster_std        standard deviation of each cluster center,
 *                                pass a nullptr if this is to be read from the
 *                                `cluster_std_scalar`. [on device]
 *                                [len = n_clusters]
 * @param[in]  cluster_std_scalar if 'cluster_std' is nullptr, then use this as
 *                                the std-dev across all dimensions.
 * @param[in]  shuffle            shuffle the generated dataset and labels
 * @param[in]  center_box_min     min value of box from which to pick cluster
 *                                centers. Useful only if 'centers' is nullptr
 * @param[in]  center_box_max     max value of box from which to pick cluster
 *                                centers. Useful only if 'centers' is nullptr
 * @param[in]  seed               seed for the RNG
 * @param[in]  type               RNG type
 */
template <typename DataT, typename IdxT>
void make_blobs(DataT* out,
                IdxT* labels,
                IdxT n_rows,
                IdxT n_cols,
                IdxT n_clusters,
                cudaStream_t stream,
                bool row_major                 = true,
                const DataT* centers           = nullptr,
                const DataT* cluster_std       = nullptr,
                const DataT cluster_std_scalar = (DataT)1.0,
                bool shuffle                   = true,
                DataT center_box_min           = (DataT)-10.0,
                DataT center_box_max           = (DataT)10.0,
                uint64_t seed                  = 0ULL,
                GeneratorType type             = GenPhilox)
{
  detail::make_blobs_caller(out,
                            labels,
                            n_rows,
                            n_cols,
                            n_clusters,
                            stream,
                            row_major,
                            centers,
                            cluster_std,
                            cluster_std_scalar,
                            shuffle,
                            center_box_min,
                            center_box_max,
                            seed,
                            type);
}

/**
 * @brief GPU-equivalent of sklearn.datasets.make_blobs
 *
 * @tparam DataT output data type
 * @tparam IdxT  indexing arithmetic type
 *
 * @param[in] handle raft handle for managing expensive resources
 * @param[out] out                generated data [on device]
 *                                [dim = n_rows x n_cols]
 * @param[out] labels             labels for the generated data [on device]
 *                                [len = n_rows]
 * @param[in]  n_clusters         number of clusters (or classes) to generate
 * @param[in]  centers            centers of each of the cluster, pass a nullptr
 *                                if you need this also to be generated randomly
 *                                [on device] [dim = n_clusters x n_cols]
 * @param[in]  cluster_std        standard deviation of each cluster center,
 *                                pass a nullptr if this is to be read from the
 *                                `cluster_std_scalar`. [on device]
 *                                [len = n_clusters]
 * @param[in]  cluster_std_scalar if 'cluster_std' is nullptr, then use this as
 *                                the std-dev across all dimensions.
 * @param[in]  shuffle            shuffle the generated dataset and labels
 * @param[in]  center_box_min     min value of box from which to pick cluster
 *                                centers. Useful only if 'centers' is nullptr
 * @param[in]  center_box_max     max value of box from which to pick cluster
 *                                centers. Useful only if 'centers' is nullptr
 * @param[in]  seed               seed for the RNG
 * @param[in]  type               RNG type
 */
template <typename DataT, typename IdxT, typename layout>
void make_blobs(raft::handle_t const& handle,
                raft::device_matrix_view<DataT, layout> out,
                raft::device_vector_view<IdxT> labels,
                IdxT n_clusters                                                  = 5,
                std::optional<raft::device_matrix_view<DataT, layout>> centers   = std::nullopt,
                std::optional<raft::device_vector_view<DataT>> const cluster_std = std::nullopt,
                const DataT cluster_std_scalar                                   = (DataT)1.0,
                bool shuffle                                                     = true,
                DataT center_box_min                                             = (DataT)-10.0,
                DataT center_box_max                                             = (DataT)10.0,
                uint64_t seed                                                    = 0ULL,
                GeneratorType type                                               = GenPhilox)
{
  if (centers.has_value()) {
    RAFT_EXPECTS(centers.value().extent(0) == (std::size_t)n_clusters,
                 "n_centers must equal size of centers");
  }

  if (cluster_std.has_value()) {
    RAFT_EXPECTS(cluster_std.value().extent(0) == (std::size_t)n_clusters,
                 "n_centers must equal size of cluster_std");
  }

  RAFT_EXPECTS(out.extent(0) == labels.extent(0),
               "Number of labels must equal the number of row in output matrix");

  RAFT_EXPECTS(out.is_contiguous(), "Output must be contiguous.");

  bool row_major = std::is_same<layout, raft::layout_c_contiguous>::value;

  auto prm_centers     = centers.has_value() ? centers.value().data() : nullptr;
  auto prm_cluster_std = cluster_std.has_value() ? cluster_std.value().data() : nullptr;

  detail::make_blobs_caller(out.data(),
                            labels.data(),
                            (IdxT)out.extent(0),
                            (IdxT)out.extent(1),
                            n_clusters,
                            handle.get_stream(),
                            row_major,
                            prm_centers,
                            prm_cluster_std,
                            cluster_std_scalar,
                            shuffle,
                            center_box_min,
                            center_box_max,
                            seed,
                            type);
}
}  // end namespace raft::random

#endif