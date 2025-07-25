#include <gtest/gtest.h>
#include <torch/torch.h>

#include <cstdint>
#include <cute/layout.hpp>

#include "fmha_params.h"
#include "fmha_runner.h"
#include "tests/mha_ref.h"

namespace llm {
#define DISPATCH_HEAD_DIM_(HEAD_DIM_V, HEAD_DIM_NAME, ...) \
  [&] {                                                    \
    if (HEAD_DIM_V <= 64) {                                \
      constexpr static int HEAD_DIM_NAME = 64;             \
      return __VA_ARGS__();                                \
    } else {                                               \
      assert(false);                                       \
    }                                                      \
  }()

#define DISPATCH_TORCH_DTYPE_(TORCH_DTYPE, TYPE_NAME, ...) \
  [&] {                                                    \
    if (TORCH_DTYPE == torch::kHalf) {                     \
      using TYPE_NAME = cute::half_t;                      \
      return __VA_ARGS__();                                \
    } else {                                               \
      assert(false);                                       \
    }                                                      \
  }()

namespace {
torch::Tensor sm120_fmha(
    torch::Tensor query,  // [batch_size, q_len, n_heads, head_dim]
    torch::Tensor key,    // [batch_size, kv_len, n_kv_heads, head_dim]
    torch::Tensor value,  // [batch_size, kv_len, n_kv_heads, head_dim]
    torch::optional<torch::Tensor> alibi_slopes,  //[n_heads]
    float logits_soft_cap,
    int32_t sliding_window,
    int32_t max_q_len) {
  const auto batch_size = query.size(0);
  const auto q_len = query.size(-3);
  const auto kv_len = key.size(-3);
  const auto n_heads = query.size(-2);
  const auto n_kv_heads = key.size(-2);
  const auto head_dim = query.size(-1);

  auto out = torch::empty_like(query);

  const float sm_scale = 1.0 / sqrt(head_dim);

  // construct attention params
  FmhaParams params;
  params.q_ptr = query.const_data_ptr();
  params.k_ptr = key.const_data_ptr();
  params.v_ptr = value.const_data_ptr();
  params.o_ptr = out.mutable_data_ptr();

  params.q_batch_stride = query.stride(0);
  params.q_seq_stride = query.stride(1);
  params.q_head_stride = query.stride(2);

  params.k_batch_stride = key.stride(0);
  params.k_seq_stride = key.stride(1);
  params.k_head_stride = key.stride(2);

  params.v_batch_stride = value.stride(0);
  params.v_seq_stride = value.stride(1);
  params.v_head_stride = value.stride(2);

  params.o_batch_stride = out.stride(0);
  params.o_seq_stride = out.stride(1);
  params.o_head_stride = out.stride(2);

  params.batch_size = batch_size;
  params.n_heads = n_heads;
  params.n_kv_heads = n_kv_heads;
  params.head_dim = head_dim;

  params.q_len = q_len;
  params.kv_len = kv_len;

  params.sliding_window = sliding_window;
  params.logits_soft_cap = logits_soft_cap;
  params.sm_scale = sm_scale;

  params.alibi_slopes_ptr = alibi_slopes.has_value()
                                ? alibi_slopes.value().const_data_ptr<float>()
                                : nullptr;

  // params.max_q_len = max_q_len;
  using ArchTag = cutlass::arch::Sm120;
  DISPATCH_TORCH_DTYPE_(query.dtype(), Dtype, [&] {
    DISPATCH_HEAD_DIM_(head_dim, HEAD_DIM, [&] {
      FmhaRunner<ArchTag, Dtype, HEAD_DIM>::run(params, /*stream=*/nullptr);
    });
  });
  return out;
}

}  // namespace

class MHAKernelTest
    : public ::testing::TestWithParam<std::tuple<torch::ScalarType /*q_dtype*/,
                                                 int64_t /*batch_size*/,
                                                 int64_t /*q_len*/,
                                                 int64_t /*kv_len*/,
                                                 int64_t /*n_heads*/,
                                                 int64_t /*n_kv_heads*/,
                                                 int64_t /*head_dim*/,
                                                 float /*logits_soft_cap*/,
                                                 bool /*alibi*/,
                                                 int32_t /*sliding_window*/>> {
 public:
  void SetUp() override {
    // Set random seed for test stability
    torch::manual_seed(0);
  }
};

TEST_P(MHAKernelTest, FMHA) {
  const auto [dtype,
              batch_size,
              q_len,
              kv_len,
              n_heads,
              n_kv_heads,
              head_dim,
              logits_soft_cap,
              alibi,
              sliding_window] = GetParam();

  const auto options = torch::dtype(dtype).device(torch::kCUDA);

  // construct non-contiguous query, key and value
  const auto& query =
      torch::randn({batch_size, q_len, n_heads, head_dim}, options);

  const auto kv =
      torch::randn({batch_size, kv_len, 2 * n_kv_heads, head_dim}, options)
          .chunk(/*chunks=*/2, /*dim=*/2);
  const auto& key = kv[0];
  const auto& value = kv[1];

  torch::optional<torch::Tensor> alibi_slopes;
  if (alibi) {
    alibi_slopes =
        torch::randn({n_heads},
                     torch::dtype(torch::kFloat32).device(torch::kCUDA)) /
        kv_len;
  }

  auto ref_out = mha_batch_ref(
      query, key, value, alibi_slopes, logits_soft_cap, sliding_window);
  auto out = sm120_fmha(
      query, key, value, alibi_slopes, logits_soft_cap, sliding_window, q_len);

  if (dtype == torch::kBFloat16) {
    EXPECT_TRUE(torch::allclose(out, ref_out, /*rtol=*/1e-2, /*atol=*/1e-2));
  } else {
    EXPECT_TRUE(torch::allclose(out, ref_out, /*rtol=*/1e-3, /*atol=*/1e-3));
  }
}

INSTANTIATE_TEST_SUITE_P(
    SM120,
    MHAKernelTest,
    ::testing::Combine(
        ::testing::Values(torch::kHalf),                     // q_dtype
        ::testing::Values(1, 2, 4),                          // batch_size
        ::testing::Values(1, 62, 125),                       // q_len
        ::testing::Values(127, 287, 1000),                   // kv_len
        ::testing::Values(6),                                // n_heads
        ::testing::Values(6 /*mha*/, 3 /*gqa*/, 1 /*mqa*/),  // n_kv_heads
        ::testing::Values(32, 64),                           // head_dim
        ::testing::Values(0.0, 50.0),                        // logits_soft_cap
        ::testing::Values(false, true),                      // alibi slope
        ::testing::Values(-1, 0, 10)                         // sliding window
        ));

}  // namespace llm
