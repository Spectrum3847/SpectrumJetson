# Camera calibrations

One file per camera and resolution, named by the camera's serial: `SJ-TC01-1280x800.json` is the
Thriftiest Cam with serial `SJ-TC01` (labelled on the camera) at 1280x800. A camera keeps its serial
on any USB port (`photonvision-86`), so its calibration does too.

Each file is PhotonVision's calibration (`CameraCalibrationCoefficients`), as stored in its settings
database: intrinsics, the 8 distortion coefficients (`LENSMODEL_OPENCV`), the board size, and every
snapshot's detected corners and reprojection errors (`observations`), which PhotonVision's
calibration view and any later analysis use. To load one: PhotonVision's Cameras page, select the
camera, import the calibration file.

| File | Camera (2026-10-30) | Snapshots | fx |
| --- | --- | --- | --- |
| `SJ-TC01-1280x800.json` | orin-left | 124 | 734.55 |
| `SJ-TC02-1280x800.json` | orin-right | 102 | 738.25 |
| `SJ-TC02-320x240.json` | orin-right | 103 | 233.34 |
| `SJ-TC01-1280x800-refit.json` | orin-left, improved (2026-10-31) | 124 | 738.50 |
| `SJ-TC02-1280x800-refit.json` | orin-right, improved (2026-10-31) | 102 | 738.88 |
| `SJ-TC02-320x240-refit.json` | orin-right, improved (2026-10-31) | 103 | 234.21 |
| `SWYFT-factory-1280x800.json` | any Swyft USB Camera: Swyft's published factory calibration | none | 799.49 |

The Swyft (`SJ-SW01`) has no calibration of its own yet. `SWYFT-factory-1280x800.json` is the factory
one Swyft publishes on its product page (photon_calibration_SWYFT_USB_Camera_OV9281_1280x800.json,
downloaded 2026-10-30): fx 799.5, 5 distortion coefficients, no snapshots. The fork's camera
profiles start each new camera with its model's calibration, marked generic until it's calibrated.

Exported 2026-10-30 from the Jetson's settings before it moved to JetPack 7. The calibration images
(109 MB) and the rest of that backup aren't in this public repository: calibration images belong
with the team's files, not in git. Re-export after a recalibration, so the repository keeps the one
in use.

## The `-refit` files

The deployed calibrations' lens models fold over just past the area the snapshots covered: the
right camera (TC02) has no valid ray for about 4% of its image, edges and all four corners
(`tests/calibration-analysis/RESULTS.md`). The `-refit` files re-solve the *same snapshots*
(`tests/calibration-analysis/refit.py`) with the same 8-coefficient OpenCV model, but keep every
detected corner, including the edge corners PhotonVision had thrown out (only corners worse than
6x the typical error would be dropped; none were). Each was checked to be fold-free across the
whole image plus a 16 px border. On the TXMAN1 field replays they cut the corner error:

| Camera | Field error median / p90, deployed | With `-refit` |
| --- | --- | --- |
| orin-left (TC01) | 1.04 / 6.32 px | 0.89 / 4.93 px |
| orin-right (TC02) | 1.51 / 10.96 px | 1.10 / 4.98 px |

They are a stop-gap until a proper recalibration that covers the edges and corners. In the
`-refit` files every snapshot lists one entry per detected corner in `locationInImageSpace`,
`reprojectionErrors`, `cornersUsed` and `cornerIds`, in the same order. In the originals they don't
line up. To use one: Cameras page, select the camera at that resolution, import the calibration
file. The original files stay here unchanged.
