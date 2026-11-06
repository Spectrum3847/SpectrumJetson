// Rewind video for the native camera backend (docs/SYSTEMCORE-NATIVE-BACKEND.md): the vision thread hands each
// frame's JPEG to a lock-free single-producer ring (a memcpy, never a wait: full ring = frame dropped and counted),
// and one low-priority (nice 19) writer thread appends them to the recording in ~1 MB sequential writes, forcing the
// file to disk every 2 s. On a write error (disk full, I/O error) recording stops and the frames are counted lost;
// the index lists only frames written whole.
// Files as docs/REWIND.md ("Files, for tools"): <prefix>_NNNN.mjpeg (JPEG frames back to back, a new file every
// 5 min) and <prefix>_NNNN.csv (frame,offset,size,width,height,jetson_us,robot_us), so the existing export tools
// read them.
#pragma once
#include <stddef.h>
#include <stdint.h>

struct RewindWriter;

struct rewind_stats {
  long queued, written, dropped_full, dropped_fps, lost;  // frames (lost: after a write error)
  long long bytes;                                  // written
  double max_fsync_ms, writer_cpu_ms;               // worst fdatasync, writer thread CPU so far
};

// prefix: path without the _NNNN suffix (its directory must exist). ring_bytes: the ring (0: 32 MB, the default per
// camera: ~5 s of a 120 fps camera at 50 KB a frame, through SD-card fsync stalls of ~2 s). record_fps: at most this many frames a second are kept (0: every frame), independent of processing.
RewindWriter *rewind_open(const char *prefix, size_t ring_bytes, double record_fps);
// From the vision thread (one producer per writer): copy the frame in (or drop it). t_us: the frame's capture time (jetson_us), robot_us: the
// robot's clock for it (0 if unknown). Returns 1 kept, 0 dropped.
int rewind_push(RewindWriter *w, const uint8_t *jpeg, size_t len, int width, int height, int64_t t_us,
                int64_t robot_us);
void rewind_get_stats(RewindWriter *w, rewind_stats *s);
// Drains the ring, syncs and closes the files.
void rewind_close(RewindWriter *w);
