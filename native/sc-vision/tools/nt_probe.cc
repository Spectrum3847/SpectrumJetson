// nt_probe: subscribe to /photonvision/<camera>/rawBytes as PhotonLib does and print what arrives (count, type
// string, decoded first target, receive latency against the capture timestamp). Checks sc-vision's output.
//   nt_probe [HOST] [CAMERA] [SECS]
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <string>
#include <vector>

#include <wpi/nt/NetworkTableInstance.hpp>
#include <wpi/nt/RawTopic.hpp>
#include <wpi/nt/ntcore_cpp.hpp>

static int64_t mono_ns() {
  timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

int main(int argc, char **argv) {
  const char *host = argc > 1 ? argv[1] : "127.0.0.1";
  std::string cam = argc > 2 ? argv[2] : "thrifty";
  int secs = argc > 3 ? atoi(argv[3]) : 5;
  auto inst = wpi::nt::NetworkTableInstance::Create();
  inst.StartClient("nt_probe");
  inst.SetServer(host, 5810);
  wpi::nt::PubSubOptions o;
  o.sendAll = true;
  o.pollStorage = 200;
  auto sub = inst.GetRawTopic("/photonvision/" + cam + "/rawBytes").Subscribe("photonstruct:PhotonPipelineResult:fd353b11f3a818e9c5b457c7dc5a8f5c", {}, o);
  std::vector<double> lat;
  double csum[8] = {0}, csq[8] = {0};
  long ncorn = 0;
  double amb_sum = 0, altx_sum = 0;
  long n = 0, tagged = 0;
  int64_t end = mono_ns() + (int64_t)secs * 1000000000LL;
  std::string type;
  while (mono_ns() < end) {
    for (auto &v : sub.ReadQueue()) {
      int64_t now = mono_ns();
      n++;
      const auto &b = v.value;
      if (b.size() < 33) continue;
      int64_t seq, cap, pub;
      memcpy(&seq, b.data(), 8);
      memcpy(&cap, b.data() + 8, 8);
      memcpy(&pub, b.data() + 16, 8);
      int ntg = (int8_t)b[32];
      lat.push_back((now - cap) / 1e6);
      if (ntg > 0) {
        tagged++;
        // first target's detectedCorners: after 2 TargetCorner lists' headers; minAreaRect list at q + 108
        const uint8_t *q0 = b.data() + 33;
        double amb, altx;
        memcpy(&amb, q0 + 156, 8), memcpy(&altx, q0 + 100, 8);
        amb_sum += amb, altx_sum += altx;
        size_t off = 164;  // yaw..skew 32, ids+conf 12, two Transform3d 112, poseAmbiguity 8
        int nmin = (int8_t)q0[off];
        off += 1 + 16 * (size_t)nmin;
        int ndc = (int8_t)q0[off];
        if (ndc == 4 && 33 + off + 1 + 64 <= b.size()) {
          for (int k = 0; k < 8; k++) {
            double v;
            memcpy(&v, q0 + off + 1 + 8 * k, 8);
            csum[k] += v, csq[k] += v * v;
          }
          ncorn++;
        }
        if (tagged == 1) {
          double yaw, pitch, area, tx, ty, tz, qw, qx, qy, qz;
          int32_t id;
          const uint8_t *q = b.data() + 33;
          memcpy(&yaw, q, 8), memcpy(&pitch, q + 8, 8), memcpy(&area, q + 16, 8), memcpy(&id, q + 32, 4);
          memcpy(&tx, q + 44, 8), memcpy(&ty, q + 52, 8), memcpy(&tz, q + 60, 8);
          memcpy(&qw, q + 68, 8), memcpy(&qx, q + 76, 8), memcpy(&qy, q + 84, 8), memcpy(&qz, q + 92, 8);
          printf("first tagged result: seq %lld id %d yaw %.2f pitch %.2f area %.3f%% t (%.4f %.4f %.4f) q (%.4f %.4f "
                 "%.4f %.4f), %zu bytes\n",
                 (long long)seq, id, yaw, pitch, area, tx, ty, tz, qw, qx, qy, qz, b.size());
        }
      }
    }
    usleep(2000);
  }
  type = sub.GetTopic().GetTypeString();
  std::sort(lat.begin(), lat.end());
  auto P = [&](double q) { return lat.empty() ? 0.0 : lat[std::min(lat.size() - 1, (size_t)(lat.size() * q))]; };
  printf("rawBytes type '%s': %ld results (%ld with tags) in %d s; capture -> received here p50 %.3f p95 %.3f p99 %.3f ms\n",
         type.c_str(), n, tagged, secs, P(.5), P(.95), P(.99));
  if (tagged) printf("poseAmbiguity mean %.4f, altCameraToTarget x mean %.4f m\n", amb_sum / tagged, altx_sum / tagged);
  if (ncorn) {
    printf("detectedCorners mean (sd) over %ld results:", ncorn);
    for (int k = 0; k < 8; k++) {
      double m = csum[k] / ncorn;
      printf(" %.3f(%.3f)", m, sqrt(std::max(0.0, csq[k] / ncorn - m * m)));
    }
    printf("\n");
  }
  return 0;
}
