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
| `SWYFT-factory-1280x800.json` | any Swyft USB Camera: Swyft's published factory calibration | none | 799.49 |

The Swyft (`SJ-SW01`) has no calibration of its own yet. `SWYFT-factory-1280x800.json` is the factory
one Swyft publishes on its product page (photon_calibration_SWYFT_USB_Camera_OV9281_1280x800.json,
downloaded 2026-10-30): fx 799.5, 5 distortion coefficients, no snapshots. The fork's camera
profiles start each new camera with its model's calibration, marked generic until it's calibrated.

Exported 2026-10-30 from the Jetson's settings before it moved to JetPack 7. The calibration images
(109 MB) and the rest of that backup aren't in this public repository: calibration images belong
with the team's files, not in git. Re-export after a recalibration, so the repository keeps the one
in use.
