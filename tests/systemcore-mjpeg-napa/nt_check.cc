// SpectrumJetson systemcore-mjpeg-napa: nt_check, an independent PhotonVision-output checker. It decodes
// /photonvision/<camera>/rawBytes generically from the photonstruct schemas the publisher itself puts on
// /.schema/ (no hard-coded offsets), so the same tool reads PhotonVision and sc-vision and shows whether a
// PhotonLib client would see the same layout and values.
//   nt_check [--host 127.0.0.1] [--camera thrifty] [--secs 10] [--dump 1]
// Prints: type string + schemas found, results/s, sequence gaps, capture -> received (NT time = CLOCK_MONOTONIC
// on the SystemCore), publish - capture, frames with targets, mean/sd of the first target's fields, and the
// other topics PhotonLib reads (heartbeat, latencyMillis, hasTarget, version strings).
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include <wpi/nt/GenericEntry.hpp>
#include <wpi/nt/MultiSubscriber.hpp>
#include <wpi/nt/NetworkTableInstance.hpp>
#include <wpi/nt/Topic.hpp>
#include <wpi/nt/ntcore_cpp.hpp>

static int64_t MonoNs() {
  timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

struct Field {
  std::string type, name;  // type: int64, float64, ..., or a struct name
  bool array = false, optional = false;
};
static std::map<std::string, std::vector<Field>> g_schemas;  // struct name -> fields

static std::vector<Field> ParseSchema(const std::string &s) {
  std::vector<Field> out;
  std::stringstream ss(s);
  std::string decl;
  while (std::getline(ss, decl, ';')) {
    if (decl.find_first_not_of(" ") == std::string::npos) continue;
    Field f;
    std::stringstream ds(decl);
    std::string w;
    std::vector<std::string> words;
    while (ds >> w) words.push_back(w);
    size_t i = 0;
    if (words[i] == "optional") f.optional = true, i++;
    f.type = words[i++];
    if (auto c = f.type.find(':'); c != std::string::npos) f.type = f.type.substr(0, c);
    f.name = words[i];
    if (auto b = f.name.find("[?]"); b != std::string::npos) f.array = true, f.name = f.name.substr(0, b);
    out.push_back(f);
  }
  return out;
}

static size_t PrimSize(const std::string &t) {
  if (t == "int8" || t == "uint8" || t == "bool") return 1;
  if (t == "int16" || t == "uint16") return 2;
  if (t == "int32" || t == "uint32" || t == "float32" || t == "float") return 4;
  if (t == "int64" || t == "uint64" || t == "float64" || t == "double") return 8;
  return 0;
}

// WPILib geometry in photon serde: Transform3d = Translation3d (x, y, z) + Rotation3d as Quaternion (w, x, y, z).
static const std::map<std::string, std::vector<std::string>> kGeom = {
    {"Transform3d", {"x", "y", "z", "qw", "qx", "qy", "qz"}},
    {"Pose3d", {"x", "y", "z", "qw", "qx", "qy", "qz"}},
    {"Translation3d", {"x", "y", "z"}},
    {"Rotation3d", {"qw", "qx", "qy", "qz"}}};

static bool Decode(const std::string &type, const uint8_t *&p, const uint8_t *end, const std::string &key,
                   std::map<std::string, double> &out) {
  if (size_t n = PrimSize(type)) {
    if (p + n > end) return false;
    double v = 0;
    if (type == "int8") v = (int8_t)*p;
    else if (type == "uint8" || type == "bool") v = *p;
    else if (type == "int16") { int16_t x; memcpy(&x, p, 2); v = x; }
    else if (type == "uint16") { uint16_t x; memcpy(&x, p, 2); v = x; }
    else if (type == "int32") { int32_t x; memcpy(&x, p, 4); v = x; }
    else if (type == "uint32") { uint32_t x; memcpy(&x, p, 4); v = x; }
    else if (type == "float32" || type == "float") { float x; memcpy(&x, p, 4); v = x; }
    else if (type == "int64") { int64_t x; memcpy(&x, p, 8); v = (double)x; }
    else if (type == "uint64") { uint64_t x; memcpy(&x, p, 8); v = (double)x; }
    else { double x; memcpy(&x, p, 8); v = x; }
    out[key] = v;
    p += n;
    return true;
  }
  if (auto g = kGeom.find(type); g != kGeom.end()) {
    for (auto &c : g->second)
      if (!Decode("float64", p, end, key + "." + c, out)) return false;
    return true;
  }
  auto s = g_schemas.find(type);
  if (s == g_schemas.end()) {
    std::fprintf(stderr, "no schema for %s\n", type.c_str());
    return false;
  }
  for (auto &f : s->second) {
    const std::string k = key.empty() ? f.name : key + "." + f.name;
    if (f.optional) {
      if (p >= end) return false;
      const int present = *p++;
      out[k + "?"] = present;
      if (present && !Decode(f.type, p, end, k, out)) return false;
    } else if (f.array) {
      if (p >= end) return false;
      const int n = (int8_t)*p++;
      out[k + "#"] = n;
      for (int i = 0; i < n; i++)
        if (!Decode(f.type, p, end, k + "[" + std::to_string(i) + "]", out)) return false;
    } else if (!Decode(f.type, p, end, k, out)) {
      return false;
    }
  }
  return true;
}

static double Pct(std::vector<double> v, double q) {
  if (v.empty()) return NAN;
  std::sort(v.begin(), v.end());
  return v[std::min(v.size() - 1, (size_t)(q * (v.size() - 1) + 0.5))];
}

int main(int argc, char **argv) {
  std::string host = "127.0.0.1", cam = "thrifty";
  FILE *csv_out = nullptr;
  double secs = 10;
  int dump = 1;
  for (int i = 1; i + 1 < argc; i += 2) {
    std::string a = argv[i];
    if (a == "--host") host = argv[i + 1];
    else if (a == "--camera") cam = argv[i + 1];
    else if (a == "--secs") secs = atof(argv[i + 1]);
    else if (a == "--dump") dump = atoi(argv[i + 1]);
    else if (a == "--csv") {  // one row per result: seq, capture ns, publish ns, received ns (CLOCK_MONOTONIC), targets
      csv_out = std::fopen(argv[i + 1], "w");
      if (csv_out) std::fprintf(csv_out, "seq,capture_ns,publish_ns,received_ns,ntargets\n");
    }
  }
  auto inst = wpi::nt::NetworkTableInstance::Create();
  inst.StartClient("nt_check");
  inst.SetServer(host.c_str(), 5810);
  wpi::nt::PubSubOptions all;
  all.sendAll = true;
  all.pollStorage = 1000;
  wpi::nt::MultiSubscriber ms(inst, {{"/.schema/", "/photonvision/"}}, all);
  const std::string base = "/photonvision/" + cam + "/";
  auto raw = inst.GetTopic(base + "rawBytes").GenericSubscribe(all);
  for (int i = 0; i < 300 && !inst.IsConnected(); i++) usleep(10000);
  usleep(500000);
  std::printf("connected %d to %s; rawBytes type '%s'\n", (int)inst.IsConnected(), host.c_str(),
              raw.GetTopic().GetTypeString().c_str());
  raw.ReadQueue();  // drop what queued while connecting (it would count as late)
  long n = 0, tagged = 0, gaps = 0, bad = 0;
  double last_seq = -1;
  std::vector<double> rx_lat, pub_lat, pub_rx;
  std::map<std::string, std::vector<double>> fields;
  std::map<std::string, double> first;
  std::map<int, std::map<std::string, std::vector<double>>> per_id;
  const int64_t end = MonoNs() + (int64_t)(secs * 1e9);
  while (MonoNs() < end) {
    if (g_schemas.empty() || g_schemas.size() < 6) {
      for (auto &t : inst.GetTopics("/.schema/photonstruct:")) {
        const std::string name = t.GetName().substr(std::strlen("/.schema/photonstruct:"));
        auto v = inst.GetEntry(t.GetName()).GetValue();
        if (v.IsRaw()) {
          auto r = v.GetRaw();
          g_schemas[name.substr(0, name.find(':'))] = ParseSchema(std::string(r.begin(), r.end()));
        }
      }
    }
    for (auto &v : raw.ReadQueue()) {
      const int64_t now = MonoNs();
      if (!v.IsRaw()) continue;
      auto r = v.GetRaw();
      std::map<std::string, double> d;
      const uint8_t *p = r.data();
      std::string top = raw.GetTopic().GetTypeString();
      top = top.substr(top.find(':') + 1);
      top = top.substr(0, top.find(':'));
      if (!Decode(top, p, r.data() + r.size(), "", d) || p != r.data() + r.size()) {
        bad++;
        continue;
      }
      n++;
      const double seq = d["metadata.sequenceID"];
      if (last_seq >= 0 && seq != last_seq + 1) gaps++;
      last_seq = seq;
      const double cap = d["metadata.captureTimestampNanos"], pub = d["metadata.publishTimestampNanos"];
      if (csv_out) std::fprintf(csv_out, "%.0f,%.0f,%.0f,%lld,%d\n", seq, cap, pub, (long long)now, (int)d["targets#"]);
      rx_lat.push_back((now - cap) / 1e6);
      pub_lat.push_back((pub - cap) / 1e6);
      pub_rx.push_back((now - pub) / 1e6);
      if (d["targets#"] > 0) {
        tagged++;
        if (first.empty()) first = d;
        for (auto &kv : d)
          if (kv.first.rfind("targets[0].", 0) == 0) fields[kv.first].push_back(kv.second);
      }
      // per fiducial id: range, translation, rotation (angle from the mean later), apparent size (px)
      for (int i = 0; i < (int)d["targets#"]; i++) {
        const std::string t = "targets[" + std::to_string(i) + "].";
        const int id = (int)d[t + "fiducialId"];
        auto &v = per_id[id];
        const double x = d[t + "bestCameraToTarget.x"], y = d[t + "bestCameraToTarget.y"],
                     z = d[t + "bestCameraToTarget.z"];
        v["range"].push_back(std::sqrt(x * x + y * y + z * z));
        v["x"].push_back(x), v["y"].push_back(y), v["z"].push_back(z);
        double q[4] = {d[t + "bestCameraToTarget.qw"], d[t + "bestCameraToTarget.qx"], d[t + "bestCameraToTarget.qy"],
                       d[t + "bestCameraToTarget.qz"]};
        if (q[0] < 0) for (double &c : q) c = -c;  // one hemisphere
        v["qw"].push_back(q[0]), v["qx"].push_back(q[1]), v["qy"].push_back(q[2]), v["qz"].push_back(q[3]);
        double side = 0;
        for (int k = 0; k < 4; k++) {
          const std::string a = t + "detectedCorners[" + std::to_string(k) + "].",
                            b = t + "detectedCorners[" + std::to_string((k + 1) % 4) + "].";
          side += std::hypot(d[a + "x"] - d[b + "x"], d[a + "y"] - d[b + "y"]) / 4;
        }
        v["side"].push_back(side);
        v["amb"].push_back(d[t + "poseAmbiguity"]);
      }
    }
    usleep(1000);
  }
  std::printf("schemas: %zu (", g_schemas.size());
  for (auto &s : g_schemas) std::printf("%s ", s.first.c_str());
  std::printf(")\n%ld results in %.0f s (%.1f/s), %ld with targets, %ld undecodable, %ld sequence gaps\n", n, secs,
              n / secs, tagged, bad, gaps);
  std::printf("capture -> received here ms p50/p95/p99 %.3f / %.3f / %.3f; capture -> publish %.3f / %.3f / %.3f; "
              "publish -> received %.3f / %.3f / %.3f\n",
              Pct(rx_lat, .5), Pct(rx_lat, .95), Pct(rx_lat, .99), Pct(pub_lat, .5), Pct(pub_lat, .95),
              Pct(pub_lat, .99), Pct(pub_rx, .5), Pct(pub_rx, .95), Pct(pub_rx, .99));
  auto msd = [](const std::vector<double> &v, double &m, double &s) {
    m = 0, s = 0;
    for (double x : v) m += x;
    m /= std::max<size_t>(1, v.size());
    for (double x : v) s += (x - m) * (x - m);
    s = v.size() > 1 ? std::sqrt(s / (v.size() - 1)) : 0;
  };
  if (!per_id.empty())
    std::printf("per tag id (of %ld results): seen%%  side px  range m (sd mm)  rot sd deg  ambiguity p50\n", n);
  for (auto &kv : per_id) {
    auto &v = kv.second;
    double side, sides, rm, rs, qm[4], qs;
    msd(v["side"], side, sides);
    msd(v["range"], rm, rs);
    const char *qk[4] = {"qw", "qx", "qy", "qz"};
    for (int k = 0; k < 4; k++) msd(v[qk[k]], qm[k], qs);
    double qn = std::sqrt(qm[0] * qm[0] + qm[1] * qm[1] + qm[2] * qm[2] + qm[3] * qm[3]);
    std::vector<double> ang;  // angle of each rotation from the mean rotation
    for (size_t i = 0; i < v["qw"].size(); i++) {
      double dot = std::fabs(v["qw"][i] * qm[0] + v["qx"][i] * qm[1] + v["qy"][i] * qm[2] + v["qz"][i] * qm[3]) / qn;
      ang.push_back(2 * std::acos(std::min(1.0, dot)) * 180 / M_PI);
    }
    double am = 0;
    for (double a : ang) am += a * a;
    am = ang.empty() ? 0 : std::sqrt(am / ang.size());
    std::printf("  id %-3d %6.1f%%  %6.1f  %7.4f (%6.2f)  %8.3f  %8.3f\n", kv.first, 100.0 * v["range"].size() / std::max(1L, n),
                side, rm, 1000 * rs, am, Pct(v["amb"], .5));
  }
  for (auto &kv : fields) {
    double m = 0, s = 0;
    for (double x : kv.second) m += x;
    m /= kv.second.size();
    for (double x : kv.second) s += (x - m) * (x - m);
    s = kv.second.size() > 1 ? std::sqrt(s / (kv.second.size() - 1)) : 0;
    std::printf("  %-44s mean %12.6f  sd %10.6f\n", kv.first.c_str(), m, s);
  }
  if (dump && !first.empty()) {
    std::printf("first tagged result, all fields:\n");
    for (auto &kv : first)
      if (kv.first.rfind("targets[0]", 0) != 0) std::printf("  %s = %.6f\n", kv.first.c_str(), kv.second);
  }
  for (const char *t : {"heartbeat", "latencyMillis", "hasTarget", "targetYaw", "targetPitch", "targetArea",
                        "version", "photonVersion", "remoteVersion"}) {
    auto e = inst.GetEntry(base + t).GetValue();
    if (!e) continue;
    if (e.IsDouble()) std::printf("  %s = %f\n", t, e.GetDouble());
    else if (e.IsInteger()) std::printf("  %s = %lld\n", t, (long long)e.GetInteger());
    else if (e.IsBoolean()) std::printf("  %s = %d\n", t, e.GetBoolean());
    else if (e.IsString()) std::printf("  %s = '%s'\n", t, std::string(e.GetString()).c_str());
  }
  for (auto &t : inst.GetTopics(base)) std::printf("  topic %s [%s]\n", t.GetName().c_str(), t.GetTypeString().c_str());
  if (csv_out) std::fclose(csv_out);
  return 0;
}
