// sc-vision: publish each frame's tags as PhotonVision does, so PhotonLib on the robot reads sc-vision as a
// PhotonVision camera: /photonvision/<camera>/rawBytes ("photonstruct:PhotonPipelineResult:<uuid>", the
// Spectrum fork's serde, little-endian Packet encoding) + heartbeat, latencyMillis, hasTarget, target*.
//
// Conventions copied from the fork (AprilTagPipeline + TrackedTarget + NTDataPublisher):
//  - corners in AprilTag order: NAPA's OpenCV order permuted {1, 0, 3, 2} (detector/napa/napa_far.h);
//  - pose: IPPE on those corners with AprilTag's tag coordinates (-1,1),(1,1),(1,-1),(-1,-1) -> R_h; AprilTag's
//    frame R_at = R_h diag(1,-1,-1); PhotonVision's convertApriltagtoOpenCV: R = R_at Ry(180) = R_h Rz(180);
//    then EDN -> NWU (convertOpenCVtoPhotonTransform);
//  - yaw/pitch from the undistorted tag centre (the homography's image of the centre), degrees;
//  - capture timestamp: estimated mid-exposure on CLOCK_MONOTONIC (= wpi::nt::Now() on the SystemCore, where
//    robot code runs on the same clock, so the time-sync offset is 0), in ns as the fork publishes.
// Differences: poseAmbiguity is the IPPE reprojection-error ratio (best/alt) where PhotonVision uses the
// orthogonal-iteration object-space errors; minAreaRectCorners are the detected corners (not cv::minAreaRect);
// skew 0; no multi-tag result (single tag in view on this bench).
#include "nt_pub.h"

#include <math.h>
#include <string.h>
#include <time.h>

#include <string>
#include <vector>

#include <wpi/nt/BooleanTopic.hpp>
#include <wpi/nt/DoubleTopic.hpp>
#include <wpi/nt/IntegerTopic.hpp>
#include <wpi/nt/NetworkTable.hpp>
#include <wpi/nt/NetworkTableInstance.hpp>
#include <wpi/nt/RawTopic.hpp>
#include <wpi/nt/StringTopic.hpp>
#include <wpi/nt/ntcore_cpp.hpp>
#include <wpi/util/json.hpp>

namespace {
const char *kUuid = "fd353b11f3a818e9c5b457c7dc5a8f5c";
struct Schema {
  const char *name, *uuid, *schema;
};
const Schema kSchemas[] = {
    {"PhotonPipelineResult", "fd353b11f3a818e9c5b457c7dc5a8f5c",
     "PhotonPipelineMetadata:5231116d7f87ff560e6aa5263d0eee02 metadata;PhotonTrackedTarget:"
     "cc6dbb5c5c1e0fa808108019b20863f1 targets[?];optional MultiTargetPNPResult:541096947e9f3ca2d3f425ff7b04aa7b "
     "multitagResult;"},
    {"PhotonPipelineMetadata", "5231116d7f87ff560e6aa5263d0eee02",
     "int64 sequenceID;int64 captureTimestampNanos;int64 publishTimestampNanos;int64 timeSinceLastPong;"},
    {"PhotonTrackedTarget", "cc6dbb5c5c1e0fa808108019b20863f1",
     "float64 yaw;float64 pitch;float64 area;float64 skew;int32 fiducialId;int32 objDetectId;float32 "
     "objDetectConf;Transform3d bestCameraToTarget;Transform3d altCameraToTarget;float64 poseAmbiguity;TargetCorner:"
     "16f6ac0dedc8eaccb951f4895d9e18b6 minAreaRectCorners[?];TargetCorner:16f6ac0dedc8eaccb951f4895d9e18b6 "
     "detectedCorners[?];"},
    {"TargetCorner", "16f6ac0dedc8eaccb951f4895d9e18b6", "float64 x;float64 y;"},
    {"MultiTargetPNPResult", "541096947e9f3ca2d3f425ff7b04aa7b",
     "PnpResult:ae4d655c0a3104d88df4f5db144c1e86 estimatedPose;int16 fiducialIDsUsed[?];"},
    {"PnpResult", "ae4d655c0a3104d88df4f5db144c1e86",
     "Transform3d best;Transform3d alt;float64 bestReprojErr;float64 altReprojErr;float64 ambiguity;"},
};

struct Packet {
  std::vector<uint8_t> b;
  template <class T>
  void put(T v) {
    uint8_t x[sizeof(T)];
    memcpy(x, &v, sizeof(T));  // aarch64 is little-endian, as PhotonVision's Packet
    b.insert(b.end(), x, x + sizeof(T));
  }
};

// Rotation matrix -> quaternion (w, x, y, z), as WPILib's Rotation3d(Matrix).
void quat(const double R[9], double q[4]) {
  double tr = R[0] + R[4] + R[8];
  if (tr > 0) {
    double s = 0.5 / sqrt(tr + 1.0);
    q[0] = 0.25 / s, q[1] = (R[7] - R[5]) * s, q[2] = (R[2] - R[6]) * s, q[3] = (R[3] - R[1]) * s;
  } else if (R[0] > R[4] && R[0] > R[8]) {
    double s = 2.0 * sqrt(1.0 + R[0] - R[4] - R[8]);
    q[0] = (R[7] - R[5]) / s, q[1] = 0.25 * s, q[2] = (R[1] + R[3]) / s, q[3] = (R[2] + R[6]) / s;
  } else if (R[4] > R[8]) {
    double s = 2.0 * sqrt(1.0 + R[4] - R[0] - R[8]);
    q[0] = (R[2] - R[6]) / s, q[1] = (R[1] + R[3]) / s, q[2] = 0.25 * s, q[3] = (R[5] + R[7]) / s;
  } else {
    double s = 2.0 * sqrt(1.0 + R[8] - R[0] - R[4]);
    q[0] = (R[3] - R[1]) / s, q[1] = (R[2] + R[6]) / s, q[2] = (R[5] + R[7]) / s, q[3] = 0.25 * s;
  }
}

// IPPE's pose (tag frame = AprilTag's homography coordinates, x right, y up) -> PhotonVision's published
// camera-to-target Transform3d (NWU), translation + quaternion.
void to_photon(const tag_pose &p, double t[3], double q[4]) {
  // R = R_h * Rz(180): negate the first two columns
  double R[9] = {-p.R[0], -p.R[1], p.R[2], -p.R[3], -p.R[4], p.R[5], -p.R[6], -p.R[7], p.R[8]};
  // EDN -> NWU: C = [[0,0,1],[-1,0,0],[0,-1,0]]; t' = C t, R' = C R C^T
  static const double C[9] = {0, 0, 1, -1, 0, 0, 0, -1, 0};
  double CR[9], Rn[9];
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++) {
      CR[i * 3 + j] = 0;
      for (int k = 0; k < 3; k++) CR[i * 3 + j] += C[i * 3 + k] * R[k * 3 + j];
    }
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++) {
      Rn[i * 3 + j] = 0;
      for (int k = 0; k < 3; k++) Rn[i * 3 + j] += CR[i * 3 + k] * C[j * 3 + k];
    }
  // and the tag frame turned 180 degrees about its (NWU) y axis, matching PhotonVision's published rotation
  // (checked live against the fork on the same frames: same quaternion within the IPPE vs orthogonal-iteration
  // difference)
  for (int i = 0; i < 3; i++) Rn[i * 3 + 0] = -Rn[i * 3 + 0], Rn[i * 3 + 2] = -Rn[i * 3 + 2];
  for (int i = 0; i < 3; i++) t[i] = C[i * 3] * p.t[0] + C[i * 3 + 1] * p.t[1] + C[i * 3 + 2] * p.t[2];
  quat(Rn, q);
}

void put_transform(Packet &k, const tag_pose *p) {
  double t[3] = {0, 0, 0}, q[4] = {1, 0, 0, 0};
  if (p) to_photon(*p, t, q);
  for (double v : t) k.put(v);
  for (double v : q) k.put(v);
}
}  // namespace

struct NtPub {
  wpi::nt::NetworkTableInstance inst;
  wpi::nt::RawPublisher raw;
  wpi::nt::IntegerPublisher heartbeat;
  wpi::nt::DoublePublisher latency, yaw, pitch, area, fps;
  wpi::nt::BooleanPublisher has;
  wpi::nt::StringPublisher version;
  cam_model cam{};
  bool have_cam = false;
  double tag_size = 0.1651;
  int64_t mid_offset_ns = 5000000;  // first packet -> mid-exposure (exposure/2 + camera delay)
  int64_t seq = 0, last_ns = 0;
  double fps_ema = 0;
};

NtPub *nt_pub_create(const char *host, const char *camera) {
  auto *p = new NtPub;
  p->inst = wpi::nt::NetworkTableInstance::Create();
  auto root = p->inst.GetTable("/photonvision");
  auto t = root->GetSubTable(camera);
  wpi::nt::PubSubOptions o;
  o.periodic = 0.01;
  o.sendAll = true;
  o.keepDuplicates = true;
  std::string type = std::string("photonstruct:PhotonPipelineResult:") + kUuid;
  p->raw = t->GetRawTopic("rawBytes").Publish(type, o);
  p->raw.GetTopic().SetProperty("message_uuid", wpi::util::json(std::string(kUuid)));
  for (const auto &s : kSchemas)
    p->inst.AddSchema(std::string("photonstruct:") + s.name + ":" + s.uuid, "photonstructschema", s.schema);
  p->heartbeat = t->GetIntegerTopic("heartbeat").Publish();
  p->latency = t->GetDoubleTopic("latencyMillis").Publish();
  p->fps = t->GetDoubleTopic("fps").Publish();
  p->yaw = t->GetDoubleTopic("targetYaw").Publish();
  p->pitch = t->GetDoubleTopic("targetPitch").Publish();
  p->area = t->GetDoubleTopic("targetArea").Publish();
  p->has = t->GetBooleanTopic("hasTarget").Publish();
  p->version = root->GetStringTopic("version").Publish();
  p->version.Set("sc-vision (Spectrum fork serde fd353b11)");
  p->inst.StartClient("sc-vision");
  p->inst.SetServer(host, 5810);
  return p;
}

void nt_pub_config(NtPub *p, const cam_model *cam, double tag_size_m, int64_t mid_offset_ns) {
  if (cam) p->cam = *cam, p->have_cam = true;
  p->tag_size = tag_size_m;
  p->mid_offset_ns = mid_offset_ns;
}

static int64_t mono_ns() {
  timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

void nt_pub_result(NtPub *p, int64_t t_first_ns, const napa_detection *d, const tag_pose *best, const tag_pose *alt,
                   int n, const int64_t * /*tag_row_ns: not published (global shutter)*/) {
  static const int perm[4] = {1, 0, 3, 2};
  const int64_t now = mono_ns();
  const int64_t capture = t_first_ns - p->mid_offset_ns;
  Packet k;
  k.b.reserve(1024);
  k.put<int64_t>(++p->seq);
  k.put<int64_t>(capture);
  k.put<int64_t>(now);
  k.put<int64_t>(0);  // timeSinceLastPong: same machine and clock as the robot's time sync server
  if (n > 127) n = 127;
  k.put<int8_t>((int8_t)n);
  double yaw0 = 0, pitch0 = 0, area0 = 0;
  for (int i = 0; i < n; i++) {
    double c[8];
    for (int j = 0; j < 4; j++) c[2 * j] = d[i].corners[2 * perm[j]], c[2 * j + 1] = d[i].corners[2 * perm[j] + 1];
    double yaw = 0, pitch = 0;
    if (p->have_cam) {
      // tag centre: intersection of the diagonals (the homography's image of the centre)
      double x1 = c[0], y1 = c[1], x2 = c[4], y2 = c[5], x3 = c[2], y3 = c[3], x4 = c[6], y4 = c[7];
      double den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4);
      double cx = (x1 + x2 + x3 + x4) / 4, cy = (y1 + y2 + y3 + y4) / 4;
      if (fabs(den) > 1e-9) {
        double a = x1 * y2 - y1 * x2, b = x3 * y4 - y3 * x4;
        cx = (a * (x3 - x4) - (x1 - x2) * b) / den;
        cy = (a * (y3 - y4) - (y1 - y2) * b) / den;
      }
      // undistort the centre (same model as pose.c), back to pixels with the camera matrix
      double ux, uy;
      {
        const cam_model &m = p->cam;
        double x0 = (cx - m.cx) / m.fx, y0 = (cy - m.cy) / m.fy, x = x0, y = y0;
        for (int it = 0; it < 30; it++) {
          double r2 = x * x + y * y;
          double ic = (1 + ((m.k[7] * r2 + m.k[6]) * r2 + m.k[5]) * r2) /
                      (1 + ((m.k[4] * r2 + m.k[1]) * r2 + m.k[0]) * r2);
          double dx = 2 * m.k[2] * x * y + m.k[3] * (r2 + 2 * x * x);
          double dy = m.k[2] * (r2 + 2 * y * y) + 2 * m.k[3] * x * y;
          x = (x0 - dx) * ic, y = (y0 - dy) * ic;
        }
        ux = x * m.fx + m.cx, uy = y * m.fy + m.cy;
      }
      yaw = atan((ux - p->cam.cx) / p->cam.fx);
      pitch = atan((p->cam.cy - uy) / (p->cam.fy / cos(yaw)));
      yaw *= 180 / M_PI, pitch *= 180 / M_PI;
    }
    double area = 0;
    for (int j = 0; j < 4; j++) {
      int q = (j + 1) % 4;
      area += c[2 * j] * c[2 * q + 1] - c[2 * q] * c[2 * j + 1];
    }
    area = fabs(area) / 2 / (1280.0 * 800.0) * 100;
    if (i == 0) yaw0 = yaw, pitch0 = pitch, area0 = area;
    k.put<double>(yaw);
    k.put<double>(pitch);
    k.put<double>(area);
    k.put<double>(0.0);  // skew
    k.put<int32_t>(d[i].id);
    k.put<int32_t>(-1);
    k.put<float>(-1.0f);
    put_transform(k, best ? &best[i] : nullptr);
    put_transform(k, alt ? &alt[i] : nullptr);
    double amb = (best && alt && alt[i].err > 0) ? best[i].err / alt[i].err : -1;
    k.put<double>(amb);
    for (int rep = 0; rep < 2; rep++) {  // minAreaRectCorners, detectedCorners
      k.put<int8_t>(4);
      for (int j = 0; j < 8; j++) k.put<double>(c[j]);
    }
  }
  k.put<int8_t>(0);  // no multitag result
  p->raw.Set(k.b);
  if (p->last_ns) {
    double f = 1e9 / (double)(now - p->last_ns);
    p->fps_ema = p->fps_ema ? 0.95 * p->fps_ema + 0.05 * f : f;
  }
  p->last_ns = now;
  p->latency.Set((now - capture) / 1e6);
  p->fps.Set(p->fps_ema);
  p->has.Set(n > 0);
  p->yaw.Set(yaw0);
  p->pitch.Set(pitch0);
  p->area.Set(area0);
  p->heartbeat.Set(p->seq);
  p->inst.Flush();
}

void nt_pub_destroy(NtPub *p) {
  if (!p) return;
  p->inst.StopClient();
  wpi::nt::NetworkTableInstance::Destroy(p->inst);
  delete p;
}
