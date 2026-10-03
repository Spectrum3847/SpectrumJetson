#!/usr/bin/env python3
"""Camera delay from an LED on a GPIO pin. Run by run.sh, ON THE JETSON, PhotonVision stopped.

The delay is the time from the END of the exposure to the frame's timestamp:

    delay = frame timestamp - exposure end

PhotonVision (photonvision-13) publishes timestamp - exposure/2 - SPECTRUM_CAMERA_DELAY_US, and
mid-exposure is exposure end - exposure/2, so SPECTRUM_CAMERA_DELAY_US = delay puts the corrected
timestamp on mid-exposure. The frame timestamp is the V4L2 buffer time (CLOCK_MONOTONIC, with
uvcvideo hwtimestamps=1), the one PhotonVision starts from.

Each trial switches the LED on at a random phase and records CLOCK_MONOTONIC. The first frame
where the LED region brightens is partly lit. The sensor is global shutter, so
lit fraction = (exposure end - switch-on) / exposure, and
exposure end = switch-on + fraction * exposure. A trial whose switch-on fell between exposures
(first lit frame fully lit) says nothing and is dropped, so only about exposure / frame period
of the trials count.

    delay.py DEVICE GPIO_CHIP GPIO_LINE EXPOSURE_US [--trials 100]
    delay.py --self-test

The LED must not saturate the sensor, or the lit fraction stops being linear.
Needs python3-opencv (its V4L2 backend returns the buffer timestamp from CAP_PROP_POS_MSEC),
numpy and python3-gpiod (libgpiod 1.x or 2.x).
"""
import argparse
import random
import signal
import statistics
import sys
import time

CLOCK = time.CLOCK_MONOTONIC
MIN_FRAC, MAX_FRAC = 0.05, 0.95


def delays_us(trials):
    """trials: (switch_on_ns, frame_ts_ns, lit_fraction, exposure_us). One delay per usable trial."""
    return [(ts - t_on) / 1000 - frac * exp_us
            for t_on, ts, frac, exp_us in trials if MIN_FRAC <= frac <= MAX_FRAC]


def fit(trials):
    d = delays_us(trials)
    if len(d) < 2:
        return None
    q = statistics.quantiles(d, n=4)
    med = statistics.median(d)
    return {"n": len(d), "median_us": med, "iqr_us": q[2] - q[0],
            "mad_us": statistics.median(abs(x - med) for x in d)}


def self_test():
    rng = random.Random(1)
    period, exp_us, true_us = 8333.0, 2000.0, 3500.0
    trials = []
    for _ in range(600):
        t_on = rng.uniform(0, 1e6)
        end = (t_on // period + 1) * period  # the next exposure end after the switch-on
        frac = min(1.0, (end - t_on) / exp_us) + rng.gauss(0, 0.01)
        ts = end + true_us + rng.gauss(0, 30)
        trials.append((int(t_on * 1000), int(ts * 1000), frac, exp_us))
    r = fit(trials)
    print(f"self-test: n={r['n']} median {r['median_us']:.0f} us (true {true_us:.0f}), IQR {r['iqr_us']:.0f} us")
    assert 100 < r["n"] < 200, "about exposure / period of the trials should be usable"
    assert abs(r["median_us"] - true_us) < 20, "median off"
    assert r["iqr_us"] < 60, "spread too large"
    assert fit([(0, 5_000_000, 1.0, exp_us)] * 5) is None, "fully lit frames must be dropped"
    print("PASS")


class Led:
    def __init__(self, chip, line):
        import gpiod
        self.gpiod, self.line = gpiod, line
        if chip.isdigit():
            chip = "gpiochip" + chip
        path = chip if chip.startswith("/dev/") else "/dev/" + chip
        self.v2 = hasattr(gpiod, "request_lines")
        if self.v2:
            self.req = gpiod.request_lines(path, consumer="camera-delay", config={line: gpiod.LineSettings(
                direction=gpiod.line.Direction.OUTPUT, output_value=gpiod.line.Value.INACTIVE)})
        else:
            self.req = gpiod.Chip(path).get_line(line)
            self.req.request(consumer="camera-delay", type=gpiod.LINE_REQ_DIR_OUT, default_vals=[0])

    def set(self, on):
        if self.v2:
            value = self.gpiod.line.Value
            self.req.set_value(self.line, value.ACTIVE if on else value.INACTIVE)
        else:
            self.req.set_value(1 if on else 0)

    def switch(self, on):
        """Switches the LED; returns CLOCK_MONOTONIC ns around the call."""
        before = time.clock_gettime_ns(CLOCK)
        self.set(on)
        return (before + time.clock_gettime_ns(CLOCK)) // 2

    def close(self):
        self.set(False)
        self.req.release()


class Cam:
    def __init__(self, device):
        import cv2
        self.cv2 = cv2
        self.cap = cv2.VideoCapture(device, cv2.CAP_V4L2)
        if not self.cap.isOpened():
            sys.exit(f"cannot open {device} (is PhotonVision stopped?)")
        self.cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 800)

    def read(self):
        """(buffer timestamp ns, gray frame)"""
        ok, frame = self.cap.read()
        if not ok:
            sys.exit("camera read failed")
        return round(self.cap.get(self.cv2.CAP_PROP_POS_MSEC) * 1e6), frame[:, :, 0]

    def read_after(self, ts_ns):
        while True:
            ts, gray = self.read()
            if ts > ts_ns:
                return ts, gray


def find_roi(cam, led):
    import numpy as np

    def level(t_switch):
        cam.read_after(t_switch + 150_000_000)
        return np.median(np.stack([cam.read()[1] for _ in range(10)]), axis=0)

    off = level(led.switch(False))
    on = level(led.switch(True))
    led.switch(False)
    diff = cam.cv2.blur(on - off, (5, 5))
    if diff.max() < 20:
        sys.exit("no LED seen: point it at the camera, or check the pin")
    ys, xs = np.nonzero(diff > diff.max() / 2)
    roi = (slice(ys.min(), ys.max() + 1), slice(xs.min(), xs.max() + 1))
    if on[roi].max() >= 250:
        sys.exit("LED saturates the sensor: dim it (bigger resistor), move it back, or shorten the exposure")
    print(f"LED region x {xs.min()}..{xs.max()}, y {ys.min()}..{ys.max()}, off {off[roi].mean():.0f}, on {on[roi].mean():.0f}")
    return roi


def trial(cam, led, roi, exposure_us, period_ns):
    """One switch-on: (switch_on_ns, frame_ts_ns, lit_fraction, exposure_us), or None."""
    t_off = led.switch(False)
    cam.read_after(t_off + 30_000_000)  # frames exposed with the LED still on are out of the queue
    off = sum(cam.read()[1][roi].mean() for _ in range(2)) / 2
    time.sleep(random.random() * period_ns / 1e9)  # frames arrive periodically: a random phase
    t_on = led.switch(True)
    frames = [cam.read() for _ in range(8)]
    led.switch(False)
    levels = [gray[roi].mean() for _, gray in frames]
    on = statistics.median(levels[-4:])
    if on - off < 20:
        return None
    fracs = [(m - off) / (on - off) for m in levels]
    k = next((i for i, f in enumerate(fracs) if f > 0.03), None)
    if not k:
        return None  # never lit, or already lit in the first frame: not the switch-on
    return t_on, frames[k][0], fracs[k], exposure_us


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("device", nargs="?")
    ap.add_argument("chip", nargs="?")
    ap.add_argument("line", nargs="?", type=int)
    ap.add_argument("exposure_us", nargs="?", type=float)
    ap.add_argument("--trials", type=int, default=100, help="usable trials to collect")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.exposure_us is None:
        ap.error("usage: delay.py DEVICE GPIO_CHIP GPIO_LINE EXPOSURE_US")

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))  # so timeout's TERM still switches the LED off
    led = Led(args.chip, args.line)
    trials = []
    try:
        cam = Cam(args.device)
        ts0, _ = cam.read()
        if not 0 <= time.clock_gettime_ns(CLOCK) - ts0 < 2_000_000_000:
            sys.exit("frame timestamps are not CLOCK_MONOTONIC (uvcvideo timestamp type, or this OpenCV build)")
        stamps = [cam.read()[0] for _ in range(30)]
        period_ns = statistics.median(b - a for a, b in zip(stamps, stamps[1:]))
        print(f"frame period {period_ns / 1e6:.2f} ms, exposure {args.exposure_us / 1000:.2f} ms")
        roi = find_roi(cam, led)
        for _ in range(args.trials * 10):
            r = trial(cam, led, roi, args.exposure_us, period_ns)
            if r and MIN_FRAC <= r[2] <= MAX_FRAC:
                trials.append(r)
                if len(trials) % 10 == 0:
                    print(f"  {len(trials)}/{args.trials} usable", flush=True)
                if len(trials) >= args.trials:
                    break
    finally:
        led.close()
    r = fit(trials)
    if r is None or r["n"] < 10:
        sys.exit(f"only {len(trials)} usable trials: the LED is too dim or too bright, or the exposure is short for the frame rate")
    print(f"SPECTRUM_CAMERA_DELAY_US={r['median_us']:.0f}  (n={r['n']}, IQR {r['iqr_us']:.0f} us, MAD {r['mad_us']:.0f} us)")


if __name__ == "__main__":
    main()
