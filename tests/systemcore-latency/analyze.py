#!/usr/bin/env python3
"""tests/latency-breakdown/analyze.py for the SystemCore: Limelight's uvcvideo runs the Thriftiest Cam at
alt setting 8 (1600-byte packets), so ktrace's packet size is 1600 here.
  analyze.py DIR NAME
"""
import os
import sys

os.environ.setdefault('KTRACE_PSIZE', '1600')
HERE = os.path.dirname(os.path.abspath(__file__))
for d in (HERE, os.path.join(HERE, '..', 'latency-breakdown')):
    sys.path.insert(0, d)
import analyze as lb  # noqa: E402  (tests/latency-breakdown/analyze.py; copied beside this file on the target)

if __name__ == '__main__':
    lb.main()
