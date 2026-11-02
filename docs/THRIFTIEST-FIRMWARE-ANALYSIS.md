# Thriftiest Cam firmware: static analysis and patch plan

Static analysis of Thrifty Bot's published **5.13** image (111,729 bytes, sha256 `79bfebdb…616c`),
2026-11-02. It's for Spectrum 3847's own cameras. Nothing was flashed and no camera was touched.
See [THRIFTIEST-CAM-FIRMWARE.md](THRIFTIEST-CAM-FIRMWARE.md) for flashing, rollback and the
existing usbrecov/bwreport patches.

## Summary

- **The 8 ms the frame takes to stream is the sensor readout, not buffering.** Full res uses HTS 728
  and VTS 910 at 120 fps, so 808 rows take ~7.4 ms. The bridge encodes in 8-row MCU strips: the
  restart interval is one MCU row (DRI = width/16 = 80), and each strip goes out as it's read.
  There's no frame buffer to remove. The only latency lever in firmware is the **sensor line time**.
- **640x400 is binned 2x2 on the sensor, but at 120 fps it reads out just as slowly**: the firmware
  doubles HTS to 0x5B0 to get 120 fps. The candidate patch `binned-fast-readout` swaps that around
  (half HTS, double VTS): the same 120 fps with **~3.7 ms readout**, about 3.7 ms less latency per
  frame at 640x400. It's 14 bytes of sensor tables; no code changes.
- **Grayscale JPEG: we didn't find the encoder's format register**, and a header-only edit would
  produce undecodable frames. It's also worth little. On a mono sensor every chroma block is
  "DC diff 0 + EOB" (~4 bits), about 8 KB of a 54 KB frame (~15%). Bytes are paced by readout, so
  the frame arrives no sooner either way. Not recommended; a live register hunt is below if wanted.
- **Quality is rate-controlled every frame** (register 0x2882), so a fixed quality patch would need
  a code change. Not proposed.

## Image map

| What | Where (file offset) | Notes |
|---|---|---|
| CPU | | **MCS-251 in source mode** (8051-compatible core with 16/32-bit registers; `7E`/`A5` encodings), not a plain 8051. The usbrecov "JNZ" sites are 251 code |
| Code address | code = `0x800000` + file offset | Flat, no banking. Reset `LJMP 0x78DF` clears RAM, sets `SPX`, then `EJMP 0x81A5D9` (main). Table pointers carry the same `00 80` prefix |
| Identity ("TONY") | 0x2000 | Name/serial slots (existing doc) |
| Sensor init tables | 0x1810 (114 regs), 0x19E4 (92), 0x1B54 (115) | Entries `00 RH RL VV` (OV9281 register, value). Directory of `{count16, 00 80, ptr16}` at 0x1E01/0x1E08/0x1E0F |
| Per-frame-rate HTS tables | directory 0x1D21 (3 modes x 8 rates, 7-byte entries), data 0x1E3C-0x1F17 | `380C`/`380D` pairs |
| UVC descriptors | 0x5200-0x5BE0 | Active config: MJPEG format at 0x59EE, frames 1280x800, 640x360, 1280x720, 800x600, 640x480, **640x400 (0x5A8F)**, 320x240, each 120 fps; YUY2 at 0x5AF7 (5-30 fps) |
| Bridge register tables | 0x6CB9, 0x6D71 (46 entries, regs 0x2660-0x27E6), 0x6E41/0x6EAD (0x27xx/0x37xx, two pipes) | Same `00 RH RL VV` format |
| **JPEG header template** | **0x6F25-0x71B4** (656 bytes; descriptor `02 90 00 80 6F 25` at 0x71B5) | SOI, APP0 "AVI1", DQT 0 and 1, the four standard DHT tables, **DRI 0x0028** at 0x7184 (rewritten at run time to 80 at 1280 wide), SOF0 at 0x7194 (160x120 placeholder, `03 01 21 00 02 11 01 03 11 01` = 3 components, Y 2x1, Cb/Cr 1x1 → 4:2:2), SOS 3 components |
| Quant tables (natural order) | 0x71BB (luma 64 + chroma 64) | Base table for rate control |
| Resolution table | 0x7270 | width/height pairs in the descriptor order |

Sensor modes (OV9281, PLL `0302=0x32`, `030D=0x50` in all three):

| Table | Output | Binning | HTS @120 fps | VTS | Readout | UVC sizes |
|---|---|---|---|---|---|---|
| 0x1810 | 1288x808 | none | 0x2D4/0x2D8 (724/728) | 0x38E (910) | ~7.4 ms | 1280x800, 1280x720, 800x600?, 640x360? |
| 0x19E4 | 648x408 | 2x2 (`3814=31 3815=22 3820=60 3821=01`) | **0x5B0 (1456)** | 0x1CA (458) | **~7.4 ms** (could be 3.7) | 640x400 |
| 0x1B54 | 656x488 crop | none | 0x488 (1160) | 0x23E (574) | ~5.6 ms | 640x480 |

Which UVC sizes map to which table is inferred from the dimensions; the ones marked ? aren't confirmed.
The 8 rate slots per mode are 120 (and two faster, unadvertised: binned slot 0 = 238 fps), 60, 30,
15, 10, 5 fps. Lower rates **lengthen HTS**, so at 60 fps or below a frame also streams more slowly.

Registers found in code (meaning inferred):

| Register | Use |
|---|---|
| 0x2882 bits 0-5 | JPEG quality index, adjusted every frame from size buckets (RAM 0x988-0x98D), clamped by RAM 0x98E/0x98F (function 0x818114). Bit 6 set on write |
| 0x2894/0x2895 → 0x2898/0x2899 | copied once per frame (0x80E2CE), probably the compressed size |
| 0x28CC bit 0, 0x2290 bit 0, 0x250E bits 1-2 | set together at 0x819B08 (stream start/stop path) |
| 0x27B0/0x27C0/0x276C (and 0x37xx) | two image pipes, configured from the tables above |
| 0x20D8 | maintenance-mode reset (existing doc) |

No public SPCA2089 register map exists (SunplusIT product pages only).

## Tools

- `firmware/thriftiest/patches/make-patched.py IN.bin OUT.bin PATCH...`: builds an image from
  **your copy** of the published 5.13. The image isn't in the repo. The tool checks the old bytes
  and prints the sha256. It reproduces the coach's usbrecov image exactly (`9a6eedb6…`).
- `firmware/thriftiest/tools/DumpListing.java`: Ghidra 12.2 headless listing. Import with
  `-processor 80251:BE:24:default -loader BinaryLoader -loader-baseAddr 0x800000`, then
  `-postScript DumpListing.java out.txt 1` (1 = source mode; it's required, binary mode gives garbage).
  Auto-analysis reaches ~10k instructions; table-driven/indirect code needs manual entry points.

## Candidate patches (ranked)

| # | Patch | Confidence | Risk | Benefit |
|---|---|---|---|---|
| 0 | **None: measure stock 640x400 first.** `v4l2-ctl` MJPEG 640x400 at 120 fps with `tests/latency-breakdown/usb-sweep.sh` (or `ktrace.py --frames`): first-to-last packet should be ~7.4 ms. If it's already ~3.7 ms, my reading of the slots is wrong and no patch is needed | | none | tells us |
| 1 | `binned-fast-readout` (14 bytes, 0x1AC7-0x1F13; usbrecov can be stacked) | medium: tables decoded, slot→rate mapping inferred | low/medium: sensor timing only. The bad case is a wrong frame rate or a bad image, not enumeration (descriptors and code are untouched) | 640x400 frame streams in ~3.7 ms instead of 7.4 |
| 2 | Grayscale JPEG | **not available**: encoder format register unknown | high if guessed | ~15% fewer bytes, no latency gain |
| 3 | Faster full-res readout (PLL `0302`/HTS below 724) | low | high: past the OV9281's 120 fps spec, and the bridge's DVP input limit is unknown | would cut the 7.4 ms |

Candidates built from the published 5.13 (not committed):

| Image | sha256 |
|---|---|
| 5.13 + binned-fast-readout | `34fe2ce34310758ef0c2c43fd6ed014c7a8e21bfbe3def5dfe9b0c4ad14131fe` |
| 5.13 + usbrecov + binned-fast-readout | `3a3cb04df3371cd291b4a9ed442e8c623d4eaca9b37e4703344543663d1d9c67` |

`thriftiest-fw.py check-image` accepts both. `variant` reports them as published/usbrecov, because
it doesn't read 0x1Axx/0x1Exx.

What to watch with patch 1:

- **Exposure is set in lines, and a line now lasts half as long.** If the firmware converts
  PhotonVision's exposure (100 us units) with a fixed line time, real exposure at 640x400 is half
  the requested value. Measure with a flicker/LED test or compare brightness, and double the
  setting if so. Full res and 640x480 are unchanged.
- Max exposure at 120 fps is still ~8 ms (VTS doubled, line time halved).
- If the firmware rewrites VTS at run time (long exposure), the frame rate will show it.
- The hidden 238/208 fps slots become ~119/104 fps (not advertised, unused).

### Bench test (spare camera, Allen present, PhotonVision stopped)

1. `scripts/host/thriftiest-flash.sh list`; flash the spare with the usbrecov + binned image
   (`flash PORT cand.bin`, which backs up the whole flash first).
2. `v4l2-ctl --list-formats-ext` should be unchanged. Stream 1280x800 at 120: same as before (~8 ms).
3. Stream 640x400 at 120: `usb-sweep.sh` at `urb_packets=4`. Expect frame period 8.33 ms and
   first→last packet ~3.7 ms. Check the JPEG header: SOF 640x400, DRI 40.
4. Exposure check as above; tag detection at 640x400 in PhotonVision.
5. Rollback: `thriftiest-flash.sh flash PORT 5.13` (or the backup, or usbrecov).

**Recovery:** the patch only touches sensor tables. USB descriptors, the XU and the maintenance-mode
entry (0x20D8) are untouched, so the camera keeps enumerating and can be reflashed over USB. If the
sensor wedges, it enumerates but streams black or nothing, and reflashing still works. The
**ROM maintenance mode** (1bcf:0b12) is in mask ROM, entered from firmware through the XU. A patch
that broke enumeration or the XU would leave no path we know of without hardware: Thrifty Bot
documents no forced-ROM pin, and the flash is SOP-8 (clip programmer). So never patch descriptors
or the XU/USB code on a robot camera.

## Grayscale: what it would take

- The hardware encoder emits interleaved Y Y Cb Cr MCUs. Changing the template's SOF/SOS to one
  component would only make the decoders misread the stream.
- **Zero-flash hunt:** the vendor XU reads and writes any bridge register live (`thriftiest-fw.py`
  `Cam.reg`/`wreg`, selectors 2/3). A power cycle undoes every write. Dump 0x2800-0x28FF and
  0x2700-0x27FF while streaming MJPEG, then YUY2, then MJPEG at another size. Bits that change
  with format are candidates. Then try them live, plus a 1-component SOF/SOS in RAM (the header
  is copied out of flash at stream start; find its XDATA copy by searching for `FF D8 FF E0` with
  `Cam.mem`). Only after a live success, a flash patch.
- Decoder side, if it ever works: libjpeg-turbo (`stream_decode.cc`, `TurboDecode`) handles a
  1-component JPEG with `JCS_GRAYSCALE` as-is. **`NvJpgDecoder.cc` rejects `num_components != 3`
  (line 152) and expects 4:2:2**, so NVJPG would fall back to libjpeg-turbo until it learned the
  grayscale case. PhotonVision/cscore decode MJPEG with libjpeg/OpenCV and accept gray JPEG.

## Other knobs seen

- Restart interval: one MCU row (computed). This is what makes our overlapped streaming decode
  possible; keep it.
- Quality: per-frame rate control on 0x2882 with base quant tables at 0x71BB. Lower quality (fewer
  bytes) doesn't speed anything up while readout paces the bytes.
- Frame rates: only 120 fps advertised for MJPEG. The binned mode can do ~238 fps (slot 0), but
  advertising it needs a descriptor edit (frame interval list at 0x5A8F+26) plus code that maps
  intervals to slots, which we haven't traced. The descriptor part is enumeration-critical, so
  higher risk.
