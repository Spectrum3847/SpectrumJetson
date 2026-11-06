#!/usr/bin/env python3
"""Set the PhotonVision fork's current pipeline on the SystemCore (settings DB; run with sudo, PhotonVision stopped).

  pv-config.py [--db PATH] key=value ...

Keys are the pipeline's JSON fields, e.g. napa=true napaMinTagPx=22 napaMaxHamming=1 cameraExposureRaw=2
cameraGain=128 cameraGamma=100 cameraBacklightCompensation=0 tagFpsMax=0. Values: true/false, ints, floats, strings.
Prints the fields it changed.
"""
import json
import sqlite3
import sys


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
    args = sys.argv[1:]
    db = '/opt/photonvision/photonvision_config/photon.sqlite'
    if args[:1] == ['--db']:
        db, args = args[1], args[2:]
    kv = dict(a.split('=', 1) for a in args)
    c = sqlite3.connect(db)
    for uid, contents in c.execute('select unique_name, contents from cameras').fetchall():
        d = json.loads(contents)
        p = d['pipelineSettings'][d.get('currentPipelineIndex', 0)]
        for k, v in kv.items():
            print(f'{uid[:8]} {k}: {p.get(k)!r} -> {val(v)!r}')
            p[k] = val(v)
        c.execute('update cameras set contents=? where unique_name=?', (json.dumps(d), uid))
    c.commit()


if __name__ == '__main__':
    main()
