#!/usr/bin/env python3
"""Pick which camera PhotonVision runs and configure its pipeline (settings DB; sudo, PhotonVision stopped).

  pv-camera-config.py list
  pv-camera-config.py only NAME_SUBSTRING NICKNAME [CALIB.json] [key=value ...]
  pv-camera-config.py add  NAME_SUBSTRING NICKNAME [CALIB.json] [key=value ...]
  pv-camera-config.py off  NAME_SUBSTRING

`only`: the camera whose matched name/path (uniquePath, path, name; or its exact nickname) contains NAME_SUBSTRING
(e.g. SJ-SW01, SJ-05, xhci-hcd.0-usb-0:1:1.0 for a ThriftyCam on its port) is activated with
NICKNAME, its current pipeline gets NAPA (min 32, hamming 1) plus the key=value fields, and CALIB.json (a
PhotonVision calibration for its resolution) if given; every other camera is deactivated (one camera at a time).
`add`: the same, but the other cameras are left as they are (any number of cameras at once: `only` the first,
then `add` each other one). `off`: deactivate the matched camera.
"""
import json
import sqlite3
import sys

DB = '/opt/photonvision/photonvision_config/photon.sqlite'


def val(s):
    if s in ('true', 'false'):
        return s == 'true'
    for t in (int, float):
        try:
            return t(s)
        except ValueError:
            pass
    return s


def main():
    c = sqlite3.connect(DB)
    rows = c.execute('select unique_name, contents from cameras').fetchall()
    if sys.argv[1] == 'list':
        for uid, contents in rows:
            d = json.loads(contents)
            info = d.get('matchedCameraInfo', {})
            print(uid[:8], d.get('nickname'), 'deactivated' if d.get('deactivated') else 'active',
                  info.get('uniquePath') or info.get('path'))
        return
    mode, sub = sys.argv[1], sys.argv[2]
    if mode not in ('only', 'add', 'off'):
        sys.exit(__doc__)
    nick = sys.argv[3] if mode != 'off' else None
    rest = sys.argv[4:]
    cal = None
    if rest and rest[0].endswith('.json'):
        cal = json.load(open(rest[0]))
        rest = rest[1:]
    kv = dict(a.split('=', 1) for a in rest)
    for uid, contents in rows:
        d = json.loads(contents)
        # the camera's own name and path only: otherPaths can hold another camera's old port (the Swyft's saved
        # otherPaths had the ThriftyCam's platform-xhci-hcd.0-usb-0:1:1.0 from an earlier plug)
        mi = d.get('matchedCameraInfo', {})
        mine = any(sub in str(mi.get(k) or '') for k in ('uniquePath', 'path', 'name')) or sub == d.get('nickname')
        if mode == 'off':
            if not mine:
                continue
            d['deactivated'] = True
            mine = False
        elif mode == 'only' or mine:
            d['deactivated'] = not mine
        else:
            continue  # add: leave the others as they are
        if mine:
            d['nickname'] = nick
            if cal:
                d['calibrations'] = [cal]
            p = d['pipelineSettings'][d.get('currentPipelineIndex', 0)]
            p.update(napa=True, napaMinTagPx=22, napaMaxHamming=1, napaFarSearch=False, solvePNPEnabled=True,
                     doMultiTarget=False, tagFpsMax=0)
            for k, v in kv.items():
                p[k] = val(v)
        c.execute('update cameras set contents=? where unique_name=?', (json.dumps(d), uid))
        print(uid[:8], 'ACTIVE as ' + nick if mine else 'deactivated')
    c.commit()


if __name__ == '__main__':
    main()
