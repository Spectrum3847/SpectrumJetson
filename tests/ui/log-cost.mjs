// The dashboard's cost per log line (photonvision-73). Not a spec: run it from tests/ui with a
// tunnel to the Jetson open (run.sh opens one), e.g.
//   PATH=~/build/tools/node/bin:$PATH node log-cost.mjs
// Feeds N lines (default 5000) through the store action the websocket uses, one per task as they
// arrive, and prints the time per 500. Before the patch it grew with the list (0.75 ms a line at
// 2,000 kept, 26 ms at 6,900); after, it stays flat and the list stays at 2,000-2,500.
// Exits 1 if the list grew past 2,500 or the last 500 lines took over 2 s.
import { chromium } from "@playwright/test";
const N = Number(process.env.N ?? 5000);
const browser = await chromium.launch({ channel: "chrome" });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
await page.goto(process.env.PV_URL ?? "http://localhost:5800/#/dashboard");
await page.getByText("Backend connected").waitFor({ timeout: 20000 });
const r = await page.evaluate(async (n) => {
  const store = document.querySelector("#app").__vue_app__.config.globalProperties.$pinia._s.get("state");
  const times = [];
  for (let done = 0; done < n; done += 500) {
    const t0 = performance.now();
    for (let i = 0; i < 500; i++) {
      store.addLogFromWebsocket({
        logMessage: { logLevel: 2, logMessage: `[CSCore] 5th Cam: Attempting to connect to USB camera ${done + i}` }
      });
      // One line per task, as websocket messages arrive: Vue's watchers run after each.
      await new Promise((res) => {
        const c = new MessageChannel();
        c.port1.onmessage = res;
        c.port2.postMessage(0);
      });
    }
    times.push(Math.round(performance.now() - t0));
  }
  return { times, kept: store.logMessages.length };
}, N);
await browser.close();
const ok = r.kept <= 2500 && r.times[r.times.length - 1] <= 2000;
console.log(`${ok ? "PASS" : "FAIL"}: ms per 500 lines: ${r.times.join(" ")}; ${r.kept} lines kept`);
process.exit(ok ? 0 : 1);
