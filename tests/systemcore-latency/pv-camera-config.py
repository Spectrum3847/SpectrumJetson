#!/usr/bin/env python3
"""Pick which camera PhotonVision runs and configure its pipeline (settings DB; sudo, PhotonVision stopped).

  pv-camera-config.py list
  pv-camera-config.py only NAME_SUBSTRING NICKNAME [CALIB.json] [key=value ...]

`only`: the camera whose matched name/path contains NAME_SUBSTRING (e.g. SJ-SW01, SJ-05) is activated with
NICKNAME, its current pipeline gets NAPA (min 32, hamming 1) plus the key=value fields, and CALIB.json (a
PhotonVision calibration for its resolution) if given; every other camera is deactivated (one camera at a time).
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
    sub, nick = sys.argv[2], sys.argv[3]
    rest = sys.argv[4:]
    cal = None
    if rest and rest[0].endswith('.json'):
        cal = json.load(open(rest[0]))
        rest = rest[1:]
    kv = dict(a.split('=', 1) for a in rest)
    for uid, contents in rows:
        d = json.loads(contents)
        info = json.dumps(d.get('matchedCameraInfo', {}))
        mine = sub in info
        d['deactivated'] = not mine
        if mine:
            d['nickname'] = nick
            if cal:
                d['calibrations'] = [cal]
            p = d['pipelineSettings'][d.get('currentPipelineIndex', 0)]
            p.update(napa=True, napaMinTagPx=32, napaMaxHamming=1, napaFarSearch=False, solvePNPEnabled=True,
                     doMultiTarget=False, tagFpsMax=0)
            for k, v in kv.items():
                p[k] = val(v)
        c.execute('update cameras set contents=? where unique_name=?', (json.dumps(d), uid))
        print(uid[:8], 'ACTIVE as ' + nick if mine else 'deactivated')
    c.commit()


if __name__ == '__main__':
    main()
