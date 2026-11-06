// sc-vision: publish each frame's tags as PhotonVision does, so PhotonLib on the robot reads sc-vision as a
// PhotonVision camera: /photonvision/<camera>/rawBytes ("photonstruct:PhotonPipelineResult:<uuid>", the
// Spectrum fork's serde, little-endian Packet encoding) + health/* (the legacy top-level heartbeat, latencyMillis,
// fps, hasTarget and target* topics were removed 2026-11-07: nothing read them; PhotonLib reads rawBytes).
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

#include "pv_pack.h"

namespace {
using pvpack::kUuid;
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

}  // namespace

struct NtPub {
  wpi::nt::NetworkTableInstance inst;
  wpi::nt::RawPublisher raw;
  wpi::nt::StringPublisher version;
  cam_model cam{};
  bool have_cam = false;
  double tag_size = 0.1651;
  int64_t mid_offset_ns = 5000000;  // first packet -> mid-exposure (exposure/2 + camera delay)
  int64_t seq = 0;
  int width = 1280, height = 800;
  // PhotonVision's /photonvision/<camera>/health/* (CameraHealthPublisher), once a second
  wpi::nt::DoublePublisher h_fps, h_pipe, h_pipe_max, h_lat;
  wpi::nt::StringPublisher h_state, h_problem;
  wpi::nt::IntegerPublisher h_beat, h_age, h_frames, h_fail, h_recov;
  int64_t h_next = 0, h_beats = 0, h_win_frames = 0, h_last_frame = 0;
  double h_sum_pipe = 0, h_max_pipe = 0, h_sum_lat = 0;
  // the robot's frame policy (input/*)
  wpi::nt::IntegerSubscriber in_process_every;
};

void nt_pub_policy(NtPub *p, int *process_every) {
  if (!p) return;
  const int64_t e = p->in_process_every.Get(0);
  if (e > 0) *process_every = (int)e;
}

void nt_pub_health(NtPub *p, int64_t now, long frames_total, long failures, double pipeline_ms, int frame_done) {
  if (frame_done) {
    p->h_win_frames++;
    p->h_sum_pipe += pipeline_ms;
    if (pipeline_ms > p->h_max_pipe) p->h_max_pipe = pipeline_ms;
    p->h_last_frame = now;
  }
  if (now < p->h_next) return;
  double win = p->h_next ? 1.0 + (now - p->h_next) / 1e9 : 1.0;
  p->h_next = now + 1000000000LL;
  int64_t age = p->h_last_frame ? (now - p->h_last_frame) / 1000000 : -1;
  p->h_fps.Set(p->h_win_frames / win);
  p->h_pipe.Set(p->h_win_frames ? p->h_sum_pipe / p->h_win_frames : 0);
  p->h_pipe_max.Set(p->h_max_pipe);
  p->h_lat.Set(p->h_win_frames ? p->h_sum_lat / p->h_win_frames : 0);
  p->h_frames.Set(frames_total);
  p->h_fail.Set(failures);
  p->h_recov.Set(0);
  p->h_age.Set(age);
  bool stale = age < 0 || age > 500;
  p->h_state.Set(stale ? "no frames" : "streaming");  // PhotonVision's word
  p->h_problem.Set(stale ? "sc-vision: no complete frames from the camera" : "");
  p->h_beat.Set(++p->h_beats);
  p->h_win_frames = 0, p->h_sum_pipe = 0, p->h_max_pipe = 0, p->h_sum_lat = 0;
}

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
  auto in = t->GetSubTable("input");
  p->in_process_every = in->GetIntegerTopic("processEvery").Subscribe(0);
  auto h = t->GetSubTable("health");
  wpi::nt::PubSubOptions keep;
  keep.keepDuplicates = true;
  p->h_fps = h->GetDoubleTopic("fps").Publish(keep);
  p->h_state = h->GetStringTopic("state").Publish(keep);
  p->h_beat = h->GetIntegerTopic("heartbeat").Publish();
  p->h_age = h->GetIntegerTopic("lastFrameAgeMs").Publish();
  p->h_pipe = h->GetDoubleTopic("pipelineMs").Publish();
  p->h_pipe_max = h->GetDoubleTopic("pipelineMsMax").Publish();
  p->h_lat = h->GetDoubleTopic("latencyMs").Publish();
  p->h_frames = h->GetIntegerTopic("frames").Publish();
  p->h_fail = h->GetIntegerTopic("decodeFailures").Publish();
  p->h_recov = h->GetIntegerTopic("recoveries").Publish();
  p->h_problem = h->GetStringTopic("problem").Publish();
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
  const int64_t now = mono_ns();
  const int64_t capture = t_first_ns - p->mid_offset_ns;
  if (n > 64) n = 64;
  int ids[64];
  double corners[64 * 8];
  for (int i = 0; i < n; i++) {
    ids[i] = d[i].id;
    napa_to_apriltag_order(d[i].corners, corners + 8 * i);
  }
  std::vector<uint8_t> buf;
  buf.reserve(1024);
  double first[3];
  // timeSinceLastPong 0: same machine and clock as the robot's time sync server
  pvpack::pack_result(buf, ++p->seq, capture, now, 0, p->have_cam ? &p->cam : nullptr, p->width, p->height, n, ids,
                      corners, best, alt, first);
  p->raw.Set(buf);
  p->h_sum_lat += (now - capture) / 1e6;
  p->inst.Flush();
}

void nt_pub_destroy(NtPub *p) {
  if (!p) return;
  p->inst.StopClient();
  wpi::nt::NetworkTableInstance::Destroy(p->inst);
  delete p;
}
