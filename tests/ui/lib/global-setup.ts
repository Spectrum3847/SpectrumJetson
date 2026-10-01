import { mkdirSync, writeFileSync } from "fs";
import { measureCameras } from "./cameras";

// Refuse to run against a robot that's connected, and make sure our build is the one answering.
export default async function globalSetup() {
  const base = process.env.PV_URL ?? "http://localhost:5800";
  let state: Response;
  try {
    state = await fetch(`${base}/api/spectrum/uiState`);
  } catch (e) {
    throw new Error(
      `Can't reach PhotonVision at ${base}. Open the tunnel first (tests/ui/run.sh does it), or set PV_URL.`
    );
  }
  if (!state.ok) {
    throw new Error(
      `${base}/api/spectrum/uiState answered ${state.status}: this PhotonVision build is older than photonvision-45.`
    );
  }
  // Every camera's running pipeline, so global-teardown can catch a test that leaves one moved.
  const cameras = (await state.json()).cameras as { nickname: string; currentPipelineIndex: number; pipelineNicknames: string[] }[];
  const start = cameras.map((c) => ({ camera: c.nickname, pipeline: c.pipelineNicknames[c.currentPipelineIndex] ?? String(c.currentPipelineIndex) }));
  mkdirSync(".state", { recursive: true });
  writeFileSync(".state/start-pipelines.json", JSON.stringify(start, null, 2));
  const rewind = await (await fetch(`${base}/api/rewind`)).json();
  // Quiet mode (photonvision-56): the fake robot's disabled phases can start it, and with no robot
  // left it stays on, so global-teardown ends it if it wasn't on before.
  const robot = await (await fetch(`${base}/api/robotState`)).json();
  writeFileSync(".state/start-quiet.json", JSON.stringify({ quietNow: !!robot.quietNow }));
  // Which cameras are streaming. Tests run on those; the ones that touch every camera skip if any
  // isn't (PhotonVision changes an unplugged camera's saved setup too, and nothing can put it back
  // until it's plugged in: a run on 2026-10-01 left test pipelines in three cameras' settings).
  const inventory = await measureCameras(base);
  if (!inventory.streaming.length) {
    throw new Error("No camera is streaming: plug at least one in (the tests need frames).");
  }
  writeFileSync(".state/cameras.json", JSON.stringify(inventory, null, 2));
  if (inventory.absent.length) {
    console.log(`Not streaming: ${inventory.absent.join(", ")}. Tests run on ${inventory.streaming.join(", ")}; every-camera tests skip.`);
  }
  // Every unplugged camera's saved pipelines, so global-teardown can check nothing touched them.
  const full = (await (await fetch(`${base}/api/spectrum/uiState`)).json()).cameras as { nickname: string; pipelines: unknown }[];
  writeFileSync(
    ".state/absent-pipelines.json",
    JSON.stringify(Object.fromEntries(full.filter((c) => inventory.absent.includes(c.nickname)).map((c) => [c.nickname, c.pipelines])))
  );
  if (rewind.robotConnected && process.env.PV_UI_TEST_ON_ROBOT !== "1") {
    throw new Error(
      "The Jetson is connected to a robot. These tests switch pipelines and move camera settings; " +
        "run them on the bench, or set PV_UI_TEST_ON_ROBOT=1 if the robot is safe (disabled, on blocks)."
    );
  }
}
