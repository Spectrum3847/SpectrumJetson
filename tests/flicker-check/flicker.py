# Frame-to-frame brightness of the newest Rewind recording, per camera (see run.sh).
import csv, glob, os
import cv2, numpy as np
sess = sorted(glob.glob("/opt/photonvision/rewind/sessions/*"))[-1]
print(os.path.basename(sess))
for cam in sorted(glob.glob(sess + "/*/")):
    means = []
    for idx in sorted(glob.glob(cam + "*.csv")):
        data = open(idx[:-4] + ".mjpeg", "rb").read()
        for r in csv.reader(l for l in open(idx) if not l.startswith("#")):
            o, n = int(r[1]), int(r[2])
            if o + n > len(data): break
            g = cv2.imdecode(np.frombuffer(data[o:o + n], np.uint8), cv2.IMREAD_GRAYSCALE)
            means.append(float(g.mean()))
    m = np.array(means)
    d = np.abs(np.diff(m))
    print(f"  {os.path.basename(cam[:-1]):9s} {len(m)} frames: mean brightness {m.mean():5.1f}/255, "
          f"frame-to-frame change avg {d.mean():4.2f} max {d.max():4.2f} ({100 * d.mean() / m.mean():.1f}% avg, "
          f"{100 * (m.max() - m.min()) / m.mean():.1f}% total range)")
