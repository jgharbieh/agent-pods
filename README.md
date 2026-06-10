# agent-pods

> One browser per Claude Code session. Git worktrees isolate your files — pods isolate your browser.

## The problem

Parallel Claude Code sessions on git worktrees work great until they touch the browser. Every CDP tool (agent-browser, Playwright MCP, console watchers) attaches to the same browser on `localhost:9222` and operates the active tab. Two sessions = tab fights.

## The fix

A **pod** is a Docker container holding one headed Chromium with:

- **CDP** exposed on a unique localhost port (9223, 9224, …) — every CDP tool works against it unchanged
- **noVNC** web viewer — watch the agent drive the browser live in a browser tab (or a VSCode Simple Browser panel)
- **Cookie injection** — slice session cookies out of your real browser by domain, load them into a pod at spawn

Your real browser keeps `9222`. Each extra Claude session gets its own pod.

```
session 1 (main worktree)  ->  your real browser   CDP 9222
session 2 (worktree wt2)   ->  pod "wt2"           CDP 9223   watch: localhost:7901
session 3 (worktree wt3)   ->  pod "wt3"           CDP 9224   watch: localhost:7902
```

## Requirements

- Docker Desktop (WSL2 backend on Windows)
- Node 21+ (only for cookie export/load)
- Any CDP client — [agent-browser](https://github.com/vercel-labs/agent-browser) recommended

## Usage

```powershell
.\pod.ps1 build                       # once — build the image
.\pod.ps1 up wt2                      # spawn a pod
.\pod.ps1 up wt3 -Cookies myapp -Worktree D:\dev\proj-wt3
.\pod.ps1 ls                          # names, CDP ports, watch URLs
.\pod.ps1 down wt2                    # remove one
.\pod.ps1 down -All                   # remove all
```

`pod up` prints the CDP port and watch URL. Point your tools at the port:

```bash
agent-browser connect 9223
agent-browser navigate https://example.com
```

Open the watch URL to see it happen.

## Cookies

```powershell
# Export from your real browser (CDP 9222), filtered by domain:
node cookies.mjs export --profile myapp --domains example.com,api.example.com

# Load into a pod (or let `pod up -Cookies myapp` do it):
node cookies.mjs load --profile myapp --port 9223
```

Profiles land in `cookie-profiles/` — gitignored. Only the domains you name leave your browser, never the whole profile.

## Worktree binding

`pod up <name> -Worktree <path>` writes `.claude/pod.json` into the worktree:

```json
{ "name": "wt2", "cdp": 9223, "watch": "http://localhost:7901/vnc.html?autoconnect=true&resize=scale" }
```

Convention: agent skills check for `.claude/pod.json` in the workspace root first. If present, they connect to that pod's CDP port instead of 9222. A fresh Claude session opened in that worktree automatically drives that worktree's browser — zero per-session setup.

## How the container works

`debian:bookworm-slim` + Chromium (headed) on Xvfb. Chromium only binds CDP to loopback, so `socat` bridges it to the container interface. `x11vnc` + noVNC serve the virtual display over HTTP. Ports are published on `127.0.0.1` only — nothing is reachable from your network.

No API keys, no LLM in the container. It's just a browser. The agent stays on your host.

## License

MIT
