#!/usr/bin/env python3
"""Generates the WPILib 2027 (SystemCore, alpha-6) source tree from the 2026 one.

The library is written once, against WPILib 2026 (src/main, src/test). WPILib 2027 renamed its
packages (edu.wpi.first.* to org.wpilib.*) but, for everything this library uses, kept the classes
and their methods; the few real differences live in src/compat2026 and src/compat2027. So the 2027
tree is the 2026 one with each WPILib import rewritten by the table below.

  tools/port2027.py OUT_DIR            writes OUT_DIR/main/java and OUT_DIR/test/java
  tools/port2027.py --check            only checks every import is in the table

It stops on an edu.wpi.first import the table doesn't know, and on edu.wpi.first used anywhere
except an import line (a fully qualified name in code would slip through unported). Add a class:
look it up in the 2027 jars (unzip -l ~/wpilib/2027/maven/org/wpilib/*/*/2027.*/*.jar) and add a
line. Each entry was checked against the alpha-6 jars on 2026-10-01.
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent

MAP = {
    "edu.wpi.first.apriltag.AprilTag": "org.wpilib.vision.apriltag.AprilTag",
    "edu.wpi.first.apriltag.AprilTagFieldLayout": "org.wpilib.vision.apriltag.AprilTagFieldLayout",
    "edu.wpi.first.apriltag.AprilTagFields": "org.wpilib.vision.apriltag.AprilTagFields",
    "edu.wpi.first.math.estimator.PoseEstimator": "org.wpilib.math.estimator.PoseEstimator",
    "edu.wpi.first.math.estimator.SwerveDrivePoseEstimator": "org.wpilib.math.estimator.SwerveDrivePoseEstimator",
    "edu.wpi.first.math.geometry.Pose2d": "org.wpilib.math.geometry.Pose2d",
    "edu.wpi.first.math.geometry.Pose3d": "org.wpilib.math.geometry.Pose3d",
    "edu.wpi.first.math.geometry.Quaternion": "org.wpilib.math.geometry.Quaternion",
    "edu.wpi.first.math.geometry.Rotation2d": "org.wpilib.math.geometry.Rotation2d",
    "edu.wpi.first.math.geometry.Rotation3d": "org.wpilib.math.geometry.Rotation3d",
    "edu.wpi.first.math.geometry.Transform2d": "org.wpilib.math.geometry.Transform2d",
    "edu.wpi.first.math.geometry.Transform3d": "org.wpilib.math.geometry.Transform3d",
    "edu.wpi.first.math.geometry.Translation2d": "org.wpilib.math.geometry.Translation2d",
    "edu.wpi.first.math.geometry.Translation3d": "org.wpilib.math.geometry.Translation3d",
    "edu.wpi.first.math.interpolation.TimeInterpolatableBuffer": "org.wpilib.math.interpolation.TimeInterpolatableBuffer",
    "edu.wpi.first.math.MathUtil": "org.wpilib.math.util.MathUtil",
    "edu.wpi.first.math.Matrix": "org.wpilib.math.linalg.Matrix",
    "edu.wpi.first.math.Nat": "org.wpilib.math.util.Nat",
    "edu.wpi.first.math.numbers.N1": "org.wpilib.math.numbers.N1",
    "edu.wpi.first.math.numbers.N3": "org.wpilib.math.numbers.N3",
    "edu.wpi.first.math.util.Units": "org.wpilib.math.util.Units",
    "edu.wpi.first.math.VecBuilder": "org.wpilib.math.linalg.VecBuilder",
    "edu.wpi.first.networktables.BooleanPublisher": "org.wpilib.networktables.BooleanPublisher",
    "edu.wpi.first.networktables.BooleanSubscriber": "org.wpilib.networktables.BooleanSubscriber",
    "edu.wpi.first.networktables.DoubleArrayPublisher": "org.wpilib.networktables.DoubleArrayPublisher",
    "edu.wpi.first.networktables.DoubleArraySubscriber": "org.wpilib.networktables.DoubleArraySubscriber",
    "edu.wpi.first.networktables.DoubleSubscriber": "org.wpilib.networktables.DoubleSubscriber",
    "edu.wpi.first.networktables.IntegerArraySubscriber": "org.wpilib.networktables.IntegerArraySubscriber",
    "edu.wpi.first.networktables.IntegerSubscriber": "org.wpilib.networktables.IntegerSubscriber",
    "edu.wpi.first.networktables.IntegerPublisher": "org.wpilib.networktables.IntegerPublisher",
    "edu.wpi.first.networktables.NetworkTable": "org.wpilib.networktables.NetworkTable",
    "edu.wpi.first.networktables.NetworkTableInstance": "org.wpilib.networktables.NetworkTableInstance",
    "edu.wpi.first.networktables.PubSubOption": "org.wpilib.networktables.PubSubOption",
    "edu.wpi.first.networktables.StringPublisher": "org.wpilib.networktables.StringPublisher",
    "edu.wpi.first.networktables.StringSubscriber": "org.wpilib.networktables.StringSubscriber",
    "edu.wpi.first.networktables.StructArrayPublisher": "org.wpilib.networktables.StructArrayPublisher",
    "edu.wpi.first.networktables.StructPublisher": "org.wpilib.networktables.StructPublisher",
    "edu.wpi.first.hal.HAL": "org.wpilib.hardware.hal.HAL",
    "edu.wpi.first.math.kinematics.SwerveDriveKinematics": "org.wpilib.math.kinematics.SwerveDriveKinematics",
    "edu.wpi.first.math.kinematics.SwerveModulePosition": "org.wpilib.math.kinematics.SwerveModulePosition",
    "edu.wpi.first.wpilibj.simulation.DriverStationSim": "org.wpilib.simulation.DriverStationSim",
    "edu.wpi.first.wpilibj.simulation.SimHooks": "org.wpilib.simulation.SimHooks",
    "edu.wpi.first.wpilibj.RobotBase": "org.wpilib.framework.RobotBase",
    "edu.wpi.first.wpilibj.RobotState": "org.wpilib.driverstation.RobotState",
    "edu.wpi.first.wpilibj.Timer": "org.wpilib.system.Timer",
}

EXAMPLE_TESTS = ["VisionTuningTest.java"]

IMPORT = re.compile(r"^import (static )?(edu\.wpi\.first\.[A-Za-z0-9_.]+?)(\.[a-z][A-Za-z0-9_]*|\.\*)?;\s*$")


def port(text: str, where: str) -> str:
    out = []
    for n, line in enumerate(text.splitlines(keepends=True), 1):
        if line.startswith("import ") and "edu.wpi.first." in line:
            m = IMPORT.match(line)
            if not m:
                raise SystemExit(f"{where}:{n}: can't parse import: {line.strip()}")
            static, cls, member = m.group(1) or "", m.group(2), m.group(3) or ""
            if cls not in MAP:
                raise SystemExit(f"{where}:{n}: no 2027 mapping for {cls} (add it to tools/port2027.py)")
            line = f"import {static}{MAP[cls]}{member};\n"
        elif "edu.wpi.first." in line:
            raise SystemExit(f"{where}:{n}: edu.wpi.first outside an import (use an import): {line.strip()}")
        out.append(line)
    return "".join(out)


def main():
    check = "--check" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not check and len(args) != 1:
        sys.exit(__doc__)
    count = 0
    for kind in ("main", "test", "simTest"):
        src = HERE / "src" / kind / "java"
        if not src.is_dir():
            continue
        for f in sorted(src.rglob("*.java")):
            ported = port(f.read_text(), str(f.relative_to(HERE)))
            count += 1
            if not check:
                dst = Path(args[0]) / kind / "java" / f.relative_to(src)
                dst.parent.mkdir(parents=True, exist_ok=True)
                if not dst.exists() or dst.read_text() != ported:
                    dst.write_text(ported)
    # The example tuning test runs in both builds' suites (it's what teams copy).
    for name in EXAMPLE_TESTS:
        f = HERE / "examples" / name
        ported = port(f.read_text(), str(f.relative_to(HERE)))
        count += 1
        if not check:
            dst = Path(args[0]) / "test" / "java" / "org" / "spectrum3847" / "vision" / "examples" / name
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists() or dst.read_text() != ported:
                dst.write_text(ported)
    # The other examples compile in the 2027 build too (wpilib2027's "examples" source set).
    # An example with a hand-written 2027 version (examples/wpilib2027/, for a vendor API that
    # changed, not just WPILib's package names) is taken as it is instead of ported.
    for f in sorted((HERE / "examples").glob("*.java")):
        if f.name in EXAMPLE_TESTS:
            continue
        own = HERE / "examples" / "wpilib2027" / f.name
        ported = own.read_text() if own.exists() else port(f.read_text(), str(f.relative_to(HERE)))
        count += 1
        if not check:
            dst = Path(args[0]) / "examples" / "java" / f.name
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists() or dst.read_text() != ported:
                dst.write_text(ported)
    print(f"port2027: {count} files {'checked' if check else 'written'}")


if __name__ == "__main__":
    main()
