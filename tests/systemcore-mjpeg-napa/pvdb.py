#!/usr/bin/env python3
"""PhotonVision settings DB helper (run as root with PhotonVision STOPPED):
  pvdb.py backup DB BACKUP      SQLite backup API copy + integrity_check of both
  pvdb.py activate DB [NAME..]  set "deactivated": false for the named cameras (nicknames; default all)
  pvdb.py restore BACKUP DB     SQLite backup API copy back + integrity_check
  pvdb.py mintag DB N           napaMinTagPx = N in every camera's NAPA pipelines
  pvdb.py show DB               nickname, deactivated, per camera
"""
import json
import sqlite3
import sys


def check(path):
    r = sqlite3.connect(path).execute("pragma integrity_check").fetchone()[0]
    print(f"integrity_check {path}: {r}")
    if r != "ok":
        sys.exit(1)


def copy(src, dst):
    s, d = sqlite3.connect(src), sqlite3.connect(dst)
    s.backup(d)
    d.close()
    s.close()


def show(path):
    for uniq, contents in sqlite3.connect(path).execute("select unique_name, contents from cameras"):
        c = json.loads(contents)
        print(f"  {c.get('nickname')}: deactivated {c.get('deactivated')} ({uniq})")


cmd = sys.argv[1]
if cmd == "backup":
    check(sys.argv[2])
    copy(sys.argv[2], sys.argv[3])
    check(sys.argv[3])
elif cmd == "restore":
    check(sys.argv[2])
    copy(sys.argv[2], sys.argv[3])
    check(sys.argv[3])
    show(sys.argv[3])
elif cmd == "activate":
    names = set(sys.argv[3:])
    db = sqlite3.connect(sys.argv[2])
    for uniq, contents in db.execute("select unique_name, contents from cameras").fetchall():
        c = json.loads(contents)
        if not names or c.get("nickname") in names:
            c["deactivated"] = False
            db.execute("update cameras set contents = ? where unique_name = ?", (json.dumps(c), uniq))
    db.commit()
    db.close()
    check(sys.argv[2])
    show(sys.argv[2])
elif cmd == "mintag":  # pvdb.py mintag DB N: napaMinTagPx = N in every NAPA AprilTag pipeline of every camera
    n = int(sys.argv[3])
    db = sqlite3.connect(sys.argv[2])
    for uniq, contents in db.execute("select unique_name, contents from cameras").fetchall():
        c = json.loads(contents)
        key = "pipelineSettings" if "pipelineSettings" in c else "pipelines"
        out = []
        for p in c.get(key, []):
            wrapped = isinstance(p, list) and len(p) == 2
            s = p[1] if wrapped else p
            as_str = isinstance(s, str)
            d = json.loads(s) if as_str else s
            if isinstance(d, dict) and "napaMinTagPx" in d:
                d["napaMinTagPx"] = n
                print(f"  {c.get('nickname')}: pipeline {d.get('pipelineIndex')} {d.get('pipelineNickname')} napaMinTagPx = {n}")
            s = json.dumps(d) if as_str else d
            out.append([p[0], s] if wrapped else s)
        c[key] = out
        db.execute("update cameras set contents = ? where unique_name = ?", (json.dumps(c), uniq))
    db.commit()
    db.close()
    check(sys.argv[2])
elif cmd == "show":
    show(sys.argv[2])
else:
    sys.exit(__doc__)
