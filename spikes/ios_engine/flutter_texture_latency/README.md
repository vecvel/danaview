# flutter_texture_latency (IOS-01 spike, V-N23)

Throwaway Flutter app (not shipped) that measures preview A/V latency through a real Flutter
`Texture` on iOS: AVPlayer + `AVPlayerItemVideoOutput` + `CADisplayLink` → `FlutterTexture`.
Run with `../tools/run_texture_latency.sh <simulator-udid> <label>`; results land in
`../results/<label>.texture_latency.jsonl` and are summarised in `docs/editor/spikes/IOS-01.md`.
