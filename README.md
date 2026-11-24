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
| `docs/agw-advanced-routing-demo-guide.html` | Build guide (English). Japanese: `docs/agw-advanced-routing-demo-guide_ja.html` |
| `backend/server.js` | Dependency-free Node.js backend. Returns which pool answered and the request headers it received (the `X-Forwarded-*` headers added by Application Gateway are highlighted) as HTML or JSON. The pool name is also in the `x-backend-pool` response header. CORS is enabled (`ALLOW_ORIGIN`, default `*`) |
| `backend/pools.conf` | Pool name, port, label, and color for VM 1. Five pools (ports 8080–8083, 8085) |
| `backend/pools-canary.conf` | Pool definition for canary VM 2 (`pool-canary`, port 8080) |
| `deploy/deploy.sh` | Creates the resource group and deploys `deploy/main.bicep`. Generates an SSH key if there is none |
| `deploy/main.bicep` | VNet, backend VM 1 (five pools), canary VM 2 (`pool-canary`, 8080), NAT gateway, WAF policy, Application Gateway, and four listeners, each with an advanced rule and its own routing map: `rule1` / `advancedRoutingMap1` (port 80), `rule-canary` / `canaryMap` (port 8080), `rule-priority` / `priorityMap` (port 8090), `rule-ab` / `abMap` (port 8100) |
| `deploy/make-cloud-init.sh` / `cloud-init.yaml` | Bootstrap data for backend VM 1 (embeds `backend/server.js`) |
| `deploy/cloud-init-canary.yaml` | Bootstrap data for canary VM 2 (generated from `backend/pools-canary.conf`) |
| `deploy/canary-check.sh` | Sends 100 consecutive requests to one URI and prints the count and share per pool from `x-backend-pool`. For the canary use `FRONTEND=<IP>:8080` |
| `deploy/test.sh` | Sends the simulator's scenarios to the real gateway with curl and lists which pool answered. |

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

## The four listeners

| Port | Rule / map | What it shows |
|---|---|---|
| 80 | `rule1` / `advancedRoutingMap1` | Condition-based routing: header, path, query string, and User-Agent rules, a redirect, and a default pool (`pool-web`) |
| 8080 | `rule-canary` / `canaryMap` | Canary: weighted distribution, `pool-web` 90% / `pool-canary` 10% |
| 8090 | `rule-priority` / `priorityMap` | Priority-based selection: `pool-primary` first, `pool-standby` when the primary is unhealthy |
| 8100 | `rule-ab` / `abMap` | A/B test: `X-Variant: B` goes to `pool-B`, everything else to `pool-A` |

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
- The simulator's "Test requests" button sends the chosen number of requests to the port of the selected request and counts which pool answered, using the Primary / Standby names. The results appear under "Real response". A request with no response within 10 seconds is counted as failed.

### A/B test (port 8100)

Requests with `X-Variant: B` go to `pool-B` (variant B, VM 2 port 8080). Everything else goes to the default `pool-A` (variant A, VM 1 port 8080). Check: `curl -H "X-Variant: B" http://<FRONTEND-IP>:8100/`

`pool-primary`, `pool-standby`, `pool-A`, and `pool-B` are gateway pools that point at the existing processes, so the `x-backend-pool` header shows the process name: `pool-canary` for VM 2 and `pool-web` for VM 1.

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
