#!/usr/bin/env python3
"""Record with Rewind for a while through PhotonVision's HTTP API (POST /api/rewind), for tests/pv-perf/measure.sh's
VIEWER hook: sets fps (and a small quota / min free for the test), records SECS seconds, stops, prints the status.
  rewind_rec.py PORT FPS SECS [MIN_FREE_GB] [QUOTA_GB]
The settings it changes persist in Rewind's settings.json: back that file up and restore it around the run
(tests/pv-perf/rewind.sh does)."""
import json
import sys
import time
import urllib.request

port, fps, secs = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
min_free = float(sys.argv[4]) if len(sys.argv) > 4 else 0.3
quota = float(sys.argv[5]) if len(sys.argv) > 5 else 1.0
url = f'http://127.0.0.1:{port}/api/rewind'


def post(body):
    for _ in range(40):  # PhotonVision may still be starting
        try:
            req = urllib.request.Request(url, data=json.dumps(body).encode(), method='POST',
                                         headers={'Content-Type': 'application/json'})
            with urllib.request.urlopen(req, timeout=5) as r:
                return json.loads(r.read() or b'{}')
        except Exception as e:  # noqa: BLE001
            err = e
            time.sleep(0.5)
    raise SystemExit(f'POST {url} {body}: {err}')


post({'fps': fps, 'minFreeGB': min_free, 'quotaGB': quota})
post({'manual': True})
time.sleep(secs)
st = post({'manual': False})
keep = {k: st.get(k) for k in ('session', 'recording', 'framesDropped', 'freeGB', 'cameras') if k in st}
print('rewind:', json.dumps(keep)[:600])
