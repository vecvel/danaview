// OWNER: AI-03
//
// Compiles every shim source as ONE translation unit, the way AI-05's iOS forwarder
// (ios/Classes/dv_whisper_forwarder.cpp) does. A file-local helper that clashes with another file's
// (same name in the same namespace) breaks this build, not just the iOS one.
#include "../dv_whisper.cpp"
#include "../dv_log.cpp"
#include "../dv_cpu.cpp"
#include "../dv_wav.cpp"
#include "../dv_chunker.cpp"
#include "../dv_words.cpp"
#include "../dv_json.cpp"
#include "../dv_vad.cpp"
#include "../dv_registry.cpp"
#include "../dv_model.cpp"
#include "../dv_job.cpp"
