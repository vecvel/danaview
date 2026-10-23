// AIS-44 Android half: native diarization probe (throwaway, not in any product build).
// Calls the sherpa-onnx 1.13.8 C API from the sherpa_onnx_android_* pub packages
// (libsherpa-onnx-c-api.so + libonnxruntime.so), one process per configuration,
// and prints the same JSON as bin/diarize.dart so tool/score.py scores it.
// Peak memory is the process VmHWM from /proc/self/status (whole process).
//
// diarize_probe --seg S --emb E [--threads 2] [--clusters N | --threshold T]
//               [--out out.json] a.wav b.wav ...
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "sherpa-onnx/c-api/c-api.h"

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

static long status_kb(const char *key) {
  FILE *f = fopen("/proc/self/status", "r");
  char line[256];
  long v = -1;
  size_t n = strlen(key);
  if (!f) return -1;
  while (fgets(line, sizeof line, f)) {
    if (strncmp(line, key, n) == 0) { v = atol(line + n + 1); break; }
  }
  fclose(f);
  return v;
}

static const char *base(const char *p) {
  const char *s = strrchr(p, '/');
  return s ? s + 1 : p;
}

int main(int argc, char **argv) {
  const char *seg = NULL, *emb = NULL, *out = NULL;
  int threads = 2, clusters = -1;
  float threshold = 0.5f;
  const char *wavs[64];
  int nw = 0;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--seg")) seg = argv[++i];
    else if (!strcmp(argv[i], "--emb")) emb = argv[++i];
    else if (!strcmp(argv[i], "--out")) out = argv[++i];
    else if (!strcmp(argv[i], "--threads")) threads = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--clusters")) clusters = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--threshold")) threshold = (float)atof(argv[++i]);
    else if (nw < 64) wavs[nw++] = argv[i];
  }
  if (!seg || !emb || nw == 0) {
    fprintf(stderr, "usage: diarize_probe --seg S --emb E [opts] a.wav ...\n");
    return 2;
  }
  long rss0 = status_kb("VmRSS:");

  SherpaOnnxOfflineSpeakerDiarizationConfig c;
  memset(&c, 0, sizeof c);
  c.segmentation.pyannote.model = seg;
  c.segmentation.num_threads = threads;
  c.segmentation.provider = "cpu";
  c.embedding.model = emb;
  c.embedding.num_threads = threads;
  c.embedding.provider = "cpu";
  c.clustering.num_clusters = clusters;
  c.clustering.threshold = threshold;
  c.min_duration_on = 0.2f;
  c.min_duration_off = 0.5f;

  double t0 = now();
  const SherpaOnnxOfflineSpeakerDiarization *sd =
      SherpaOnnxCreateOfflineSpeakerDiarization(&c);
  if (!sd) { fprintf(stderr, "create failed\n"); return 1; }
  double load_ms = (now() - t0) * 1000;
  long rss_loaded = status_kb("VmRSS:");
  int sr = SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(sd);

  FILE *o = out ? fopen(out, "w") : stdout;
  fprintf(o, "{\"seg\":\"%s\",\"emb\":\"%s\",\"threads\":%d,\"clusters\":%d,"
             "\"threshold\":%g,\"loadMs\":%.0f,\"results\":[",
          seg, emb, threads, clusters, threshold, load_ms);
  for (int w = 0; w < nw; w++) {
    const SherpaOnnxWave *wave = SherpaOnnxReadWave(wavs[w]);
    if (!wave || wave->sample_rate != sr) {
      fprintf(stderr, "%s: bad wave\n", wavs[w]);
      return 1;
    }
    double dur = (double)wave->num_samples / wave->sample_rate;
    double s0 = now();
    const SherpaOnnxOfflineSpeakerDiarizationResult *r =
        SherpaOnnxOfflineSpeakerDiarizationProcess(sd, wave->samples, wave->num_samples);
    double secs = now() - s0;
    int n = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(r);
    const SherpaOnnxOfflineSpeakerDiarizationSegment *s =
        SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(r);
    char clip[256];
    snprintf(clip, sizeof clip, "%s", base(wavs[w]));
    char *dot = strstr(clip, ".wav");
    if (dot) *dot = 0;
    fprintf(o, "%s{\"clip\":\"%s\",\"duration\":%.3f,\"wall\":%.4f,\"rtf\":%.5f,\"segments\":[",
            w ? "," : "", clip, dur, secs, secs / dur);
    for (int i = 0; i < n; i++)
      fprintf(o, "%s{\"speaker\":\"S%d\",\"start\":%.3f,\"end\":%.3f}", i ? "," : "",
              s[i].speaker, s[i].start, s[i].end);
    fprintf(o, "]}");
    fprintf(stderr, "%s: %d segs, %.2f s, RTF %.3f\n", clip, n, secs, secs / dur);
    SherpaOnnxOfflineSpeakerDiarizationDestroySegment(s);
    SherpaOnnxOfflineSpeakerDiarizationDestroyResult(r);
    SherpaOnnxFreeWave(wave);
  }
  SherpaOnnxDestroyOfflineSpeakerDiarization(sd);
  long hwm = status_kb("VmHWM:");
  fprintf(o, "],\"rssStartKb\":%ld,\"rssLoadedKb\":%ld,\"vmHwmKb\":%ld}\n", rss0, rss_loaded, hwm);
  if (out) fclose(o);
  fprintf(stderr, "load %.0f ms, RSS start %ld kB, loaded %ld kB, VmHWM %ld kB\n",
          load_ms, rss0, rss_loaded, hwm);
  return 0;
}
