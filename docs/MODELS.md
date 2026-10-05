# On-device models and AI

MB Notes keeps intelligence on the device by default. Small specialized models handle specific jobs: snapping shapes, transcribing, labeling speakers, cleaning audio, tagging, and titling. Open-ended work, such as summaries and questions, goes through the AI provider the user chooses.

## Desert Ant Labs models

[Desert Ant Labs](https://desertant.com) publishes small task-specific models through one Swift package, [`desert-ant-core`](https://github.com/Desert-Ant-Labs/desert-ant-core). The weights live on [Hugging Face](https://huggingface.co/desert-ant-labs). Every model runs fully on device, mostly on the Neural Engine. No audio, text, or drawing leaves the device.

| Model | What it does | Size | How MB Notes uses it | Delivery |
| --- | --- | --- | --- | --- |
| **Shapes** | Classifies one hand-drawn stroke as a rectangle, ellipse, triangle, star, or line | 0.2 MB Core ML | Optional. The editor's own `StrokeBeautifier` (in NoteEngine, plain geometry) handles lines, arrows, elbow connectors, polygons, stars, and ellipses; Shapes is kept as an extra classifier. | Downloads quietly the first time it's needed |
| **Voz** | Speech to text with word timings; Parakeet TDT 0.6B v3, about 300× real time on an iPhone, 25 European languages | 467 MB | Re-transcribes a recording after you stop, for better accuracy and word-level timings | Download button in Settings |
| **Uhm** | Finds um, uh, and hmm from audio, frame by frame | 45 MB | Marks fillers so playback can skip them | Download button |
| **Clear** | Speech enhancement: removes noise and echo, normalizes loudness; DeepFilterNet 3 | 9 MB | Optional cleaned-up copy of a recording for playback | Downloads quietly |
| **Gist** | Multi-label topic tags (36 topics); English 15 MB, multilingual 74 MB | 15 MB | Adds topic tags to notes when they close, used by search | Downloads quietly |
| **Title** | Short title and description for a passage; Granite 350M, 6-bit, MLX | about 280 MB | Names recordings from their transcript | Download button; real devices only |
| Align | Sharpens word timestamps from Apple's SpeechTranscriber | 0.7 MB | Not used yet, because Voz already returns word timings. A good fit for refining live transcripts later. | — |
| Who (beta) | Audio and visual speaker labels | — | Closed beta. FluidAudio covers speaker labels for now. | — |

**License:** Desert Ant's SDK is *source-available*, not open source. It is free below 100,000 monthly active devices per model, with unlimited use per device. In return it requires:

- visible credit, which is in **Settings › About**;
- no use of its outputs to train competing models;
- its telemetry left on. The telemetry is an anonymous monthly-active-device count that never includes inputs or outputs, and MB Notes discloses it in About.

The rest of MB Notes stays MIT. If you fork the app to serve more than 100k devices, you'll need a Desert Ant commercial license or alternatives for these features.

## Speaker labels: FluidAudio

Desert Ant's speaker model is still in closed beta, so speaker labels use [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0). It runs the pyannote community-1 offline pipeline (segmentation, WeSpeaker embeddings, VBx clustering) on Core ML. After a recording stops, segments are split wherever the speaker changes and labeled Speaker 1, Speaker 2, and so on. You can rename them (for example, "Professor") and hide any speaker from the transcript, search, and AI.

## Live transcription: Apple SpeechAnalyzer

During recording, Apple's on-device `SpeechTranscriber` (iOS 26) produces a live transcript with timings. It's built into the OS and keeps working when Voz isn't installed. The first time a language is used, iOS downloads its speech model; recording starts right away and the transcript joins in once the model is ready (the recording bar says "Downloading the speech model…" meanwhile).

## How models ship

| Tier | Models | Why |
| --- | --- | --- |
| Built into iOS | Apple SpeechTranscriber, Vision handwriting recognition, Apple Intelligence | Zero cost, always available |
| Quiet download on first use | Shapes, Clear, Gist | A few MB, so asking would be noise |
| Explicit download in **Settings › On-device models** | Voz, Uhm, Title, speaker labels, local LLM | Tens to hundreds of MB, so the user decides |

Nothing is bundled in the app binary. That keeps the App Store download small, and Desert Ant's SDK caches weights from Hugging Face anyway. Each model can be switched off (kept on disk, not used) or deleted individually in Settings. Features that depend on a model show as unavailable while it is off.

Downloads report real phases: bytes received with a rate and time estimate, then **Optimizing for this device…** while Core ML specializes the model for the Neural Engine (tens of seconds, once), then **Ready**. Hugging Face downloads are checksummed and only count as complete once a marker file is written, so an interrupted download never looks finished.

## Shape snapping

Shape snapping is deterministic. Draw a shape and hold the pen still at the end for about a third of a second; the stroke is replaced by the fitted shape, which undo reverts. `StrokeBeautifier` resamples the stroke, finds corners with a ShortStraw-style straw test, and fits:

- lines, snapped to 45° steps when close;
- arrows, from a single stroke whose tail doubles back, or from a short caret drawn right after a line;
- elbow connectors and zigzags (straight runs between corners);
- triangles, rectangles (right angles enforced, squares made square), regular polygons, and stars;
- ellipses, snapped to circles when nearly round.

Handwriting is never touched because it is not held at the end. The algorithms are published ones (ShortStraw, PaleoSketch-style tests, moment-based ellipse fitting) written from scratch here under MIT.

## AI providers

AI is off until the user picks one of three providers in **Settings › AI**:

1. **Apple Intelligence.** Uses the FoundationModels framework on supported devices. It's free and private.
2. **On-device model.** Any small MLX model from Hugging Face, run with [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm). Presets include Qwen 3.5 0.8B, Qwen 3 0.6B, Gemma 3 1B, LFM 2.5 1.2B, and Qwen 3.5 2B, and any `mlx-community/…` id works. The model loads when you ask something and unloads after 45 seconds idle, so memory is only used while it works. MLX needs a real GPU, so this doesn't run in the simulator.
3. **Your API key.** Any OpenAI-compatible endpoint: a base URL, a key (stored in the keychain), and a model picked from the endpoint's `/models` list. Presets cover OpenAI, OpenRouter, Anthropic, Google Gemini, Groq, Mistral, DeepSeek, xAI, Together, and Ollama or LM Studio running on your own computer.

Note text sent to a provider combines typed text, recognized handwriting, text from imported PDFs, and transcripts, minus hidden speakers.

### Deferred: Sign in with ChatGPT

OpenAI offers a self-serve "Sign in with ChatGPT" flow for open-source apps that lets users spend their ChatGPT plan instead of an API key. It uses OAuth with PKCE, dynamic client registration via `client_id=dynamic_agent_client`, and the Responses API with `store: false` and `stream: true`. Its documentation only covers loopback redirects on desktops, though, and it needs extra administrative setup, so it's deliberately left out for now. The `AIProvider` protocol makes it a single new provider type when we add it.
