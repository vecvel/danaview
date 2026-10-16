// OWNER: QA-10
//
// fsync probe for V-D1 (ARCH §8.3, §24 "does RandomAccessFile.flush() fsync on iOS?").
//
// A tiny dylib injected into the app on the iOS Simulator (SIMCTL_CHILD_DYLD_INSERT_LIBRARIES,
// set by tool/qa10_host.py). It interposes fsync(2) through dyld's __interpose section, so every
// call made by the Dart VM (Flutter.framework) or the engine is counted and the path of the
// descriptor is remembered (fcntl F_GETPATH). fcntl itself is not interposed: an interposed
// variadic fcntl stopped `flutter test` from ever attaching on the simulator (2026-10-16), and
// Dart has no F_FULLFSYNC call to observe anyway (the counter stays 0 and documents that). The in-app test
// (support/qa10_fsync_probe.dart) reads the counters through dart:ffi and checks that
// `LocalStoreFs.writeBytesSynced` and a real project save end in an fsync of the file they wrote.
//
// Calls made from inside this image are not interposed (dyld rule), so the hooks call the real
// functions directly. Build (tool/qa10_host.py does it):
//
//   xcrun --sdk iphonesimulator clang -dynamiclib -arch arm64 -mios-simulator-version-min=15.0 \
//     -o fsync_probe.dylib fsync_probe.c && codesign -f -s - fsync_probe.dylib

#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/param.h>
#include <unistd.h>

#define DV_RING 128

static atomic_long g_fsync_calls;
static atomic_long g_fullfsync_calls; // never incremented: see the header
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static char g_ring[DV_RING][MAXPATHLEN + 8];
static long g_ring_next;

static void dv_note(int fd, const char *kind) {
  char path[MAXPATHLEN];
  path[0] = '\0';
  if (fcntl(fd, F_GETPATH, path) == -1) strcpy(path, "?");
  pthread_mutex_lock(&g_mu);
  char *slot = g_ring[g_ring_next % DV_RING];
  strlcpy(slot, kind, 8);
  strlcat(slot, " ", sizeof(g_ring[0]));
  strlcat(slot, path, sizeof(g_ring[0]));
  g_ring_next++;
  pthread_mutex_unlock(&g_mu);
}

static int dv_fsync(int fd) {
  int r = fsync(fd);
  atomic_fetch_add(&g_fsync_calls, 1);
  dv_note(fd, "fsync");
  return r;
}

typedef struct {
  const void *replacement;
  const void *replacee;
} dv_interpose_t;

__attribute__((used)) static const dv_interpose_t dv_interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)dv_fsync, (const void *)fsync},
};

/// Number of fsync(2) calls since the process started.
__attribute__((visibility("default"))) long dv_qa10_fsync_count(void) { return atomic_load(&g_fsync_calls); }

/// Number of fcntl(F_FULLFSYNC) calls since the process started.
__attribute__((visibility("default"))) long dv_qa10_fullfsync_count(void) { return atomic_load(&g_fullfsync_calls); }

/// Writes the newest (up to 128) "<kind> <path>" records, oldest first, separated by '\n', into
/// [out] (NUL-terminated, truncated to [cap]). Returns the number of records written.
__attribute__((visibility("default"))) int dv_qa10_fsync_paths(char *out, int cap) {
  if (cap <= 0) return 0;
  out[0] = '\0';
  pthread_mutex_lock(&g_mu);
  long first = g_ring_next > DV_RING ? g_ring_next - DV_RING : 0;
  int n = 0;
  for (long i = first; i < g_ring_next; i++) {
    if (n > 0) strlcat(out, "\n", (size_t)cap);
    strlcat(out, g_ring[i % DV_RING], (size_t)cap);
    n++;
  }
  pthread_mutex_unlock(&g_mu);
  return n;
}
