/* OWNER: AI-02
 *
 * danaview whisper shim, C ABI version 1 (ai.md §4.5, ARCH §16.1). Implemented by AI-03
 * (src/dv_*.cpp) on top of the vendored whisper.cpp v1.9.4 (AI-01).
 *
 * Rules: every entry point is extern "C", default visibility, wrapped in try/catch (C++ exceptions
 * map to DV_ERR_OOM / DV_ERR_INTERNAL) and thread-safe. Every struct starts with struct_size for
 * forward compatibility. All strings passed in are copied. Jobs run on native std::threads; Dart
 * polls status and segments every 250 ms with leaf calls; no Dart callbacks cross threads.
 * Transcript text, prompts and file paths are never logged.
 */
#ifndef DV_WHISPER_H
#define DV_WHISPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define DV_API __declspec(dllexport)
#else
#define DV_API __attribute__((visibility("default"))) __attribute__((used))
#endif

#define DV_ABI_VERSION 1

typedef enum {
  DV_OK = 0,
  DV_ERR_INVALID_ARG = 1,
  DV_ERR_MODEL_LOAD = 2,
  DV_ERR_WAV_FORMAT = 3,
  DV_ERR_IO = 4,
  DV_ERR_OOM = 5,
  DV_ERR_CANCELLED = 6,
  DV_ERR_INFERENCE = 7,
  DV_ERR_BUSY = 8,
  DV_ERR_VAD_MODEL = 9,
  DV_ERR_NO_SPEECH = 10,
  DV_ERR_INTERNAL = 99
} dv_status;

typedef enum { DV_MODEL_LOADING = 0, DV_MODEL_READY = 1, DV_MODEL_FAILED = 2 } dv_model_state;

typedef enum {
  DV_JOB_RUNNING = 1,
  DV_JOB_PAUSED = 2,
  DV_JOB_SUCCEEDED = 3,
  DV_JOB_FAILED = 4,
  DV_JOB_CANCELLED = 5
} dv_job_state;

typedef enum { DV_MODE_TRANSCRIBE = 0, DV_MODE_DETECT_LANGUAGE = 1 } dv_job_mode;

typedef enum { DV_PHASE_PREPARING = 0, DV_PHASE_VAD = 1, DV_PHASE_ENCODING = 2, DV_PHASE_DECODING = 3 } dv_phase;

typedef struct dv_model dv_model;
typedef struct dv_job dv_job;

typedef struct {
  int32_t struct_size;
  int32_t use_gpu;    /* request; the shim applies the iOS GPU policy and may downgrade */
  int32_t flash_attn; /* 1 (default) */
  int32_t dtw_preset; /* 0 = off (default); else whisper_alignment_heads_preset; forces flash_attn = 0 */
} dv_model_params;

typedef struct {
  int32_t struct_size;
  int32_t multilingual, n_vocab, model_type, ftype;
  int32_t gpu_used, gpu_fallback;
} dv_model_info;

typedef struct {
  int32_t struct_size;
  int32_t mode;               /* dv_job_mode */
  const char *wav_path;       /* 16 kHz, mono, PCM s16le, canonical RIFF/WAVE; validated */
  int64_t range_start_ms;     /* inclusive, relative to WAV start; resume point */
  int64_t range_end_ms;       /* exclusive; -1 = end of file */
  const char *language;       /* whisper code ("en", "ja", ...); "auto" only in DETECT mode */
  int32_t n_threads;          /* 1..8; may change later via dv_job_set_threads */
  int32_t chunk_target_ms;    /* 180000 */
  int32_t chunk_search_ms;    /* 15000: search +-this around the target for the quietest 400 ms */
  int32_t chunk_min_ms;       /* 10000: a shorter tail merges into the previous chunk */
  int32_t vad_enabled;
  const char *vad_model_path; /* ggml-silero-v6.2.0.bin */
  float vad_threshold;        /* 0.5 */
  int32_t vad_min_speech_ms;  /* 250 */
  int32_t vad_min_silence_ms; /* 300 */
  int32_t vad_speech_pad_ms;  /* 100 */
  float vad_samples_overlap_s; /* 0.1 */
  int32_t token_timestamps;   /* 1 */
  float no_speech_thold, entropy_thold, logprob_thold, temperature_inc; /* 0.6, 2.4, -1.0, 0.2 */
  int32_t beam_size;          /* <= 1: greedy */
  int32_t best_of;            /* 5 (temperature fallback only) */
  int32_t suppress_nst;       /* 1 unless the user wants sound descriptions */
  int32_t carry_prompt_words; /* 0..40: tail of the previous chunk used as initial_prompt */
  const char *initial_prompt; /* nullable; unused by the v1 UI */
  int32_t detect_max_speech_ms; /* DETECT: up to 30000 ms of speech after the first VAD speech start */
  int32_t detect_search_ms;     /* DETECT: search window for the first speech (600000) */
} dv_job_params;

typedef struct {
  int32_t struct_size;
  int32_t state;             /* dv_job_state */
  int32_t error;             /* dv_status (valid when FAILED/CANCELLED) */
  int32_t phase;             /* dv_phase */
  int32_t progress_permille; /* 0..1000 over [range_start, range_end) */
  int32_t chunk_index, chunk_count; /* 0-based current chunk; count known after planning */
  int32_t chunks_completed;  /* chunks whose segments are final */
  int32_t segments_ready;    /* segments available to take */
  int64_t processed_ms;      /* audio covered by completed work */
  int64_t compute_ms;        /* wall time spent in whisper calls (excludes pauses) */
  int32_t threads;           /* current n_threads */
  char language[8];          /* language used/detected */
  float language_p;
} dv_job_status;

/* library */
DV_API int32_t dv_abi_version(void);
DV_API const char *dv_engine_version(void);   /* whisper_version(), e.g. "1.9.4" */
DV_API const char *dv_system_info(void);      /* diagnostics only */
DV_API uint64_t dv_cpu_features(void);        /* Android: HWCAP-derived bitmask; iOS: 0 */
DV_API int32_t dv_perf_core_count(void);      /* iOS: hw.perflevel0.physicalcpu; Android: 0 */
DV_API void dv_set_log_level(int32_t level);  /* 0 off ... 4 debug; never logs text or paths */
DV_API int32_t dv_lang_max_id(void);
DV_API const char *dv_lang_code(int32_t id);  /* whisper_lang_str */
DV_API void dv_shutdown_all(void);            /* cancel+join all jobs, free all models (hot restart) */
DV_API void dv_free(void *p);

/* model */
DV_API dv_model *dv_model_load(const char *model_path, const dv_model_params *params); /* loads on a native thread */
DV_API int32_t dv_model_get_state(const dv_model *m); /* dv_model_state; renamed from ai.md's dv_model_state(), which collided with the enum typedef */
DV_API int32_t dv_model_error(const dv_model *m, char *buf, int32_t buf_len);
DV_API int32_t dv_model_info_get(const dv_model *m, dv_model_info *out);
DV_API void dv_model_release(dv_model *m); /* refcounted; freed after the last job using it */

/* job: at most one active job per model (DV_ERR_BUSY otherwise) */
DV_API dv_job *dv_job_start(dv_model *m, const dv_job_params *params, int32_t *out_status);
DV_API void dv_job_status_get(const dv_job *j, dv_job_status *out); /* leaf, O(1) */
DV_API char *dv_job_take_segments_json(dv_job *j, int32_t from_index, int32_t max_count); /* free with dv_free */
DV_API char *dv_job_language_probs_json(dv_job *j, int32_t top_n); /* DETECT result; free with dv_free */
DV_API void dv_job_cancel(dv_job *j);
DV_API void dv_job_pause(dv_job *j, int32_t abort_current_chunk); /* 0: at next chunk; 1: abort and redo on resume */
DV_API void dv_job_resume(dv_job *j);
DV_API void dv_job_set_threads(dv_job *j, int32_t n_threads); /* applied at the next chunk */
DV_API void dv_job_free(dv_job *j); /* cancels if running, joins the thread, frees */

#ifdef __cplusplus
}
#endif

#endif /* DV_WHISPER_H */
