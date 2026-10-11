// OWNER: AI-09
//
// Model store and resumable, verified downloader (ARCH §16.3, ai.md §5): SpeechModelStore with
// its file-backed FileSpeechModelStore, ModelDownload and the consent-gated, hash-verified
// downloader, the ports it needs (ModelStorePlatform, DownloadWakelock) and the on-disk records.

library;

export 'model_downloader.dart' show FailedModelDownload, ModelDownload, ModelDownloadTask, ModelDownloaderConfig, ModelStoreLayout;
export 'model_file_checks.dart' show ggmlMagicBytes, hasGgmlMagic, sha256OfFile;
export 'model_manifest.dart' show ManifestEntry, PartialSidecar, SpeechModelManifest;
export 'model_store_ports.dart';
export 'speech_model_store.dart';
