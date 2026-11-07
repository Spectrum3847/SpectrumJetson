# Exposure and gain sweep (SystemCore / Pi 5 bench, 2026-11-06)

Both cameras run natively under PhotonVision at 1280x800 MJPEG 120 fps, with NAPA min tag 22 and full-tag fit on. Copy the scripts to `~/bench/exposure` on the target. `sweep.sh SECS OUT "texp tgain sexp sgain" ...` holds `/tmp/camera.lock`. For each setting it runs `expo_probe.py`, a stdlib-only NT4 client. The probe reports, per tag, the detection rate, decision margin (from `tagQuality`), corner jitter and range sd, plus capture-to-receive latency. `grab.py` reads the image mean and saturation from the PV input stream. The script also measures PV CPU (% of one core). It sets only the controls that change, because the Swyft stores its controls in flash.

Tags: tags 3 and 10 are at 0.8 and 1.7 m. The Swyft also sees 11 (3.7 m, 40 px), 12 (5.4 m, 27 px), 13 (7.3 m, 20 px) and 14 (9.3 m).

## Chosen
| Camera | Setting | Gain | Real exposure (rough) |
|---|---|---|---|
| Thriftiest SJ-05 | 12 | 128 (max) | ~1.2-1.4 ms: photometric, anchored on the LED-measured 0.92 ms at setting 10. Settings 12 and 13 give the same image. Setting 2 gives the same image as 11 (~1.1 ms). |
| Swyft SJ-SW01 | 5 | 96 | ~0.5 ms: brightness is roughly linear in the setting at 0.1 ms per unit (gamma 100 check, +-15% scatter) |

- **Thriftiest.** Gain is already at its maximum, so exposure alone sets the margin. Detection falls off a cliff below ~1 ms: setting 8 gives 43%, setting 10 gives 76%, and 3/4/6 detect nothing. Setting 11 (= 2) is the strictly shortest at 100%, but its margin of 42 sits close to that cliff. Setting 12 adds about 0.2 ms and raises the margin by 27%. If blur matters more than headroom, use 11.
- **Swyft.** It was overexposed: at 10/128, 60-70% of pixels were saturated, which washed out the far tags. Shorter exposure with less gain helps. Setting 3 (0.3 ms) caps tag 13 at ~67% at any gain. 4/96 gives ~94%, 5/96 gives 97-99%, and 6/64 gives 99-100%. Above gain ~96 at a fixed exposure there is no further gain.

## Sweep (20 s each; rate % / margin; jitter px)
| Thriftiest exp/gain | id3 | id10 | jitter id10 | img mean |
|---|---|---|---|---|
| 2/128 | 100/39-42 | 100/42 | 0.10-0.15 | 69-83 |
| 3,4,6/128 | 0 | 0 | - | 61-64 |
| 8/128 | 44/26 | 43/29 | 0.18 | 65 |
| 10/128 | 77/33 | 76/35 | 0.17 | 71 |
| 11/128 | 100/39-43 | 100/42 | 0.09-0.16 | 70-77 |
| 12, 13/128 | 100/49-53 | 100/52-53 | 0.09-0.16 | 74-79 |
| 14/128 | 100/63 | 100/62 | 0.08 | 83 |
| 15/128 | 100/69-73 | 100/72 | 0.08-0.15 | 84-90 |
| 20/128 | 100/96 | 100/99 | 0.12 | 93 |
| 25/128 | 100/136 | 100/134 (id12 18%) | 0.07 | 117 |
| 15/96, 15/64, 2/96, 2/64 | 100/47; 60/26; 70/28; 0 | | | |

| Swyft exp/gain | id11 | id12 | id13 | sat % | img mean |
|---|---|---|---|---|---|
| 10/128 (old) | 99/83 | 1/49 | 0 | 60-71 | 224-235 |
| 13, 15/128 | 99/77; 3/56 | 0 | 0 | 66-68 | 227-229 |
| 7/128 | 100/100 | 61/62 | 4 | 45 | 210 |
| 5/128 | 100/111 | 100/76 | 54/63 | 35 | 204 |
| 4/128 | 100/106 | 100/80 | 91/46 | 22 | 195 |
| 3/128 | 100/92 | 100/69 | 67/38 | 7 | 172 |
| 2/128, 2/96 | 100/59; 100/47 | 99/41; 99/31 | 9; 3 | 8; 0 | 158; 115 |
| 3/112, 3/96, 3/64, 3/32 | 100 | 100 | 67, 50, 37, 14 | 0 | 167-76 |
| 4/112, 4/96, 4/80, 4/64 | 100/107-91 | 100/80-50 | 94, 94-95, 89, 82 | <1 | 178-106 |
| **5/96** | 100/106 | 100/79 | **97-99/48-50** | 0.3 | 165-175 |
| 5/80, 5/64 | 100/90; 100/74 | 100/66; 100/54 | 97; 95 | 0 | 150; 111 |
| 6/64, 6/32 | 100/91-99; 100/66 | 100/65; 100/47 | 99-100; 96 | 0 | 121-124; 88 |

## Before / after (30 s each; PhotonVision restarted with the new defaults)
| | Thriftiest 2/128 -> 12/128 | Swyft 10/128 -> 5/96 |
|---|---|---|
| far-tag rate | id10 100 -> 100 | id12 1 -> 100%, id13 0 -> 97% |
| margin | 42 -> 53 | id11 83 -> 105, id3 102 -> 116 |
| corner jitter | id10 0.099 -> 0.090 px | id10 0.25 -> 0.078 px |
| range sd | 1.2 -> 1.2 mm | id10 10.0 -> 1.4 mm, id11 16.3 -> 7.6 mm |
| saturation | 0.01 -> 0% | 71 -> 0.01% |
| latency p50/p95 | 9.27/9.76 -> 9.37/9.94 ms | 9.25/9.64 -> 9.52/10.34 ms |
| PV CPU (% of a core, both cameras) | 77 -> 115 (more tags decoded and solved) | |

No moving target was available on the bench, so motion blur was not measured. The LED test was not run: the cameras face the tag wall, not the ACT LED. Real exposures come from image brightness instead, and mains flicker makes those numbers noisy (+-15%).
