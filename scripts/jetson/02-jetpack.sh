#!/usr/bin/env bash
# Install the JetPack SDK components (CUDA, cuDNN, TensorRT, ...) that a BSP-only
# flash leaves out, and set up the shell environment the vision stack build needs.
# Run ON THE JETSON. Needs internet (e.g. Wi-Fi: sudo nmcli --ask dev wifi connect <SSID>).
set -euo pipefail

sudo apt update
sudo apt install -y nvidia-jetpack

# Environment from GpuDetectorJNI's README. Rewritten each run, so an older block (Java 17) moves
# to Java 25.
touch ~/.bashrc
sed -i '/^# >>> SpectrumJetson env >>>$/,/^# <<< SpectrumJetson env <<<$/d' ~/.bashrc
cat >> ~/.bashrc <<'EOF'
# >>> SpectrumJetson env >>>
export PATH=$PATH:/usr/local/cuda/bin
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/cuda/lib64
export JAVA_HOME=/usr/lib/jvm/java-25-openjdk-arm64/
# <<< SpectrumJetson env <<<
EOF
echo "Wrote the CUDA/Java environment block in ~/.bashrc"

/usr/local/cuda/bin/nvcc --version
