from typing import Callable, List, Optional

import torch

from scalellm._C.llm_handler import Future, Priority
from scalellm._C.output import RequestOutput
from scalellm._C.sampling_params import SamplingParams

class VLMHandler:
    class Options:
        def __init__(self) -> None: ...
        def __repr__(self) -> str: ...
        model_path: str
        devices: Optional[str]
        block_size: int
        max_cache_size: int
        max_memory_utilization: float
        enable_prefix_cache: bool
        enable_cuda_graph: bool
        cuda_graph_max_seq_len: int
        cuda_graph_batch_sizes: Optional[List[int]]
        max_tokens_per_batch: int
        max_seqs_per_batch: int
        num_handling_threads: int
        image_input_type: str
        image_token_id: int
        image_input_shape: str
        image_feature_size: int

    def __init__(self, options: Options) -> None: ...
    def __repr__(self) -> str: ...
    def schedule_async(
        self,
        image: torch.Tensor,
        prompt: str,
        sp: SamplingParams,
        priority: Priority,
        stream: bool,
        callback: Callable[[RequestOutput], bool],
    ) -> Future: ...
    def start(self) -> None: ...
    def stop(self) -> None: ...
    def run_until_complete(self) -> None: ...
    def reset(self) -> None: ...
    # helper functions
    def encode(self, text: str) -> List[int]: ...
    def decode(self, tokens: List[int], skip_special_tokens: bool) -> str: ...
