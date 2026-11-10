# Acknowledgements

SnippAI ships with these third-party components. Thank you to their authors.

## FluidAudio
Local speech-to-text SDK (Core ML inference on the Apple Neural Engine).
- Author: FluidInference
- License: Apache License 2.0
- Source: https://github.com/FluidInference/FluidAudio

## Parakeet ASR models
The speech-recognition models FluidAudio downloads on first use of voice input
(derived from NVIDIA's Parakeet TDT, converted to Core ML by FluidInference).
- License: CC-BY-4.0
- Source: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml

## SwiftProtobuf
Protocol Buffers runtime used by the native iTerm2 client.
- Author: Apple Inc.
- License: Apache License 2.0
- Source: https://github.com/apple/swift-protobuf

## iTerm2 API schema
`proto/api.proto` is iTerm2's scripting-API schema, reconstructed by
`tools/extract_proto.py` from the descriptor in the `iterm2` Python package, and
`Sources/SnippAIKit/ITerm/Generated/api.pb.swift` is generated from it. Both describe
iTerm2's wire protocol so SnippAI can talk to a running iTerm2; they are iTerm2's work,
not covered by this repository's MIT license.
- Author: George Nachman and iTerm2 contributors
- License: GNU General Public License v2 or later
- Source: https://github.com/gnachman/iTerm2 (`proto/api.proto`)
