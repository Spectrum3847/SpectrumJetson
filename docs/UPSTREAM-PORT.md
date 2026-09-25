# Historical JetPack 6 port notes

These notes describe the tested 2026 PhotonVision port that used the former numbered
`photonvision-00` through `photonvision-34` patch series. The experimental alpha-7 branch replaces
that source replay with one reproducible migration patch.

The measured FPS, latency, memory, camera recovery, Rewind, and robot-network results below belong
to the JetPack 6 and AllWPILib `v2026.2.1` baseline. They do not validate
PhotonVision source `1f419c9de3a6a0787571648d18211537a83fdca9` or WPILib
`2027.0.0-alpha-7`.

## Historical source anchors

- Spectrum PhotonVision fork: `d8c9e8e1d3d4036f077a92f10f3a513ef4849765`
- BOS detector: `62e93b4e1ba81bb2cab5d6a0d34346b7051fe0d7`
- Legacy detector: `ef9fc1ec7e43116849e71fef1ab335ba630274a7`
- AllWPILib baseline: `v2026.2.1`

## Historical changes

- `photonvision-00` merged upstream PhotonVision `v2026.3.4` into the 4143 CUDA fork.
- `photonvision-01` through `photonvision-34` added the CUDA tab, camera defaults, Rewind, robot-clock
  synchronization, direct JPEG decode, exposure units, TensorRT detection, telemetry, mount
  estimates, calibration, excluded tags, settings snapshots, copying settings, tuning help, decode
  recovery, camera controls, stuck-camera recovery, field calibration with its 3D view and tuning
  locks, USB bandwidth reporting and allocation, quieter frame-error logging, and the focus score.
- `gpudetector-01` through `gpudetector-03` added CUDA error clearing, timing output, and safe handle
  reuse.
- `bos-01` and `bos-02` made CUDA errors recoverable and handled empty detector frames.

## Historical compatibility boundary

The tested 2026 fork kept the same PhotonLib message hashes, NetworkTables protocol, and
microsecond time-sync layout used by the robot's PhotonLib alpha-2 baseline. Alpha-7 changes raw
timestamps to nanoseconds and moves several vendordep types, so that compatibility argument cannot
be reused for the migration.

## Alpha-7 source port

The experimental migration applies
`patches/photonvision-2027-alpha7-migration.patch` to PhotonVision source
`1f419c9de3a6a0787571648d18211537a83fdca9`. The port keeps the valid behavior from the old features
while adopting alpha-7's package layout, JSON dependency, vendordeps, and raw-frame types.

See [CUDA13-MIGRATION.md](CUDA13-MIGRATION.md) for the exact pins, host checks, Jetson matrix, and
robot-network gate. No alpha-7 hardware result is recorded.
