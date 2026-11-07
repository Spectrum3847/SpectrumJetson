// sc-vision: a user-space UVC isochronous reader (Linux usbfs), for one MJPEG camera.
//
// Why: the kernel's uvcvideo (LimelightOS's included) completes 32-packet URBs, so a frame's bytes reach user
// space in ~4 ms chunks (2-3 per frame) and a streaming decoder can't overlap much with the transfer. Here we
// detach uvcvideo from the camera's interfaces (the camera itself is untouched: no firmware, no reset), run the
// UVC probe/commit ourselves and keep many short URBs in flight (default 4 packets = 0.5 ms each), so the bytes
// arrive every 0.5 ms, straight into mmap'd usbfs buffers. uvc_close() gives the interfaces back to uvcvideo.
// Camera controls (exposure, gain, ...) are set through V4L2 before detaching (they are camera state, kept).
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct uvc_usb uvc_usb;

typedef struct {
  const uint8_t *data;  // payload (after the UVC header)
  int len;
  uint8_t flags;        // UVC header bmHeaderInfo: bit0 FID, bit1 EOF, bit2 PTS, bit3 SCR, bit6 ERR
  int pkt_from_end;     // packets in this URB after this one (its time ~ reap time - pkt_from_end * 125 us)
  uint32_t pts;         // camera PTS (if flags & 4)
  uint32_t scr_stc;     // SCR source clock (if flags & 8)
  uint16_t scr_sof;
} uvc_chunk;

typedef struct {
  int vid, pid;          // 0: the first UVC MJPEG device (default 0x1bcf:0x28c5, the Thriftiest Cam)
  int width, height, fps;
  int alt;               // streaming alt setting; -1: smallest with >= min(request, 1600 B); -2: the camera's request
  int pkts_per_urb;      // default 4 (0.5 ms)
  int nurbs;             // URBs in flight, default 32
  int verbose;
  int force;             // detach uvcvideo even when a process has the camera's /dev/video node open
  int frame_index;       // >0: this bFrameIndex instead of the one matching width x height (tests: unlisted modes)
  int yuyv;              // 1: the uncompressed (YUY2) format instead of MJPEG (tests only; sc-vision decodes MJPEG)
} uvc_config;
// What the camera committed: frame interval (100 ns), max payload, alt setting and its bytes per interval.
typedef struct {
  uint32_t interval, maxpay;
  int alt, psize, speed, frame_index, format_index;
} uvc_info;
void uvc_get_info(const uvc_usb *u, uvc_info *out);

// Pick one of several identical cameras: by USB serial (e.g. "SJ-05", sysfs serial / iSerial) and/or USB port (the
// sysfs device name, e.g. "3-1"). NULL or "" = any. Applies to uvc_open() and uvc_v4l2_set().
void uvc_select(const char *serial, const char *port);
// Opens and starts streaming. NULL on failure (message on stderr).
uvc_usb *uvc_open(const uvc_config *cfg);
// Waits for the next URB (blocking). Fills up to max chunks (one per non-empty packet), sets *t_ns to the
// CLOCK_MONOTONIC time it was reaped. Returns the number of chunks (0: no payload in that URB), or -1.
int uvc_reap(uvc_usb *u, uvc_chunk *out, int max, int64_t *t_ns);
// Packet interval of the bus in ns (125000 at high speed).
int uvc_packet_ns(const uvc_usb *u);
// Stops streaming and gives the interfaces back to uvcvideo.
void uvc_close(uvc_usb *u);
// Set a V4L2 control on the camera's /dev/video node (before uvc_open). 0 or -1.
int uvc_v4l2_set(int vid, int pid, uint32_t id, int value);

#ifdef __cplusplus
}
#endif
