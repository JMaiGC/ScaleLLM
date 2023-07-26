#include "sentencepiece_tokenizer.h"

#include <glog/logging.h>

namespace llm {

SentencePieceTokenizer::SentencePieceTokenizer(const std::string& model_path) {
  const auto status = sp_processor_.Load(model_path);
  if (!status.ok()) {
    LOG(FATAL) << "Failed to load SentencePiece model: " << status.ToString();
  }
}

std::vector<int> SentencePieceTokenizer::Encode(
    const std::string_view& text) const {
  std::vector<int> tokens;
  const auto status = sp_processor_.Encode(text, &tokens);
  if (!status.ok()) {
    LOG(ERROR) << "Failed to encode text: " << status.ToString();
  }
  return tokens;
}

std::string SentencePieceTokenizer::Decode(const std::vector<int>& ids) const {
  std::string text;
  const auto status = sp_processor_.Decode(ids, &text);
  if (!status.ok()) {
    LOG(ERROR) << "Failed to decode ids: " << status.ToString();
  }
  return text;
}

}  // namespace llm