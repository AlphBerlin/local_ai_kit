# Changelog

## 0.0.3

- Add llama.cpp-backed LLM and embedding support to the facade and model hub.
- Support registering external, bring-your-own model files.
- Expand the bundled catalog with GGUF, Moonshine v2 and Dolphin models.

## 0.0.2

- Extract sentence boundaries from streaming LLM text and pipeline responses
  into per-sentence TTS for lower time-to-first-audio.
- Cancel barge-in before stopping output to avoid audio glitches.
- Introduce a Model Context Protocol (MCP) plugin architecture.
- Coordinated version bump; correct the bundled `LICENSE` text.

## 0.0.1

- Initial public release.
