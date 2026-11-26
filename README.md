# Application Gateway Advanced Routing — Live Demo Kit

English | [日本語](README_ja.md)

A demo of [Azure Application Gateway advanced routing rules (preview)](https://learn.microsoft.com/en-us/azure/application-gateway/advanced-rules) and [advanced load balancing (preview)](https://learn.microsoft.com/en-us/azure/application-gateway/advanced-load-balancing). It deploys a real gateway with Bicep and ships a browser simulator that predicts each routing decision and compares it with the live response.

## Concepts

The diagrams are from Microsoft Learn: [What is Azure Application Gateway advanced routing rules (Preview)?](https://learn.microsoft.com/en-us/azure/application-gateway/advanced-rules)

**Hierarchy: request routing rule → advanced routing map → rules → condition sets → routing conditions**

![Diagram showing the hierarchy from a request routing rule to an advanced routing map, rules, condition sets, and routing conditions](https://learn.microsoft.com/azure/application-gateway/media/advanced-rules/advanced-routing-hierarchy.png)

**Request flows for basic, path-based, and advanced routing rules**

![Diagram of Application Gateway request flows for basic, path-based, and advanced routing rules](https://learn.microsoft.com/azure/application-gateway/media/advanced-rules/rule-flows.png)

### Advanced load balancing (preview)

The diagrams are from Microsoft Learn: [Advanced load balancing on Azure Application Gateway (Preview)](https://learn.microsoft.com/en-us/azure/application-gateway/advanced-load-balancing)

**Pool selection: weighted distribution and priority-based selection**

![Diagram comparing weighted pool selection and priority-based selection with primary and standby pools](https://learn.microsoft.com/azure/application-gateway/media/advanced-load-distribution/pool-selection.png)

**Server selection: Round Robin, Weighted Round Robin, Least Connections**

![Diagram comparing Round Robin, Weighted Round Robin, and Least Connections inside a backend pool](https://learn.microsoft.com/azure/application-gateway/media/advanced-load-distribution/server-selection.png)

**How to read it**: the pools of the matched rule are chosen in one of two ways.
- **Weighted**: traffic is split by the ratio of the weights (weights 8 and 2 give 80% / 20%). The configured shares stay the same even when a pool is unhealthy.
- **Priority**: requests go to the priority 1 pool while it meets the minimum healthy percentage. Otherwise the gateway switches to the priority 2 standby pool.

## What is in this repository

| Path | Contents |
|---|---|
| `agw-routing-simulator.html` | Standalone simulator. Offline when the gateway URL is empty; with a URL it sends the request to the real gateway and compares the answer with its prediction. Shows English or Japanese from the browser language |
| `tests/simulator.test.mjs` | Browser tests for the simulator (see Tests) |
| `docs/agw-advanced-routing-demo-guide.html` | Build guide (English). Japanese: `docs/agw-advanced-routing-demo-guide_ja.html` |
| `backend/server.js` | Dependency-free Node.js backend. Returns which pool answered and the request headers it received (the `X-Forwarded-*` headers added by Application Gateway are highlighted) as HTML or JSON. The pool name is also in the `x-backend-pool` response header. CORS is enabled (`ALLOW_ORIGIN`, default `*`) |
| `backend/pools.conf` | Process name, port, label, color, and delay for VM 1. Seven processes (ports 8080–8083, 8085, and for server selection `pool-slow` 8086 with a 3 s delay and `pool-rr-a` 8087) |
| `backend/pools-canary.conf` | Processes for VM 2 (`pool-canary` 8080, and for server selection `pool-fast` 8086 and `pool-rr-b` 8087) |
| `deploy/deploy.sh` | Creates the resource group and deploys `deploy/main.bicep`. Generates an SSH key if there is none |
| `deploy/main.bicep` | VNet, backend VM 1 (seven processes: ports 8080–8083, 8085, 8086, 8087), VM 2 (three processes: `pool-canary` 8080, `pool-fast` 8086, `pool-rr-b` 8087), NAT gateway, WAF policy, Application Gateway, and seven listeners. Four have an advanced rule and its own routing map: `rule1` / `advancedRoutingMap1` (port 80), `rule-canary` / `canaryMap` (port 8080), `rule-priority` / `priorityMap` (port 8090), `rule-flag` / `flagMap` (port 8100). Three have a Basic rule for server selection: `rule-rr` (port 8110), `rule-rr-slow` (port 8120), `rule-lc` (port 8130) |
| `deploy/make-cloud-init.sh` / `cloud-init.yaml` | Bootstrap data for backend VM 1 (embeds `backend/server.js`) |
| `deploy/cloud-init-canary.yaml` | Bootstrap data for canary VM 2 (generated from `backend/pools-canary.conf`) |
| `deploy/canary-check.sh` | Sends 100 consecutive requests to one URI and prints the count and share per pool from `x-backend-pool`. For the canary use `FRONTEND=<IP>:8080` |
| `deploy/lb-check.sh` | Sends N requests to one URI, 6 at a time by default, and prints the count, share, and average time per server, then the total time. For server selection use `FRONTEND=<IP>:8110`, `:8120`, or `:8130` |
| `deploy/test.sh` | Sends the simulator's scenarios to the real gateway with curl and lists which pool answered. |
| `.github/workflows/pages.yml` / `.github/pages/build.sh` | Publishes only the build guide to GitHub Pages. The simulator is not published, because it can send many requests to any URL; links to it point to its file in this repository. Needs Settings → Pages → Source: "GitHub Actions" |

## Steps

```bash
az login
cd deploy
./deploy.sh
FRONTEND=<frontend IP printed by deploy.sh> ./test.sh
FRONTEND=<frontend IP>:8080 ./canary-check.sh /app/home 100   # 100 requests to port 8080, count per pool
```

Deployment takes about 15–20 minutes, because creating and updating an Application Gateway is slow. Open `http://<frontend IP>/app/home` in a browser to see the page of the pool that answered. To add headers, use curl or a browser extension such as ModHeader.

Deployment uses Bicep (`main.bicep`, ARM API `Microsoft.Network/applicationGateways@2026-03-01`). Azure CLI 2.87.0 has no advanced-routing commands (such as `az network application-gateway advanced-routing-map`), so the gateway cannot be created with the CLI.

## The listeners

| Port | Rule / map | What it shows |
|---|---|---|
| 80 | `rule1` / `advancedRoutingMap1` | Condition-based routing: header, path, query string, and User-Agent rules, a redirect, and a default pool (`pool-web`) |
| 8080 | `rule-canary` / `canaryMap` | Canary: weighted distribution, `pool-web` 90% / `pool-canary` 10% |
| 8090 | `rule-priority` / `priorityMap` | Priority-based selection: `pool-primary` first, `pool-standby` when the primary is unhealthy |
| 8100 | `rule-flag` / `flagMap` | Feature flag: `X-Feature: new` goes to `pool-flag-on`, everything else to `pool-flag-off` |
| 8110 | `rule-rr` / `pool-rr` | Server selection: Round Robin over two fast servers |
| 8120 | `rule-rr-slow` / `pool-rr-slow` | Server selection: Round Robin with one slow server |
| 8130 | `rule-lc` / `pool-lc` | Server selection: Least Connections over the same slow and fast servers |

### Canary (port 8080)

The rule `canary-split` sends every request on port 8080 to `pool-web` 90% / `pool-canary` 10% (weighted distribution in an advanced rule). It does not filter by URI.

```text
client --:8080--> listener-canary --> rule-canary (Advanced)
                                            |
                                            v   map canaryMap
                                  rule: canary-split  (path ^/ = every request)
                                            |   WeightedDistribution
                              +-------------+-------------+
                              |                           |
                        weight 90                   weight 10
                              |                           |
                              v                           v
                     pool-web (VM1 :8080)        pool-canary (VM2 :8080)
                     current version             new version
```

`pool-canary` runs on VM 2 (192.168.1.11), port 8080. `pool-web` runs on VM 1, port 8080. They answer differently on the same port, so they need different IP addresses. Whether VM 2 could use a different port instead has not been tested (in an advanced rule each pool can have its own backend settings).

### Priority-based selection (port 8090)

The rule `rule-priority` (Advanced, priority 300) uses the map `priorityMap`. In the map, the rule `priority-split` matches every path and uses `pool-primary` (VM 2, port 8080, priority 1). When the healthy servers of `pool-primary` fall below the minimum healthy percentage of 60%, it switches to `pool-standby` (VM 1, port 8080, priority 2). The default target is `pool-standby`. Each pool has one server, so the switch is for the whole pool.

- Check: `FRONTEND=<IP>:8090 ./canary-check.sh /app/home 100`
- Stop and restore by hand: `az vm run-command invoke -g rg-agw-advrouting-demo -n agwdemo-backend-canary --command-id RunShellScript --scripts "systemctl stop agw-pool@pool-canary"` stops VM 2's process. The switch takes about 2–3 minutes. `systemctl start agw-pool@pool-canary` restores it, and requests go to `pool-primary` again.
- The simulator's "Test requests" button sends the request in the form (method, path, query, and headers, the same as "Send request") the chosen number of times and counts which pool answered, using the Primary / Standby names. The results appear under "Real response". A request with no response within 10 seconds is counted as failed.

### Feature flag (port 8100)

The client turns the flag on with a header. Requests with `X-Feature: new` go to `pool-flag-on` (VM 2 port 8080). Everything else goes to the default `pool-flag-off` (VM 1 port 8080). Check: `curl -H "X-Feature: new" http://<FRONTEND-IP>:8100/`

This is not an A/B test: the client chooses, and there is no random split. A statistical A/B test is tracked in issue #27.

### Server selection (ports 8110 / 8120 / 8130)

These three ports show how the gateway picks a server inside one pool, and what happens when one server is stuck (a hot spot). Each port has a Basic rule and one pool with two servers.

| Port | Rule / pool | Servers (`x-backend-pool`) | What it shows |
|---|---|---|---|
| 8110 | `rule-rr` / `pool-rr` | `pool-rr-a` (VM 1 :8087), `pool-rr-b` (VM 2 :8087), both fast | Round Robin: the servers take turns |
| 8120 | `rule-rr-slow` / `pool-rr-slow` | `pool-slow` (VM 1 :8086, waits 3 s), `pool-fast` (VM 2 :8086) | Round Robin with a slow server: about half of the requests wait 3 s |
| 8130 | `rule-lc` / `pool-lc` | the same two servers as 8120 | Least Connections: new requests avoid the slow server |

```bash
FRONTEND=<IP>:8110 ./lb-check.sh /app/home 100 6   # about half each, short total time
FRONTEND=<IP>:8120 ./lb-check.sh /app/home 100 6   # pool-slow about half, total about 25 s or more
FRONTEND=<IP>:8130 ./lb-check.sh /app/home 100 6   # pool-slow 10 or fewer, total much shorter than 8120
```

- `lb-check.sh` keeps 6 requests open at a time and prints the count, share, and average time per server, then the total time. Least Connections only differs from Round Robin while a slow server still holds earlier requests, so the requests must overlap. `canary-check.sh` sends one at a time and cannot show it.
- The simulator's "Test requests" button does the same from the browser (6 at a time) and shows the total time and the average per server. The presets are "Round Robin (port 8110)", "Round Robin with a slow server (port 8120)", and "Least Connections (port 8130)".
- Test one port at a time. 8120 and 8130 share the same two servers, so requests on one port change the open connections the other sees.
- `pool-slow` waits 3 s on every request except `/healthz`. That is shorter than the probe timeout (20 s), so the slow server stays healthy. A server that stops answering is taken out by the health probe with either algorithm; Least Connections helps when a server is slow but still passes its probe.
- Least Connections is not applied while cookie-based affinity is on. The backend settings `hs-8086` and `hs-8087` keep it off.
- The algorithm is set on the pool: `serverSelectionAlgorithm: 'LeastConnections'` on `pool-lc`. This preview property is not in the public API spec or the Bicep types. It was found by changing a pool in the portal and comparing the gateway before and after (`docs/superpowers/specs/2026-11-25-server-selection-demo-design.md`).
- Processes are added at first boot (cloud-init). An environment deployed before this change needs `./cleanup.sh` and `./deploy.sh` again.

`pool-primary`, `pool-standby`, `pool-flag-off`, and `pool-flag-on` are gateway pools that point at the existing processes, so the `x-backend-pool` header shows the process name: `pool-canary` for VM 2 and `pool-web` for VM 1.

## Tests

```bash
node --test backend/server.test.js tests/simulator.test.mjs
```

- `backend/server.test.js`: the backend's delay, health check, and CORS preflight.
- `tests/simulator.test.mjs`: the simulator in headless Chrome. It checks that the prediction follows the request form (headers, method, path, query, client IP) when "Send request" or "Send test requests" is pressed, that test requests send the form's request (against a local stand-in gateway), and that ports 8080, 8090, and 8110–8130 say they do not route by the request. It is skipped when Chrome is not found; set `CHROME_PATH` to point at it. Needs Node.js 22 or later.
- GitHub Actions (`.github/workflows/test.yml`) runs the same command on every pull request and on pushes to `main`.

## Notes

- WAF runs before routing. A request whose User-Agent contains `agw-block-demo` gets 403 from any client. The rule is in the template as `BlockDemoUA` (priority 12).
  ```bash
  curl -i -A "agw-block-demo" http://<FRONTEND>/app/home   # → 403
  curl -i http://<FRONTEND>/app/home                        # → 200
  ```
  The source IP rule (`BlockDemoIp`) is also there. Source IPs differ per environment, so the demo uses the User-Agent rule.
- Known issue: a POST without a body is blocked by WAF (managed rules, DRS 2.1) and returns 403. A POST with a JSON body, GET, and PUT pass. The partner scenario in the tests and the simulator uses GET. The rule ID that blocks it has not been identified.
- ARM API facts (checked 2026-11-20): the template validates with API versions 2026-03-01, 2026-05-01, and 2026-07-01. An advanced rule accepts a single pool (`backendAddressPool`) or several pools (`backendAddressPoolsAndSettings` + `poolSelectionAlgorithm`). With only `loadDistributionPolicy`, ARM rejects it with `ApplicationGatewayAdvancedRoutingRuleMustReference`. Bicep 0.49.2 flags `loadDistributionPolicy` with BCP037.
- The Microsoft Learn page also says "During the public preview, the service supports only header-based conditions". If creating a Path, QueryString, ClientIP, or Method condition fails, change that rule to header conditions only.
- Cleanup: `deploy/cleanup.sh` deletes the resource group (asks for the group name first). `deploy/cleanup.sh --dry-run` only lists the resources; `--yes` skips the prompt.
