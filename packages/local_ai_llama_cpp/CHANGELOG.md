# Changelog

## 0.0.3

- First pub.dev release of the llama.cpp adapter, with streaming GGUF chat,
  embeddings, persistent KV-cache planning and GBNF-constrained output.
- Add model-family chat templates and bring-your-own native library support.

## 0.0.2

- Initial release of the llama.cpp adapter: `LlamaCppLlmAdapter` (any GGUF
  chat model, streaming, GBNF-constrained structured output),
  `LlamaCppEmbeddingAdapter` (the first `LocalEmbedding` implementation in
  the kit) and `LlamaCppAdapterPlugin` under provider key `llama-cpp`.
