include(cc_library)
include(cc_test)


cc_library(
  NAME 
    attention
  HDRS 
    handler.h
    ref_handler.h
    flash_attn_handler.h
    flash_infer_handler.h
    attention.h
  SRCS 
    handler.cpp
    ref_handler.cpp
    flash_attn_handler.cpp
    flash_infer_handler.cpp
    attention.cpp
  DEPS
    :state_dict
    :memory
    :pos_embedding
    :kernels
    :flash_attn.kernels
    # :flash_infer.kernels
    glog::glog
    gflags::gflags
    torch
)

cc_test(
  NAME
    attention_test
  SRCS
    attention_test.cpp
  DEPS
    :attention
    absl::random_random
    GTest::gtest_main
)
