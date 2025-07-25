#pragma once

#include <cuda.h>
#include <cuda_runtime.h>

#include <cute/layout.hpp>
#include <cute/tensor.hpp>

#include "common/gather_tensor.h"
#include "common/layout_convertor.h"
#include "common/mask.h"
#include "common/online_softmax.cuh"
#include "mha_params.h"

namespace llm {

using namespace cute;

namespace detail {

template <typename Params>
struct MHATile {
  static_assert(cute::dependent_false<Params>, "not implemented");
};

// AttentionTile specialization for AttentionParams
template <>
struct MHATile<MHAParams> {
  const MHAParams& params_;
  const int batch_idx_;
  const int kv_head_idx_;

  CUTE_HOST_DEVICE MHATile(const MHAParams& params,
                           int batch_idx,
                           int kv_head_idx)
      : params_(params), batch_idx_(batch_idx), kv_head_idx_(kv_head_idx) {}

  // return the query/output tile: (q_len, head_dim)
  template <typename Element>
  CUTE_HOST_DEVICE auto get_qo_tile() const {
    // (batch, seq, head, dim)

    // packed all q/o in the same kv head group together
    auto packed_idx_to_coord = [this](int packed_idx) {
      int idx, offset;
      params_.group_size.divmod(packed_idx, idx, offset);
      return make_coord(idx, offset);
    };

    const auto packed_len = params_.q_len * params_.group_size;
    const auto q_offset =
        (batch_idx_ * get<0>(params_.q_stride)) +
        (kv_head_idx_ * params_.group_size * get<2>(params_.q_stride));
    auto q = make_gather_tensor(
        make_gmem_ptr((const Element*)params_.q_ptr + q_offset),
        make_shape(packed_len, params_.head_dim),
        make_stride(select<1, 2>(params_.q_stride), get<3>(params_.q_stride)),
        packed_idx_to_coord);

    const auto o_offset =
        (batch_idx_ * get<0>(params_.o_stride)) +
        (kv_head_idx_ * params_.group_size * get<2>(params_.o_stride));
    auto o = make_gather_tensor(
        make_gmem_ptr((Element*)params_.o_ptr + o_offset),
        make_shape(packed_len, params_.head_dim),
        make_stride(select<1, 2>(params_.o_stride), get<3>(params_.o_stride)),
        packed_idx_to_coord);
    return make_tuple(q, o);
  }

  // return the key/value tile: (kv_len, head_dim)
  template <typename Element>
  CUTE_HOST_DEVICE auto get_kv_tile() const {
    // (batch, seq, kv_head, dim)
    const auto k_offset = (batch_idx_ * get<0>(params_.k_stride)) +
                          (kv_head_idx_ * get<2>(params_.k_stride));
    const auto v_offset = (batch_idx_ * get<0>(params_.v_stride)) +
                          (kv_head_idx_ * get<2>(params_.v_stride));
    // k[batch_idx, :, kv_head_idx, :]
    auto k =
        make_tensor(make_gmem_ptr((const Element*)params_.k_ptr + k_offset),
                    make_shape(params_.kv_len, params_.head_dim),
                    select<1, 3>(params_.k_stride));
    // v[batch_idx, :, kv_head_idx, :]
    auto v =
        make_tensor(make_gmem_ptr((const Element*)params_.v_ptr + v_offset),
                    make_shape(params_.kv_len, params_.head_dim),
                    select<1, 3>(params_.v_stride));
    return make_tuple(k, v);
  }
};

// paged KV cache + variable length sequence
template <>
struct MHATile<MHAPagedKVParams> {
  // NOLINTNEXTLINE
  const MHAPagedKVParams& params_;
  const int batch_idx_;
  const int kv_head_idx_;

  CUTE_HOST_DEVICE MHATile(const MHAPagedKVParams& params,
                           int batch_idx,
                           int kv_head_idx)
      : params_(params), batch_idx_(batch_idx), kv_head_idx_(kv_head_idx) {}

  // return the query/output tile: (q_len, head_dim)
  template <typename Element>
  CUTE_HOST_DEVICE auto get_qo_tile() const {
    const auto begin = params_.q_cu_lens[batch_idx_];
    const auto qo_len = params_.q_cu_lens[batch_idx_ + 1] - begin;

    auto packed_idx_to_coord = [this](int packed_idx) {
      int idx, offset;
      params_.group_size.divmod(packed_idx, idx, offset);
      return make_coord(idx, offset);
    };

    const auto packed_len = qo_len * params_.group_size;
    const auto q_offset =
        (begin * get<0>(params_.q_stride)) +
        (kv_head_idx_ * params_.group_size * get<1>(params_.q_stride));
    auto q = make_gather_tensor(
        make_gmem_ptr((const Element*)params_.q_ptr + q_offset),
        make_shape(packed_len, params_.head_dim),
        make_stride(select<0, 1>(params_.q_stride), get<2>(params_.q_stride)),
        packed_idx_to_coord);

    const auto o_offset =
        (begin * get<0>(params_.o_stride)) +
        (kv_head_idx_ * params_.group_size * get<1>(params_.o_stride));
    auto o = make_gather_tensor(
        make_gmem_ptr((Element*)params_.o_ptr + o_offset),
        make_shape(packed_len, params_.head_dim),
        make_stride(select<0, 1>(params_.o_stride), get<2>(params_.o_stride)),
        packed_idx_to_coord);
    return make_tuple(q, o);
  }

  // return the key/value tile: (kv_len, head_dim)
  template <typename Element>
  CUTE_HOST_DEVICE auto get_kv_tile() const {
    const auto kv_len =
        params_.kv_cu_lens[batch_idx_ + 1] - params_.kv_cu_lens[batch_idx_];

    // map seq_idx to slot_idx
    const int* block_table =
        params_.block_table + params_.block_cu_lens[batch_idx_];
    auto idx_to_slot = [block_table,
                        shr = params_.block_shift_right,
                        mask = params_.block_mask](int idx) {
      return block_table[idx >> shr] + (idx & mask);
    };

    // v[:, kv_head_idx, :]
    const auto k_offset = kv_head_idx_ * get<1>(params_.k_stride);
    auto k = make_gather_tensor(
        make_gmem_ptr((const Element*)params_.k_ptr + k_offset),
        make_shape(kv_len, params_.head_dim),
        select<0, 2>(params_.k_stride),
        idx_to_slot);

    // v[:, kv_head_idx, :]
    const auto v_offset = kv_head_idx_ * get<1>(params_.v_stride);
    auto v = make_gather_tensor(
        make_gmem_ptr((const Element*)params_.v_ptr + v_offset),
        make_shape(kv_len, params_.head_dim),
        select<0, 2>(params_.v_stride),
        idx_to_slot);
    return make_tuple(k, v);
  }
};
}  // namespace detail

template <class CollectiveMainloop_,
          class CollectiveEpilogue_,
          class TileScheduler_>
class Sm80KernelMha {
 public:
  using CollectiveMainloop = CollectiveMainloop_;
  using CollectiveEpilogue = CollectiveEpilogue_;
  using TileScheduler = TileScheduler_;

  using TiledMma = typename CollectiveMainloop::TiledMma;

  using Element = typename CollectiveMainloop::Element;
  using BLK_M = typename CollectiveMainloop::BLK_M;
  using BLK_N = typename CollectiveMainloop::BLK_N;
  using BLK_K = typename CollectiveMainloop::BLK_K;

  static constexpr int kSharedStorageSize =
      cute::max(sizeof(typename CollectiveMainloop::SharedStorage),
                sizeof(typename CollectiveEpilogue::SharedStorage));

  static constexpr int kMmaThreads = CollectiveMainloop::kMmaThreads;

  // Kernel params
  using MainloopParams = typename CollectiveMainloop::Params;
  using EpilogueParams = typename CollectiveEpilogue::Params;
  using TileSchedulerParams = typename TileScheduler::Params;

  // returns grid and block shape for kernel launch
  static dim3 get_grid_shape(TileSchedulerParams const& params) {
    return TileScheduler::get_grid_shape(params);
  }
  static dim3 get_block_shape() { return kMmaThreads; }

  template <class Params>
  CUTE_DEVICE void operator()(const Params& params,
                              const TileSchedulerParams& scheduler_params,
                              char* smem) {
    static constexpr int kBlockM = CollectiveMainloop::kBlockM;
    static constexpr int kBlockN = CollectiveMainloop::kBlockN;
    static constexpr int kRowsPerMMA = CollectiveMainloop::kRowsPerMMA;

    static constexpr bool kAlibi = CollectiveMainloop::kAlibi;
    static constexpr bool kLocal = CollectiveMainloop::kLocal;

    CollectiveMainloop mha;
    CollectiveEpilogue epilogue;
    TileScheduler scheduler(scheduler_params);

    // construct params
    MainloopParams mainloop_params{params.logits_soft_cap};
    EpilogueParams epilogue_params;

    // process each block
    const auto& group_size = params.group_size;
    for (const auto block_coord : scheduler) {
      // block coord: (m_block_idx, ((kv_head_idx, _0), batch_idx))
      const int m_block_idx = get<0>(block_coord);
      const int kv_head_idx = get<1, 0, 0>(block_coord);
      const int batch_idx = get<1, 1>(block_coord);

      const auto tidx = threadIdx.x;

      // (q_packed_len, BLK_K)
      detail::MHATile<Params> tile(params, batch_idx, kv_head_idx);
      auto [Q, O] = tile.template get_qo_tile<Element>();
      // (kv_len, BLK_K)
      auto [K, V] = tile.template get_kv_tile<Element>();

      // problem shape
      const int q_packed_len = size<0>(Q);
      const int kv_len = size<0>(K);
      const int m_block_base = m_block_idx * kBlockM;
      if (m_block_base >= q_packed_len) {
        // m out of bound, skip this block
        continue;
      }

      const int q_idx = m_block_base / group_size;
      const auto residue_mnk =
          make_tuple(q_packed_len, kv_len, params.head_dim);

      const int sliding_window = kLocal ? params.sliding_window : kv_len;
      const int q_len = q_packed_len / group_size;

      const int diagonal = q_idx + kv_len - q_len;
      const int kv_idx_min = std::max(0, diagonal - sliding_window);
      const int kv_idx_max = std::min(kv_len, diagonal + kBlockM);
      const int n_block_min = kLocal ? kv_idx_min / kBlockN : 0;
      const int n_block_max = cute::ceil_div(kv_idx_max, kBlockN);

      // (BLK_M, BLK_K)
      Tensor gQ =
          local_tile(Q, Shape<BLK_M, BLK_K>{}, make_coord(m_block_idx, _0{}));
      Tensor gO =
          local_tile(O, Shape<BLK_M, BLK_K>{}, make_coord(m_block_idx, _0{}));
      // (BLK_M, BLK_K) => (M, K)
      Tensor cQ = local_tile(make_identity_tensor(Q.shape()),
                             Shape<BLK_M, BLK_K>{},
                             make_coord(m_block_idx, _0{}));

      // (BLK_N, BLK_K, n)
      Tensor gK = local_tile(K, Shape<BLK_N, BLK_K>{}, make_coord(_, _0{}));
      Tensor gV = local_tile(V, Shape<BLK_N, BLK_K>{}, make_coord(_, _0{}));
      // (BLK_N, BLK_K, n) => (N, K)
      Tensor cKV = local_tile(make_identity_tensor(K.shape()),
                              Shape<BLK_N, BLK_K>{},
                              make_coord(_, _0{}));

      // (BLK_M, BLK_N, n) => (M, N)
      Tensor cMN =
          local_tile(make_identity_tensor(make_shape(q_packed_len, kv_len)),
                     Shape<BLK_M, BLK_N>{},
                     make_coord(m_block_idx, _));

      TiledMma tiled_mma;
      // accumulator: (MMA,MMA_M,MMA_K)
      auto tOrAccO = partition_fragment_C(tiled_mma, Shape<BLK_M, BLK_K>{});
      clear(tOrAccO);

      auto thr_mma = tiled_mma.get_slice(tidx);
      // (MMA, MMA_M, MMA_N, n) => (M, N)
      auto tScMN = thr_mma.partition_C(cMN);
      // ((2, MMA_M), (2, MMA_N), n) => (M, N)
      auto tScMN_mn =
          make_tensor(tScMN.data(), LayoutConvertor::to_mn(tScMN.layout()));

      constexpr int kRowsPerThr = kRowsPerMMA * size<1>(tOrAccO);
      // Create softmax and mask
      OnlineSoftmax<kRowsPerThr> softmax(params.sm_scale_log2);
      Mask<kRowsPerThr, kAlibi, kLocal> mask(
          q_len, kv_len, group_size, sliding_window);
      if constexpr (kAlibi) {
        const auto tScS_mn = tScMN_mn(_, _, _0{});
        mask.init_alibi(
            tScS_mn, kv_head_idx, params.sm_scale, params.alibi_slopes_ptr);
      }

      // mainloop: process kv in range: [n_block_min, n_block_max)
      if (n_block_min < n_block_max) {
        mha(mainloop_params,
            gQ,
            cQ,
            gK,
            gV,
            cKV,
            tScMN_mn,
            tOrAccO,
            softmax,
            mask,
            tidx,
            residue_mnk,
            n_block_min,
            n_block_max,
            smem);
      }

      // epilogue
      epilogue(
          epilogue_params, tOrAccO, tiled_mma, gO, cQ, tidx, residue_mnk, smem);
    }
  }
};

}  // namespace llm
