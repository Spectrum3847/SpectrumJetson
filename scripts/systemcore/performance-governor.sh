#!/bin/bash
# OPT-IN: keep the SystemCore's CPUs on the `performance` cpufreq governor across reboots, with a small oneshot
# systemd unit (no boot config / cmdline change). The Pi 5 has one cpufreq policy for all 4 cores, so this is
# system-wide; robot code benefits too.
# Measured (tests/systemcore-latency/governor-ab.sh, sc-vision): CPU per frame 3.82 -> 3.15 ms (min tag 16),
# 2.95 -> 2.25 ms (min 32), p99 latency -0.03 ms, +2 C, no under-voltage messages on the bench supply.
# Don't enable it on a SystemCore whose supply logs under-voltage (dmesg | grep -i undervoltage) until that is fixed.
#   performance-governor.sh enable | disable | status      (run ON THE SYSTEMCORE)
set -euo pipefail
U=/etc/systemd/system/spectrum-performance-governor.service
P=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
case ${1:-status} in
  enable)
    sudo tee "$U" >/dev/null <<'EOF'
[Unit]
Description=Spectrum: CPU governor performance (SpectrumJetson scripts/systemcore/performance-governor.sh)
After=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for p in /sys/devices/system/cpu/cpufreq/policy*; do echo performance > $p/scaling_governor; done'
ExecStop=/bin/sh -c 'for p in /sys/devices/system/cpu/cpufreq/policy*; do echo ondemand > $p/scaling_governor; done'

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now spectrum-performance-governor
    ;;
  disable)
    sudo systemctl disable --now spectrum-performance-governor 2>/dev/null || true
    sudo rm -f "$U"
    sudo systemctl daemon-reload
    ;;
  status) ;;
  *) echo "usage: performance-governor.sh enable|disable|status" >&2; exit 2 ;;
esac
echo "governor: $(cat $P); unit: $(systemctl is-enabled spectrum-performance-governor 2>/dev/null || echo absent)"
