// OWNER: AI-03
//
// Compiles every shim source as ONE translation unit, the way AI-05's iOS forwarder
// (ios/Classes/vw_whisper_forwarder.cpp) does. A file-local helper that clashes with another file's
// (same name in the same namespace) breaks this build, not just the iOS one.
#include "../vw_whisper.cpp"
#include "../vw_log.cpp"
#include "../vw_cpu.cpp"
#include "../vw_wav.cpp"
#include "../vw_chunker.cpp"
#include "../vw_words.cpp"
#include "../vw_json.cpp"
#include "../vw_vad.cpp"
#include "../vw_registry.cpp"
#include "../vw_model.cpp"
#include "../vw_job.cpp"
