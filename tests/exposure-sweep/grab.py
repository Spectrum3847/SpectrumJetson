# grab.py PORT N: mean luma, % pixels >=250, % <=5 over N frames of a PhotonVision MJPEG stream
import sys, urllib.request, numpy as np, cv2, json
port, N = int(sys.argv[1]), int(sys.argv[2])
r = urllib.request.urlopen(f"http://127.0.0.1:{port}/stream.mjpg", timeout=5); buf = b""; fr = []
while len(fr) < N:
    buf += r.read(65536)
    a = buf.find(b"\xff\xd8"); b = buf.find(b"\xff\xd9", a + 2)
    if a >= 0 and b > 0:
        img = cv2.imdecode(np.frombuffer(buf[a:b+2], np.uint8), cv2.IMREAD_GRAYSCALE); buf = buf[b+2:]
        if img is not None: fr.append(img)
x = np.stack(fr).astype(np.float32)
print(json.dumps({"port": port, "shape": fr[0].shape, "mean": float(x.mean()), "sat_pct": float((x >= 250).mean()*100), "black_pct": float((x <= 5).mean()*100), "p99": float(np.percentile(x, 99))}))
