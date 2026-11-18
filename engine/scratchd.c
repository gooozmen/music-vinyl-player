// scratchd — vinyl scratch engine for the gooozmen.music plugin.
//
// Audio comes from two raw f32/48k/stereo captures:
//   A  the monitor of your speakers — what you normally hear
//   B  the monitor of a silent "scratch bus" sink
// The ring buffer keeps the last RING_SECONDS from whichever source is live.
//
// While you hold the record the player keeps playing, re-routed into the bus
// (inaudible), so the buffer keeps filling with the track's *future* audio and
// "now" moves on at 1x — exactly like a real deck: hold the platter still and
// the music falls behind, push it and you can catch up to the live point.
// The playhead chases the platter (xwax/Mixxx style), so pitch slides and the
// sound stops dead when your hand does.
//
// On release the motor spins the platter back up to 1x, then we tell the UI
// how far behind live we are ("handoff <lag>"): it seeks the player back by
// that much, re-routes it to the speakers and sends "fade" so we drop out.
//
// Usage: scratchd <captureA_fd> <captureB_fd> <playback_fd>
// Commands (stdin, one per line):
//   grab <live>     live=1: player is playing and is being routed to the bus
//   move <seconds>  platter moved by this much (+ forward)
//   release         let go
//   break           the needle snapped: skid + crackle, then hand back
//   fade            UI has handed playback back to the player; drop out
//   quit
// Events (stdout):
//   ready                 have audio
//   pos <seconds>         playhead relative to where you grabbed (~25 Hz)
//   handoff <lag> <pos>   live session: playhead is <lag> s behind live, at
//                         grab + <pos> s — seek the player there, re-route
//   seek <seconds>        paused session: set player to grab pos + seconds
//   done                  engine is idle again

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SR 48000
#define CH 2
#define RING_SECONDS 30
#define RING (SR * RING_SECONDS)
#define BLOCK 128
#define TAU 0.010              // playhead chase time constant (s)
#define VEL_SMOOTH 0.35        // per-block velocity smoothing
#define MAX_RATE 12.0
#define MOTOR_TIME 0.25        // seconds for the motor to bring 0 -> 1x
#define TAIL_TIMEOUT 1.5       // drop out on our own if "fade" never comes

static float ring[RING * CH];
static atomic_llong written;        // total frames ever stored
static atomic_int source;           // 0 = A, 1 = B, -1 = frozen
static pthread_mutex_t ring_lock = PTHREAD_MUTEX_INITIALIZER;

struct cap { int fd; int id; };

static void *capture_thread(void *arg) {
  struct cap *c = arg;
  float buf[1024 * CH];
  size_t have = 0;
  for (;;) {
    ssize_t n = read(c->fd, (char *)buf + have, sizeof(buf) - have);
    if (n <= 0) { if (n < 0 && errno == EINTR) continue; exit(0); }
    have += (size_t)n;
    size_t frames = have / (sizeof(float) * CH);
    if (atomic_load(&source) == c->id) {
      pthread_mutex_lock(&ring_lock);
      long long w = atomic_load(&written);
      for (size_t i = 0; i < frames; i++) {
        long long idx = (w + (long long)i) % RING;
        ring[idx * CH] = buf[i * CH];
        ring[idx * CH + 1] = buf[i * CH + 1];
      }
      atomic_store(&written, w + (long long)frames);
      pthread_mutex_unlock(&ring_lock);
    }
    size_t used = frames * sizeof(float) * CH;
    memmove(buf, (char *)buf + used, have - used);
    have -= used;
  }
  return NULL;
}

// Cubic (Catmull-Rom) read at a fractional absolute frame; silence outside [lo, hi).
static void sample_at(double pos, long long lo, long long hi, float *l, float *r) {
  long long i = (long long)floor(pos);
  double f = pos - (double)i;
  float s[4][2];
  for (int k = 0; k < 4; k++) {
    long long j = i - 1 + k;
    if (j < lo || j >= hi) { s[k][0] = s[k][1] = 0; continue; }
    long long idx = j % RING;
    s[k][0] = ring[idx * CH];
    s[k][1] = ring[idx * CH + 1];
  }
  for (int c = 0; c < 2; c++) {
    double p0 = s[0][c], p1 = s[1][c], p2 = s[2][c], p3 = s[3][c];
    double v = p1 + 0.5 * f * (p2 - p0 + f * (2 * p0 - 5 * p1 + 4 * p2 - p3 + f * (3 * (p1 - p2) + p3 - p0)));
    if (c == 0) *l = (float)v; else *r = (float)v;
  }
}

// Transparent below 0.8, rounds off anything louder.
static inline float softclip(float x) {
  float a = fabsf(x);
  if (a <= 0.8f) return x;
  float y = 0.8f + 0.2f * tanhf((a - 0.8f) / 0.2f);
  return x < 0 ? -y : y;
}

static void emit(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void emit(const char *fmt, ...) {
  va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
  putchar('\n'); fflush(stdout);
}

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: scratchd <capA_fd> <capB_fd> <playback_fd>\n"); return 2; }
  static struct cap ca, cb;
  ca.fd = atoi(argv[1]); ca.id = 0;
  cb.fd = atoi(argv[2]); cb.id = 1;
  int out_fd = atoi(argv[3]);
  fcntl(out_fd, F_SETPIPE_SZ, 4096);   // small pipe = low latency
  fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
  atomic_store(&source, 0);

  pthread_t ta, tb;
  pthread_create(&ta, NULL, capture_thread, &ca);
  pthread_create(&tb, NULL, capture_thread, &cb);

  enum { IDLE, HELD, COAST, TAIL, BRK } mode = IDLE;
  int live = 0, readyed = 0;
  double p = 0, target = 0, vel = 0;   // frames, frames, rate (x realtime)
  long long grab_idx = 0, frozen_end = 0;
  double brk_t = 0, tail_t = 0, pos_t = 0;
  unsigned int rng = 0x9e3779b9u;
  float gain = 0;
  char line[256]; size_t llen = 0;
  float out[BLOCK * CH];
  const double dt = (double)BLOCK / SR;

  for (;;) {
    // --- commands ---
    char c;
    ssize_t got;
    while ((got = read(STDIN_FILENO, &c, 1)) == 1) {
      if (c != '\n') { if (llen < sizeof(line) - 1) line[llen++] = c; continue; }
      line[llen] = 0; llen = 0;
      if (!strncmp(line, "grab", 4)) {
        if (mode == IDLE) {
          live = atoi(line + 4) ? 1 : 0;
          // live: keep recording the player (now on the bus); paused: freeze.
          atomic_store(&source, live ? 1 : -1);
          long long w = atomic_load(&written);
          frozen_end = w;
          grab_idx = w;
          p = target = (double)w;
          vel = live ? 1.0 : 0.0;   // caught it while it was turning
        } else {
          target = p;               // caught it again mid-coast/tail
          if (live) atomic_store(&source, 1);
        }
        mode = HELD;
      } else if (!strncmp(line, "move ", 5) && mode == HELD) {
        target += atof(line + 5) * SR;
      } else if (!strncmp(line, "release", 7) && mode == HELD) {
        if (live) {
          mode = COAST;             // motor back on
        } else {
          emit("seek %.3f", (p - grab_idx) / SR);
          mode = IDLE; atomic_store(&source, 0); emit("done");
        }
      } else if (!strncmp(line, "break", 5) && (mode == HELD || mode == COAST || mode == TAIL)) {
        mode = BRK; brk_t = 0;
        if (fabs(vel) < 0.6) vel = vel < 0 ? -0.6 : 0.6;
      } else if (!strncmp(line, "fade", 4)) {
        if (mode != IDLE) { mode = IDLE; live = 0; atomic_store(&source, 0); emit("done"); }
      } else if (!strncmp(line, "quit", 4)) {
        return 0;
      }
    }

    if (got == 0) return 0;   // controller is gone: don't linger as an orphan

    long long w = atomic_load(&written);
    long long lo = w > RING ? w - RING + 1 : 0;
    // Newest audio we may play: live grows, otherwise it's frozen.
    long long hi = live ? w : (mode == IDLE ? w : frozen_end);

    if (!readyed && w > SR / 2) { readyed = 1; emit("ready"); }

    // You can't push past live: there's no audio there yet.
    if (target > (double)hi) target = (double)hi;
    if (target < (double)lo) target = (double)lo;

    // --- physics ---
    if (mode == HELD) {
      double want = (target - p) / SR / TAU;
      if (want > MAX_RATE) want = MAX_RATE;
      if (want < -MAX_RATE) want = -MAX_RATE;
      vel += (want - vel) * VEL_SMOOTH;
    } else if (mode == COAST) {
      vel += (1.0 - vel) * (dt / MOTOR_TIME * 4);
      if (fabs(vel - 1.0) < 0.01) {
        vel = 1.0;
        // Up to speed: hand back. Stop recording — the player is about to
        // jump back, and its new audio must not land after ours.
        atomic_store(&source, -1);
        frozen_end = hi = atomic_load(&written);
        live = 0;
        emit("handoff %.3f %.3f", (frozen_end - p) / SR, (p - grab_idx) / SR);
        mode = TAIL; tail_t = 0;
      }
    } else if (mode == TAIL) {
      tail_t += dt;
      if (tail_t > TAIL_TIMEOUT) { mode = IDLE; atomic_store(&source, 0); emit("done"); }
    } else if (mode == BRK) {
      vel += (0.0 - vel) * (dt / 0.07);
      brk_t += dt;
    }

    // --- render ---
    float want_gain = (mode == IDLE) ? 0.f : 1.f;
    double p0 = p, p1 = p + vel * BLOCK;
    pthread_mutex_lock(&ring_lock);
    for (int i = 0; i < BLOCK; i++) {
      gain += (want_gain - gain) * 0.01f;
      if (mode == IDLE && gain < 1e-4f) { out[i * 2] = out[i * 2 + 1] = 0; continue; }
      double pos = p0 + (p1 - p0) * i / BLOCK;
      float l, r;
      sample_at(pos, lo, hi, &l, &r);
      if (mode == BRK) {
        double t = brk_t + (double)i / SR;
        rng = rng * 1664525u + 1013904223u;
        float n = ((rng >> 9) / 8388608.0f) - 1.0f;
        float env = (float)exp(-t / 0.12);
        float click = ((rng & 0x3ff) < 6) ? n * 0.8f : 0.0f;
        float muffle = (float)fmax(0.0, 1.0 - t / 0.4);
        l = l * muffle + (n * 0.22f + click) * env;
        r = r * muffle + (n * 0.22f - click) * env;
      }
      out[i * 2] = softclip(l * gain);
      out[i * 2 + 1] = softclip(r * gain);
    }
    pthread_mutex_unlock(&ring_lock);
    if (mode != IDLE) p = p1;
    if (p < lo) { p = (double)lo; if (vel < 0) vel = 0; }
    if (mode != IDLE && p > hi) { p = (double)hi; if (mode == HELD && vel > 0) vel = 0; }

    // Needle snapped: after the skid, hand back without a tail.
    if (mode == BRK && brk_t >= 0.45) {
      if (live) {
        atomic_store(&source, -1);
        frozen_end = atomic_load(&written);
        live = 0;
        emit("handoff %.3f %.3f", (frozen_end - p) / SR, (p - grab_idx) / SR);
      } else {
        emit("seek %.3f", (p - grab_idx) / SR);
      }
      mode = IDLE; atomic_store(&source, 0); emit("done");
    }

    // --- timecode for the UI ---
    if (mode != IDLE) {
      pos_t += dt;
      if (pos_t >= 0.04) { pos_t = 0; emit("pos %.3f", (p - grab_idx) / SR); }
    }

    size_t off = 0, len = sizeof(out);
    while (off < len) {
      ssize_t n = write(out_fd, (char *)out + off, len - off);
      if (n < 0) { if (errno == EINTR) continue; return 0; }
      off += (size_t)n;
    }
  }
}
