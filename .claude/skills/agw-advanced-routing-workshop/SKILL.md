---
name: agw-advanced-routing-workshop
description: Run the Azure Application Gateway Advanced Routing workshop in this repo end to end — prerequisites, Bicep deploy, scenario verification with test.sh, live demos (header/path/IP/method/query/UA rules, WAF-before-routing, redirect, weighted canary, server selection (Round Robin / Least Connections on ports 8110–8130), priority-based failover, feature flag, multi-pool distribution simulation), expected results, known issues, and cleanup. Use when the user asks to run, present, rehearse, or troubleshoot this Application Gateway advanced rules demo or workshop.
---

# Application Gateway Advanced Routing workshop

A Japanese version of this document is in `SKILL_ja.md` in the same directory. Answer in the language the user writes in.

This repository demonstrates [Advanced rules (preview)](https://learn.microsoft.com/azure/application-gateway/advanced-rules) and [Advanced load balancing (preview)](https://learn.microsoft.com/azure/application-gateway/advanced-load-balancing) on a real gateway. Run the workshop in this order.

1. Check the prerequisites
2. Deploy (Bicep, about 15–20 minutes)
3. Verify (`test.sh`)
4. Live demo (rules, WAF, redirect)
5. Canary, priority-based selection, feature flag, and server selection (ports 8080, 8090, 8100, 8110–8130)
6. Load distribution simulation (simulator only)
7. Clean up

The working directory is the **repository root**. Ask the user before every Azure operation: it costs money and takes minutes.

## 1. Prerequisites

```bash
az account show --query "{sub:name, id:id, user:user.name}" -o table   # is this the right subscription?
az provider show -n Microsoft.Network --query registrationState -o tsv   # must be Registered
```

- Azure CLI 2.87.0 has **no** `az network application-gateway advanced-routing-*` commands, so the deployment uses Bicep (`deploy/main.bicep`, ARM API `Microsoft.Network/applicationGateways@2026-03-01`). Check Bicep with `az bicep version`. ARM validation also passes with 2026-05-01 and 2026-07-01; no new advanced-rule feature was found there.
- `deploy.sh` generates an SSH key (`~/.ssh/id_ed25519.pub`) when there is none.
- No parameters are needed.
- Weighted and priority-based pool selection are Advanced load balancing features. In an advanced rule they work without any feature registration (confirmed on the real gateway on 2026-11-20).

## 2. Deploy

```bash
cd deploy
./deploy.sh
```

On success the last lines include `Done. Frontend: http://<IP>/`. `deploy.sh` does the following.

- Generates two bootstrap files with `make-cloud-init.sh` (each embeds `backend/server.js`): `cloud-init.yaml` (backend VM 1) and `cloud-init-canary.yaml` (canary VM 2, from `backend/pools-canary.conf`)
- Creates the resource group `rg-agw-advrouting-demo`
- Deploys `main.bicep`:
  - VNet (`appgw` 192.168.0.0/24, `backend` 192.168.1.0/24), backend NSG, NAT gateway (StandardV2, attached to the backend subnet)
  - Backend VM 1 (Ubuntu 24.04, static IP 192.168.1.10, seven Node.js processes on ports 8080–8083, 8085, 8086 (`pool-slow`, 3 s), and 8087 (`pool-rr-a`))
  - Canary VM 2 (static IP 192.168.1.11, `pool-canary` on port 8080, `pool-fast` on 8086, `pool-rr-b` on 8087)
  - WAF policy (Prevention, DRS 2.1, custom rules `BlockDemoIp` and `BlockDemoUA`)
  - Application Gateway (WAF_v2) with seven listeners. Four have an advanced rule and its own map; three (8110–8130) have a Basic rule for server selection:

| Port | Listener | Rule | Map | Contents |
|---|---|---|---|---|
| 80 | `listener-http` | `rule1` | `advancedRoutingMap1` | Five rules (partner 10, tenant 20, api-v2 30, campaign 40, mobile 60), default `pool-web` |
| 8080 | `listener-canary` | `rule-canary` | `canaryMap` | Rule `canary-split` (every path): `pool-web` 90 / `pool-canary` 10, `WeightedDistribution`. Default `pool-canary` |
| 8090 | `listener-priority` | `rule-priority` | `priorityMap` | Rule `priority-split` (every path): `pool-primary` (priority 1) then `pool-standby` (priority 2), `PriorityAware`, minimum healthy 60%. Default `pool-standby` |
| 8100 | `listener-flag` | `rule-flag` | `flagMap` | Rule `flag-on` (`X-Feature: new`) → `pool-flag-on`. Default `pool-flag-off` |
| 8110 | `listener-rr` | `rule-rr` (Basic) | — | `pool-rr`: `pool-rr-a` / `pool-rr-b` (8087), Round Robin |
| 8120 | `listener-rr-slow` | `rule-rr-slow` (Basic) | — | `pool-rr-slow`: `pool-slow` (3 s) / `pool-fast` (8086), Round Robin |
| 8130 | `listener-lc` | `rule-lc` (Basic) | — | `pool-lc`: the same servers as 8120, `serverSelectionAlgorithm: 'LeastConnections'` |

The backends can take a few minutes to become healthy. Check:

```bash
az network application-gateway show-backend-health -g rg-agw-advrouting-demo -n agwdemo-agw -o table
```

## 3. Verify

```bash
cd deploy && FRONTEND=<IP printed by deploy.sh> ./test.sh
```

**Expected results** (confirmed on the real gateway; they do not depend on the source IP):

| Scenario | Expected | Why |
|---|---|---|
| Default | 200 pool-web | Default pool |
| Tenant | 200 pool-tenant | `X-Tenant-Id: customer-*` and `/app` |
| Partner | 200 pool-partner | `X-Partner-Id` matches (sent with GET) |
| API v2 | 200 pool-api-v2 | `X-Api-Version: 2.0` and `/api/orders` |
| Encoded path | 200 pool-api-v2 | `/api%2Forders` is decoded, then matched |
| Canary (:8080 90:10) | 200 pool-web or pool-canary | All of port 8080 is split 90% / 10%. One request lands on one of them |
| Campaign | 302 (`https://www.contoso.com/campaign?campaign=...`) | The campaign condition (priority 40) matches |
| Feature flag off | 200 pool-web (`pool-flag-off`) | Port 8100, no `X-Feature: new` header. Default of `flagMap` |
| Feature flag on | 200 pool-canary (`pool-flag-on`) | Port 8100 with `X-Feature: new`. Rule `flag-on` (priority 10) |
| Mobile | 200 pool-mobile | iPhone User-Agent |
| Round Robin (:8110) | 200 pool-rr-a or pool-rr-b | Two fast servers in `pool-rr` |
| RR slow (:8120) | 200 pool-fast, or pool-slow after 3 s | Round Robin over a slow and a fast server |
| Least conn (:8130) | 200 pool-fast, or pool-slow after 3 s | One request can reach either; use `lb-check.sh` for counts |
| WAF block (UA) | 403 | `curl -A agw-block-demo`. WAF blocks it before routing (`BlockDemoUA`) |

`x-backend-pool` is the name of the process that answered. The gateway pools `pool-primary` and `pool-flag-on` point at the `pool-canary` process on VM 2; `pool-standby` and `pool-flag-off` point at the `pool-web` process on VM 1.

## 4. Live demo

Open `agw-routing-simulator.html` in a browser and enter `http://<FRONTEND>` as the gateway URL. The simulator then shows its prediction next to the real response (`backend/server.js` has CORS enabled). The simulator shows English or Japanese from the browser language; the language link in the header switches it.

- In live mode the prediction uses the source IP that the gateway sees (`X-Forwarded-For`), not the IP of the preset.
- A browser cannot set the User-Agent header. Show the "Mobile" and "WAF block" scenarios with `curl -A`.

Suggested order:

1. **Default and a matching rule**: send the "Tenant" and "API v2" presets and show that the real `x-backend-pool` equals the prediction.
2. **Priority**: build a request that matches both the partner rule (10) and the tenant rule (20), and show that the lower number wins.
3. **Path normalization**: with "Encoded path", show that `/api%2Forders` is decoded and matches.
4. **Redirect**: send "Campaign" and check the 302 and the Location header (the query string is kept).
5. **WAF runs before routing**: see the next section.

### WAF block

WAF blocks a request before routing. Use the User-Agent rule `BlockDemoUA` (priority 12) that the template creates. It works from any client and needs no CLI changes.

```bash
curl -i -A "agw-block-demo" http://<FRONTEND>/app/home   # → 403 (blocked before routing)
curl -i http://<FRONTEND>/app/home                        # → 200 (for comparison)
```

The simulator predicts the same result with the "WAF block" preset. `BlockDemoIp` (198.51.100.0/24, by source IP) is also in the template; source IPs differ per environment, so the demo uses the User-Agent rule.

## 5. Canary, priority-based selection, and feature flag

### Canary (port 8080)

```bash
cd deploy && FRONTEND=<IP>:8080 ./canary-check.sh /app/home 100   # → about 90 pool-web, 10 pool-canary (measured: 91 / 9)
cd deploy && FRONTEND=<IP>      ./canary-check.sh /app/home 100   # → port 80: advanced rules, no split
```

The weights are expected values. With few requests the counts drift from 90 / 10.

```text
 VM1 (192.168.1.10)                      VM2 (192.168.1.11)
 +----------------------------+          +----------------------------+
 | :8080 pool-web (current)   |          | :8080 pool-canary (new)    |
 | :8081 pool-partner         |          +----------------------------+
 | :8082 pool-tenant          |
 | :8083 pool-api-v2          |
 | :8085 pool-mobile          |
 +----------------------------+

 Port 8080: listener-canary -> rule-canary -> canaryMap -> canary-split
            -> WeightedDistribution (pool-web 90 / pool-canary 10)
```

- `pool-web` runs on VM 1 port 8080. `pool-canary` answers differently on the same port, so it needs **another IP address** and runs on VM 2 (192.168.1.11) port 8080.
- In an advanced rule each pool can have its own backend settings. Both pools use `hs-pool-web` (port 8080). Whether VM 2 could use another port instead has not been tested.

### Priority-based selection (port 8090)

`pool-primary` (VM 2, priority 1) is used while it meets the minimum healthy percentage of 60%. Otherwise `pool-standby` (VM 1, priority 2) is used. Each pool has one server, so only a whole-pool switch can be shown.

| State | Expected | How |
|---|---|---|
| Normal | All 100 requests to `pool-primary` (VM 2, process `pool-canary`) | `FRONTEND=<IP>:8090 ./canary-check.sh /app/home 100` |
| VM 2 stopped | After about 2–3 minutes, all 100 to `pool-standby` (VM 1, process `pool-web`) | Stop with the command below, wait 2–3 minutes |
| Restored | All 100 back to `pool-primary` | Start with the command below, wait 2–3 minutes |

```bash
# stop (pool-canary on VM 2)
az vm run-command invoke -g rg-agw-advrouting-demo -n agwdemo-backend-canary --command-id RunShellScript --scripts "systemctl stop agw-pool@pool-canary"
# restore
az vm run-command invoke -g rg-agw-advrouting-demo -n agwdemo-backend-canary --command-id RunShellScript --scripts "systemctl start agw-pool@pool-canary"
```

- Without stopping `pool-canary` on VM 2, every request keeps going to the primary and the failover cannot be seen.
- Stopping `pool-canary` also affects port 8080 (the canary's 10%) and the flag-on pool on port 8100. Restore it after the test.
- The simulator's "Test requests" button sends the chosen number of requests to the port of the selected request. Select the "Priority (port 8090)" preset first to count Primary / Standby. While sending, the button becomes "Cancel". Results are shown under "Real response", 50 at a time. A request with no response within 10 seconds is counted as failed.

### Feature flag (port 8100)

The client turns the flag on with a header. The rule `flag-on` (priority 10) sends requests with the header `X-Feature: new` to `pool-flag-on` (VM 2 port 8080). Everything else goes to the map default `pool-flag-off` (VM 1 port 8080).

| Request | Expected |
|---|---|
| `:8100/` (no header) | pool-web (`pool-flag-off`, flag off, default) |
| `:8100/` + `X-Feature: other` | pool-web (`pool-flag-off`, flag off, default) |
| `:8100/` + `X-Feature: new` | pool-canary (`pool-flag-on`, flag on) |
| `:80/` + `X-Feature: new` | pool-web (port 80 has no feature flag rule) |

```bash
curl -s -D - -o /dev/null -H "X-Feature: new" http://<FRONTEND-IP>:8100/ | grep -i x-backend-pool
```

- The simulator's "Feature flag (off)" and "Feature flag (on)" presets predict the same.
- This is not an A/B test: the client chooses, and there is no random split. A statistical A/B test (random split with sticky assignment) is tracked in issue #27.

### Server selection (ports 8110 / 8120 / 8130)

These ports show how the gateway picks a server inside one pool, and what happens when one server is stuck (a hot spot). Each port has a Basic rule and one pool with two servers. `x-backend-pool` shows the server that answered.

| Port | Rule / pool | Servers | Expected (100 requests, 6 at a time) |
|---|---|---|---|
| 8110 | `rule-rr` / `pool-rr` (Round Robin) | `pool-rr-a` (VM 1 :8087), `pool-rr-b` (VM 2 :8087) | About half each, short total time |
| 8120 | `rule-rr-slow` / `pool-rr-slow` (Round Robin) | `pool-slow` (VM 1 :8086, waits 3 s), `pool-fast` (VM 2 :8086) | `pool-slow` 35–65, total about 25 s or more |
| 8130 | `rule-lc` / `pool-lc` (Least Connections) | the same two servers as 8120 | `pool-slow` 10 or fewer, total much shorter than 8120 |

```bash
cd deploy && FRONTEND=<IP>:8110 ./lb-check.sh /app/home 100 6
cd deploy && FRONTEND=<IP>:8120 ./lb-check.sh /app/home 100 6
cd deploy && FRONTEND=<IP>:8130 ./lb-check.sh /app/home 100 6
```

- Least Connections only differs from Round Robin while the slow server still holds earlier requests. `lb-check.sh` and the simulator's test requests keep 6 open at a time; `canary-check.sh` sends one at a time and cannot show it.
- Test one port at a time: 8120 and 8130 share the same two servers.
- The 3 s delay is shorter than the probe timeout (20 s), so `pool-slow` stays healthy. A server that stops answering is removed by the health probe with either algorithm; Least Connections helps when a server is slow but still passes its probe.
- Least Connections is not applied while cookie-based affinity is on; `hs-8086` and `hs-8087` keep it off.
- The algorithm is the pool's `serverSelectionAlgorithm: 'LeastConnections'` (`pool-lc`). It is a preview property, not in the public API spec or the Bicep types; it was found by changing a pool in the portal and comparing the gateway before and after.
- The new processes come from cloud-init at first boot. An environment deployed before this change needs `./cleanup.sh` and `./deploy.sh` again.
- Simulator presets: "Round Robin (port 8110)", "Round Robin with a slow server (port 8120)", "Least Connections (port 8130)".

## 6. Load distribution simulation (simulator)

```text
                  matched rule
                        |
                        v
              pool selection algorithm
              |                   |
              v                   v
   Weighted                   Priority
   Pool A: weight 8 (80%)     Priority 1 = primary (while it qualifies)
   Pool B: weight 2 (20%)     Priority 2 = standby (when the primary does not)
   shares stay the same       the minimum healthy percentage
   even when unhealthy        decides whether a pool qualifies
```

The "Load distribution: pool selection → server selection" section of `agw-routing-simulator.html` is a **simulation only**. It does not change the real gateway. On the real gateway only the pools of ports 8110–8130 have two servers.

- Presets: canary 90:10 on port 8080 (same as the real gateway), weights 8:2, priority (1 of 5 unhealthy → primary, 3 of 5 unhealthy → standby), WRR 6:3:1 (all healthy / the weight 6 server unhealthy)
- Expected values (same as the documentation): 90:10 → 90/10, 8:2 → 80/20. WRR 6:3:1 all healthy → 60/30/10, weight 6 unhealthy → 75/25. Priority with minimum healthy 60%: 1 of 5 unhealthy stays on the primary, 3 of 5 unhealthy goes to the standby.

Documentation sections: "Pool selection algorithm", "Server selection algorithm", "How requests are distributed" (advanced-load-balancing).

## 7. Clean up

```bash
cd deploy && ./cleanup.sh             # lists the resources, asks for the group name, then deletes the resource group
cd deploy && ./cleanup.sh --dry-run   # lists the resources only
cd deploy && ./cleanup.sh --yes       # deletes without the prompt (needed when there is no terminal)
```

`cleanup.sh` runs `az group delete -n rg-agw-advrouting-demo --yes --no-wait`, so the deletion finishes in the background after a few minutes (`az group exists -n rg-agw-advrouting-demo` returns `false` when it is done). The gateway (WAF_v2) and the VMs are billed while they run. Always delete them after the workshop.

## Known issues

- **A POST without a body returns 403**: a bodyless POST to `/api/orders` is blocked by a DRS 2.1 managed rule. A POST with a JSON body, GET, and PUT pass. The tests and the simulator use GET. The rule ID has not been identified.
- **ARM API facts (checked 2026-11-20)**: an advanced rule accepts a single pool (`backendAddressPool`) or several pools (`backendAddressPoolsAndSettings` + `poolSelectionAlgorithm`). With only `loadDistributionPolicy` (a Basic rule property), ARM rejects it with `ApplicationGatewayAdvancedRoutingRuleMustReference`. The public REST API specification (2026-03-01, 2026-05-01) does not list the multi-pool properties, so Bicep reports BCP037 warnings for them; the deployment still works.
- **A routing map needs at least one rule**: an empty `advancedRoutingRules` fails with `ApplicationGatewayAdvancedRoutingMapMustSpecifyAdvancedRoutingRules`. That is why `canaryMap` and `priorityMap` use a rule that matches every path (`^/`).
- **Changing `backend/server.js` or the pool definitions changes the VM bootstrap data**: `deploy.sh` then fails on existing VMs with `PropertyChangeNotAllowed` (`osProfile.customData`). Delete the VMs (or the resource group) and deploy again.
- **Portal edits are lost on redeploy**: `deploy.sh` puts the gateway back to the template.

## Talking points (mapped to the documentation)

| Topic | Documentation | Demo |
|---|---|---|
| Hierarchy (routing map → rule → condition set → condition) | advanced-rules: Architecture overview | `advancedRoutingMaps` / `advancedRoutingConditionSets` in `main.bicep` |
| Condition types (Header, QueryString, ClientIP, Method, Path) | advanced-rules: Supported condition types | The `test.sh` scenarios |
| Rules are evaluated in priority order; the first match wins | advanced-rules: Request flows | Priority 10 (partner) and 20 (tenant) |
| WAF runs before routing | advanced-rules | "WAF block" |
| Regular expressions (RE2) and path normalization | advanced-rules: Path, pattern matching | "Encoded path" |
| Weighted distribution (canary 90:10) | advanced-load-balancing: Weighted distribution | Port 8080, `canaryMap`, `canary-check.sh` |
| Priority-based selection and minimum healthy percentage | advanced-load-balancing: Priority-based selection | Port 8090, `priorityMap`, stop and start VM 2 |
| Header-based feature flag | advanced-rules: Use cases | Port 8100, `flagMap` |
| Server selection (RR, WRR, Least Connections) | advanced-load-balancing: Server selection | Ports 8110 / 8120 / 8130 with `lb-check.sh`, and the "Load distribution" section of the simulator (8120 / 8130 presets) |

## Design note: outbound traffic (NAT gateway)

- The backend VMs have no public IP. Inbound traffic from the internet is denied by the NSG default rules.
- Outbound traffic (apt and so on) goes through a NAT gateway (StandardV2, with its own StandardV2 public IP) attached to the backend subnet.
- The backend subnet has `defaultOutboundAccess: false` (a private subnet), so no default outbound IP is assigned.

## Files

- `deploy/main.bicep`: all infrastructure (template)
- `deploy/deploy.sh`: deployment
- `deploy/make-cloud-init.sh`, `deploy/cloud-init.yaml`, `deploy/cloud-init-canary.yaml`: VM bootstrap (VM 1 / canary VM 2)
- `deploy/test.sh`: scenario verification
- `deploy/canary-check.sh`: sends 100 consecutive requests to one URI and prints the count per pool
- `deploy/lb-check.sh`: sends N requests 6 at a time and prints the count and average time per server, and the total time (server selection on 8110–8130)
- `deploy/cleanup.sh`: deletes the resource group (`--dry-run` lists only, `--yes` skips the prompt)
- `backend/server.js`, `backend/pools.conf`, `backend/pools-canary.conf`: backend and pool definitions
- `agw-routing-simulator.html`: prediction versus real response, test requests, load distribution simulation (English / Japanese)
- `docs/agw-advanced-routing-demo-guide.html` (English), `docs/agw-advanced-routing-demo-guide_ja.html` (Japanese): guide for participants
- `README.md` (English), `README_ja.md` (Japanese)
