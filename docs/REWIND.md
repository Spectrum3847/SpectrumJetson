# Rewind: recording the Jetson's cameras

Our replacement for Limelight Rewind. When robot code asks, PhotonVision saves every camera's video
to the Jetson's SSD. Afterwards you copy it to a laptop and watch what each camera saw, lined up
with the AdvantageKit log. It's built into our PhotonVision build (`patches/photonvision-07-rewind.patch`).

## How it works, and why it doesn't slow vision down

- **The camera's own JPEGs, untouched.** The cameras already send compressed MJPEG. Rewind adds a
  second output on each camera that receives those JPEG bytes exactly as they arrive: nothing is
  decoded or re-encoded. The cost is one memory copy and one disk write per saved frame.
- **30 frames per second** per camera (the cameras run ~95). Every third frame is kept.
- **It can only skip frames, never delay them.** Each output gets the newest frame on its own. If
  the recorder or the SSD falls behind, it misses frames; the vision pipeline's own output is
  untouched. The recorder threads also run at a lower priority (nice 10).
- **Nothing runs between recordings.** The extra output is switched off when not recording.
- **No hardware video encoder on the Orin Nano**, so compressing to H.264 on the Jetson would cost
  CPU. That's why the Jetson saves raw MJPEG, and the laptop does any conversion.

Measured on the bench (2 cameras, 1280x800, `tests/rewind-ab/run.sh`):

| | Detector fps (each) | Detect time | PhotonVision CPU | Rewind CPU |
|---|---|---|---|---|
| Not recording | 94–100 | 1.9–2.4 ms | 313–336% | 0 |
| Recording | 97–99 | 2.0 ms | 325% | 2.8% of one core |

The differences between rows are run-to-run noise. Each frame is about 50–60 KB, so 4 cameras use
about 7 MB/s: **about 1 GB per match**.

## Robot code: when to record

All topics are under `/photonvision/rewind/` in NetworkTables.

| Topic | Type | Who sets it | Meaning |
|---|---|---|---|
| `record` | boolean | robot | Record while true. |
| `label` | string | robot | Optional name for the recording, e.g. `shooter-test-3`. Empty: the FMS match (`Q12`), else the robot's mode (`auto`, `teleop`, `test`, `disabled`, `estop`, or `no-robot`). Read when a recording starts. |
| `recording` | boolean | Jetson | Whether it's recording right now. |
| `session` | string | Jetson | The current recording's name. |
| `freeGB` | double | Jetson | Free space on the Jetson's SSD. |
| `framesDropped` | integer | Jetson | Frames it couldn't save (bad JPEGs, write errors, a camera not in MJPEG mode). |

If the robot disconnects while `record` is true (a brownout, a reboot, a bad cable), the Jetson
keeps recording, so you get the video of whatever happened:
- **An FMS match:** until the robot is back and sends `record` false, or 5 min after its last true
  (`photonvision-78`). That covers the rest of a match the robot dropped out of.
- **Anything else:** 60 s. Settings > Rewind > **Record through disconnects** gives every robot
  recording the match rule. Turn it on at events for practice matches; leave it off on the bench.

**A NetworkTables drop doesn't split a recording** (`photonvision-77`). After a reconnect, `record`
reads false on the Jetson until the robot's value arrives again. At TXMAN1 (2026-10-17) a flaky
robot switch dropped NetworkTables for ~2 s in Q30, Q32 and a playoff match, and each time the
Jetson took that false for "robot stopped": the match's video came out in two recordings. Now the
grace keeps going after the reconnect until the robot sends `record` again:
- **true:** the same recording carries on (the log says "the robot still wants recording; same
  session").
- **false:** it stops, as "robot stopped".
- **nothing before the grace runs out:** it stops, as "robot didn't send record after
  reconnecting".

Robot code that sets `record` every loop needs no change. `tests/rewind-sessions/reconnect.sh`
drops a fake robot's traffic mid-match and checks for one recording.

Example (Java, WPILib 2027). Keep it in the vision IO layer so AdvantageKit replay stays clean:

```java
var rewind = NetworkTableInstance.getDefault().getTable("photonvision").getSubTable("rewind");
BooleanPublisher record = rewind.getBooleanTopic("record").publish();
StringPublisher label = rewind.getStringTopic("label").publish();

// Real matches: record from enable until 10 s after disable, with the FMS attached. Recording
// only while enabled would split each match in two (the robot is disabled between auto and
// teleop, and recording stops as soon as record goes false). Name it by event and match.
double now = Timer.getTimestamp();
if (DriverStation.isEnabled()) lastEnabledSec = now; // field, starts at NEGATIVE_INFINITY
if (DriverStation.isFMSAttached()) {
    String type = switch (DriverStation.getMatchType()) {
        case Practice -> "P";
        case Qualification -> "Q";
        case Elimination -> "E";
        default -> "M";
    };
    label.set(String.format("%s-%s%d-r%d", DriverStation.getEventName(), type,
            DriverStation.getMatchNumber(), DriverStation.getReplayNumber()));
    record.set(now - lastEnabledSec < 10.0);
}

// A specific test: set the label first, then record.
label.set("shooter-test-3");
record.set(true);
// ... test ...
record.set(false);
```

Setting the label *before* `record` goes true matters: the name is read when the recording starts.

## On the bench, without robot code

Settings page → **Rewind (camera recording)** → **Record now (bench)**. The card shows the current
recording, the saved fps and size per camera, the disk space, and the recent recordings (each with
a delete button).

## Disk space

- Recordings live in `/opt/photonvision/rewind/sessions/`, one folder per recording. That's outside
  `photonvision_config`, so PhotonVision's settings export never includes video.
- **The oldest recordings are deleted** when the folder passes **100 GB** (about 100 matches), or
  when the SSD drops below 15 GB free. Recording stops if it drops below 7.5 GB.
- The limits are in `/opt/photonvision/rewind/settings.json` (`fps`, `quotaGB`, `minFreeGB`), or can
  be changed with `POST /api/rewind` (for example `{"quotaGB": 50}`).

## Copying recordings to a laptop

Over the USB-C cable, or Ethernet in the pit. A match is ~1 GB, too much for the radio.

**From the browser:** Settings → Rewind → the download button next to a recording. You get
`<recording>.zip` with one `<Camera>.avi` per camera, `<Camera>.frames.csv` and `session.json`,
the same files the script below makes. The Jetson builds the zip while it streams:
- nothing extra is stored on the SSD;
- the JPEGs are copied as they are, with no re-encoding;
- the copy runs below the vision threads' priority.

A download runs at up to ~125 MB/s over the USB cable (a match in about 10 s). While it runs,
detection slows by about 15% (93 → 78 fps on the bench), because the kernel's network work isn't
covered by the lower priority. It's back to normal as soon as the download ends. **Don't
download while the robot is enabled.**

**From a terminal**, to copy several at once or to make `.mp4`s:

```bash
scripts/host/rewind-pull.sh --list
```

```bash
scripts/host/rewind-pull.sh Q12
```

With no name it copies the newest recording; `--all` copies everything. Recordings land in
`~/rewind/<recording>/`, and the videos in `~/rewind/<recording>/export/`:

- `<Camera>.avi`: the recording as an MJPEG AVI, made in plain Python with no re-encoding. VLC and
  mpv play it.
- `<Camera>.frames.csv`: every frame's exact time (see below).
- `<Camera>.mp4`: only with `--mp4` and ffmpeg installed (`sudo apt install ffmpeg`). H.264,
  about 5–10x smaller, timed from the real frame times. Better for sharing and AdvantageScope.

On the robot network, set the address: `JETSON=10.85.15.15 scripts/host/rewind-pull.sh`.

**For robotlog.spectrum3847.org:** `scripts/host/jetson-pull.sh` copies every recording,
PhotonVision's logs and the system journal (one `journal/boot-<boot id>.json.gz` for every boot still in it, as JSON so each
line keeps its boot and monotonic time) into `~/jetson-pull/<date>/`. Upload that folder with
robotlog's `npm run import -- --team 8515 <folder>`. PhotonVision logs a `Clock mark:` line
(`photonvision-80`) every 60 s and whenever the robot connects, disconnects or the time-sync offset
moves: it pairs the kernel's monotonic clock, `jetson_us`, the wall clock and the robot's offset,
so every journal line can be placed on the robot's clock even before the Jetson's date is set.

## Lining video up with the AdvantageKit log

Every frame has two timestamps:

- `jetson_us`: the Jetson's clock, the same one PhotonVision stamps its results with, at the moment
  the frame arrived.
- `robot_us`: the **robot's clock**, from PhotonVision's time sync with the robot. That's the
  timebase of PhotonLib's result timestamps and of the AdvantageKit log. It's blank when no robot
  was connected (bench recordings).

Both are arrival times. A result's timestamp is earlier: the middle of the exposure, half the
exposure (plus `SPECTRUM_CAMERA_DELAY_US`, 0 unless set) before arrival. PhotonVision logs the
shift for each camera when it starts ("Frame timestamps moved 2.5 ms earlier, to mid-exposure"). To
find a result's frame, subtract that shift from the frame's time.

`frames.csv` has `video_s` (seconds into the video) next to `robot_s` (the robot's time), so a moment
in the log can be found in the video and back. In AdvantageScope, open the `.mp4` in the Video tab
and set its offset so a known event lines up; the CSV gives the exact offset.

## Files, for tools

```
sessions/0007_Q12_20261010-143502/
  0007_Q12_20261010-143502_session.json         name, why it recorded, match, label, fps,
                                                per-camera frame counts, start/end times, and
                                                why it ended
  TopLeft/0007_Q12_20261010-143502_TopLeft_0000.mjpeg   JPEG frames back to back (one file per 5 min)
  TopLeft/0007_Q12_20261010-143502_TopLeft_0000.csv     frame,offset,size,width,height,jetson_us,robot_us
  0007_Q12_20261010-143502_vision.wpilog        what PhotonVision sent the robot (below)
  TopRight/...
```

The number at the start of each name counts up forever, so name order is age order. Every file
names its recording and camera (`photonvision-75`), so it means the same thing out of its folder:
robotlog.spectrum3847.org stores files by name. Recordings from before then have `session.json`,
`0000.mjpeg` and `0000.csv`; the tools here read both.

**`<session>_vision.wpilog`** (`photonvision-79`) holds every result PhotonVision published while
recording, as the robot would have received it, even through a disconnect: per camera
`/<camera>/result` (PhotonVision's own message, the bytes PhotonLib reads) and
`/<camera>/multiTagCameraPose` (a `Pose3d`), plus `/Jetson/ntConnected`, `/Jetson/robotOffsetUs`,
`/Jetson/robotMode` and `/Jetson/match` when they change. Its timestamps are `jetson_us`, like the
frame tables; add `robotOffsetUs` for the robot's clock. AdvantageScope opens it.

The label is the robot's `label`, else the FMS match, else the robot's mode when the recording
started. A recording from the web page's Record now button uses the same fallback.

## Checking it still works

```bash
~/SpectrumJetson/tests/rewind-ab/run.sh 30 2
```

Run it on the Jetson, with the cameras running. It records for 30 s, pauses for 30 s, twice, and
prints fps, detect time, CPU and SSD writes for each phase. The export on the laptop also checks
every frame is a complete JPEG and warns if not.

## Things to know

- **Only MJPEG modes are recorded.** A camera in a YUYV mode is skipped (the card says so). Our
  cameras always run MJPEG.
- **Rewind never changes camera settings.** The video is exactly what the detector saw, including
  exposure.
- **A camera plugged in mid-recording** joins the current recording from its first frame.
- **Power cuts** (switching the robot off) lose at most ~2 s at the end of a recording: the files are
  forced to the SSD every 2 s. Tested by pulling the plug: 1.4 s lost, every saved frame complete.
- **Dates in recording names come from the robot.** The Jetson has no clock battery, so after a
  power cut its clock restarts at 1970. Once robot code publishes `/photonvision/clock/unixMs`
  (see [TECHNICAL.md](TECHNICAL.md)), the Jetson sets its clock from the robot's. Until then the
  date in a name can be wrong; the number at the start of each name is always in order.
- **WPILib bug found on the way:** WPILib's Java `RawFrame.getSize()` goes stale when cscore reuses
  its buffer, so every frame was cut to the first frame's size. The recorder gives cscore its own 4
  MB buffer and finds each frame's real length from the JPEG's end marker.
