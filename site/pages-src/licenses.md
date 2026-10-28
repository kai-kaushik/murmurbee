---
title: Licences and credits
description: MurmurBee is MIT-licensed and built on open-source models and software. Credits and licences for everything it uses.
date: 2026-10-28
---

MurmurBee is free and open source under the [MIT licence](https://github.com/kai-kaushik/murmurbee/blob/main/LICENSE), and it stands on the shoulders of some brilliant open work, so here's credit where it's due. The full licence texts ship inside the app (`ThirdPartyNotices.txt` in the app's resources) and are [in the repo](https://github.com/kai-kaushik/murmurbee/blob/main/app/Resources/ThirdPartyNotices.txt).

## Models

| Model | By | Licence |
|---|---|---|
| Parakeet TDT 0.6B v3, post-trained as Parakeet Ultra, Core ML version | NVIDIA, post-training by Moondream, conversion by [FluidInference](https://huggingface.co/FluidInference/parakeet-ultra-coreml) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| MurmurBee's clean-up model, a fine-tune of Qwen3.5-0.8B | Base model by the [Qwen team](https://huggingface.co/Qwen/Qwen3.5-0.8B), Alibaba Cloud; fine-tuned (modified) by Kai Kaushik | Apache 2.0 |

The models are downloaded the first time you run MurmurBee and aren't bundled in the app itself.

## Software

| Project | Licence |
|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache 2.0 |
| [MLX Swift](https://github.com/ml-explore/mlx-swift) and [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm) | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | MIT |
| [swift-transformers](https://github.com/huggingface/swift-transformers), [swift-huggingface](https://github.com/huggingface/swift-huggingface), [swift-jinja](https://github.com/huggingface/swift-jinja) | Apache 2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto), [swift-asn1](https://github.com/apple/swift-asn1), [swift-collections](https://github.com/apple/swift-collections), [swift-numerics](https://github.com/apple/swift-numerics) | Apache 2.0 |
| [EventSource](https://github.com/mattt/EventSource) | MIT |
| [yyjson](https://github.com/ibireme/yyjson) | MIT |

Fonts on this website are [Sora](https://fonts.google.com/specimen/Sora) and [DM Sans](https://fonts.google.com/specimen/DM+Sans), both under the SIL Open Font License.
