#!/usr/bin/env node
// cookies.mjs — export cookies from a running browser / load them into a pod.
// Zero dependencies. Needs Node 21+ (global WebSocket).
//
//   node cookies.mjs export --profile weathercrm --domains weathercontracting.com[,other.com] [--from 9222]
//   node cookies.mjs load   --profile weathercrm --port 9223
//
// Profiles are JSON files in ./cookie-profiles/ — gitignored, local only.

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const profilesDir = join(here, "cookie-profiles");

function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) args[argv[i].slice(2)] = argv[++i];
    else args._.push(argv[i]);
  }
  return args;
}

async function cdpConnect(port) {
  const res = await fetch(`http://127.0.0.1:${port}/json/version`);
  if (!res.ok) throw new Error(`CDP not responding on ${port}`);
  const { webSocketDebuggerUrl } = await res.json();
  const ws = new WebSocket(webSocketDebuggerUrl);
  await new Promise((ok, fail) => {
    ws.onopen = ok;
    ws.onerror = () => fail(new Error(`WebSocket failed on ${port}`));
  });
  let id = 0;
  const pending = new Map();
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.id && pending.has(msg.id)) {
      const { ok, fail } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) fail(new Error(msg.error.message));
      else ok(msg.result);
    }
  };
  return {
    send: (method, params = {}) =>
      new Promise((ok, fail) => {
        pending.set(++id, { ok, fail });
        ws.send(JSON.stringify({ id, method, params }));
      }),
    close: () => ws.close(),
  };
}

function matchesDomain(cookieDomain, domains) {
  const d = cookieDomain.replace(/^\./, "");
  return domains.some((want) => d === want || d.endsWith("." + want));
}

const args = parseArgs(process.argv.slice(2));
const cmd = args._[0];

if (cmd === "export") {
  const { profile, domains } = args;
  const from = args.from || "9222";
  if (!profile || !domains) {
    console.error("Usage: cookies.mjs export --profile <name> --domains <d1,d2> [--from 9222]");
    process.exit(1);
  }
  const wanted = domains.split(",").map((s) => s.trim().toLowerCase());
  const cdp = await cdpConnect(from);
  const { cookies } = await cdp.send("Storage.getCookies");
  cdp.close();

  const filtered = cookies
    .filter((c) => matchesDomain(c.domain.toLowerCase(), wanted))
    .map((c) => {
      const out = {
        name: c.name,
        value: c.value,
        domain: c.domain,
        path: c.path,
        secure: c.secure,
        httpOnly: c.httpOnly,
      };
      if (c.sameSite) out.sameSite = c.sameSite;
      if (c.expires && c.expires > 0) out.expires = c.expires;
      return out;
    });

  await mkdir(profilesDir, { recursive: true });
  const file = join(profilesDir, `${profile}.json`);
  await writeFile(file, JSON.stringify(filtered, null, 2));
  console.log(`Exported ${filtered.length} cookies (${wanted.join(", ")}) -> ${file}`);
} else if (cmd === "load") {
  const { profile, port } = args;
  if (!profile || !port) {
    console.error("Usage: cookies.mjs load --profile <name> --port <cdpPort>");
    process.exit(1);
  }
  const file = join(profilesDir, `${profile}.json`);
  const cookies = JSON.parse(await readFile(file, "utf8"));
  const cdp = await cdpConnect(port);
  await cdp.send("Storage.setCookies", { cookies });
  cdp.close();
  console.log(`Loaded ${cookies.length} cookies from '${profile}' into pod on ${port}`);
} else {
  console.error("Commands: export | load");
  process.exit(1);
}
