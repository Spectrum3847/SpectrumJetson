import { execFileSync } from "child_process";
import { readFileSync } from "fs";
import { JETSON, sshArgs } from "./fake-robot";

// Fails the run if any camera ends on a different pipeline than it started on, or a test pipeline
// (zz-uitest...) was left behind. A test that dies half way can leave either; the fix is on the
// dashboard (switch the camera back / delete the zz-uitest pipeline), and the list says where.
export default async function globalTeardown() {
  const base = process.env.PV_URL ?? "http://localhost:5800";
  let start: { camera: string; pipeline: string }[];
  try {
    start = JSON.parse(readFileSync(".state/start-pipelines.json", "utf8"));
  } catch {
    return; // setup never got that far
  }
  const cameras = (await (await fetch(`${base}/api/spectrum/uiState`)).json()).cameras as {
    nickname: string;
    currentPipelineIndex: number;
    pipelineNicknames: string[];
  }[];
  const problems: string[] = [];
  for (const c of cameras) {
    const now = c.pipelineNicknames[c.currentPipelineIndex] ?? String(c.currentPipelineIndex);
    const was = start.find((s) => s.camera === c.nickname)?.pipeline;
    if (was !== undefined && was !== now) problems.push(`${c.nickname} started on '${was}' and is now on '${now}'`);
    const leftovers = c.pipelineNicknames.filter((n) => n.startsWith("zz-uitest"));
    if (leftovers.length) problems.push(`${c.nickname} still has ${leftovers.join(", ")}`);
  }
  // Unplugged cameras: their saved pipelines must be exactly as they were.
  let absent: Record<string, unknown> = {};
  try {
    absent = JSON.parse(readFileSync(".state/absent-pipelines.json", "utf8"));
  } catch {}
  const full = (await (await fetch(`${base}/api/spectrum/uiState`)).json()).cameras as { nickname: string; pipelines: unknown }[];
  for (const [name, was] of Object.entries(absent)) {
    const now = full.find((c) => c.nickname === name)?.pipelines;
    if (JSON.stringify(now) !== JSON.stringify(was)) problems.push(`${name} (not streaming) had its saved pipelines changed`);
  }
  // Quiet mode left on by the fake robot (a run of disabled phases; it stays on with the robot gone,
  // and a restart hands it over): the scratch partition stays read-only and Rewind can't record.
  // An enable ends it, so a 2 s fake robot does.
  let quietAtStart = true;
  try {
    quietAtStart = JSON.parse(readFileSync(".state/start-quiet.json", "utf8")).quietNow;
  } catch {}
  const quietNow = async () => (await (await fetch(`${base}/api/robotState`)).json()).quietNow as boolean;
  if (!quietAtStart && (await quietNow())) {
    if (JETSON) {
      try {
        execFileSync("ssh", sshArgs("bash ~/SpectrumJetson/tests/fake-robot/run.sh enabled:2"), { stdio: "ignore", timeout: 90_000 });
      } catch {}
    }
    if (await quietNow()) problems.push("left the Jetson in quiet mode (scratch partition read-only): enable a robot once to end it");
    else console.log("Quiet mode was on after the tests; a 2 s fake-robot enable ended it");
  }
  // Test snapshots (photonvision-53), and a "field connected" one taken during the run by the fake field.
  const snaps = (await (await fetch(`${base}/api/snapshots`)).json()) as { name: string; reason: string }[];
  for (const s of snaps) if (s.name.includes("zz-uitest")) problems.push(`snapshot '${s.name}' left behind`);
  if (problems.length) {
    throw new Error(`The tests left the Jetson changed:\n  ${problems.join("\n  ")}`);
  }
}
