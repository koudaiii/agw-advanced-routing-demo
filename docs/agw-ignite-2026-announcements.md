# Microsoft Ignite 2026: Azure Application Gateway announcements

English | [日本語](agw-ignite-2026-announcements_ja.md) / [Web version](https://koudaiii.com/agw-advanced-routing-demo/agw-ignite-2026-announcements.html) / Related: [Demo environment build guide](https://koudaiii.com/agw-advanced-routing-demo/agw-advanced-routing-demo-guide.html)

As of November 26, 2026. Scope: the five 2026 items in Azure Updates with product "Application Gateway" and tag "Microsoft Ignite" (all public previews published on November 17, 2026, with Update Types "Microsoft Ignite" and "Feature").

## Summary: five features that move routing, authentication, and data protection into the gateway

The Application Gateway announcements at Ignite 2026 move decisions that apps and surrounding infrastructure used to make into the gateway. They cover four areas, scale platform, traffic control, identity, and data protection, with five items in all.

All five are public previews (no SLA, not recommended for production). Some come with limits such as "can be chosen only at creation" or "cannot be combined with other preview features". Start with a proof of concept, with those limits in mind.

| # | Announcement (Azure Update ID) | Area | What changes | Existing gateway |
|---|---|---|---|---|
| 1 | Next-generation elastic architecture = Accelerated deployment tier (580428) | Scale platform | Up to 50% shorter provisioning and up to 70% shorter autoscaling | No (chosen at creation) |
| 2 | Advanced routing rules (579324) | Traffic control | Routing by Header / QueryString / ClientIP / Method / Path conditions | Yes (update a Basic rule to Advanced) |
| 3 | Advanced load balancing (580423) | Traffic control | Between pools: weighted or priority; within a pool: weighted round robin or least connections | Yes |
| 4 | Centralized user authentication + JWT validation (580418) | Identity | OIDC sign-in and JWT validation, with one policy applied to many gateways | Yes |
| 5 | Confidential Compute (579649) | Data protection | The data plane runs in a TEE, protecting data even after decryption | No (enabled at creation) |

## Overview: where in the gateway each feature works

#2 to #4 work at stages of request processing; #1 and #5 work on the gateway's platform itself.

```text
Client
  │ HTTPS
  ▼
Application Gateway (Standard_v2 / WAF_v2)
  ├─ ① Listener ............ Advanced rules need a Basic listener (no multisite)
  ├─ ② WAF policy .......... Evaluated before routing (per gateway / listener)
  ├─ ③ Routing rule ........ Authentication policy (OIDC / JWT) per rule [#4]
  ├─ ④ Advanced routing map  Condition sets (AND) in priority order [#2]
  ├─ ⑤ Pool selection ...... Weighted, or priority + minimum healthy percentage [#3]
  └─ ⑥ Server selection .... Round robin / weighted RR / least connections [#3]
  ▼
Backend pool

Platform: Accelerated tier [#1] / Confidential Compute (TEE) [#5]
* During the preview, the Accelerated tier cannot be combined with other preview features, including #2 to #5
```

## 1. Accelerated deployment tier: faster scaling for new gateways

The next-generation architecture of Application Gateway v2 can now be chosen as a new deployment tier, "Accelerated (preview)". Compared with the current tier, it cuts provisioning time by up to 50% and autoscaling time by up to 70%. It also supports scale-out in under a minute and longer connection draining. There is no extra charge; the billing model is the same as today.

| Deployment tier | Position | Fits |
|---|---|---|
| Standard | The current GA platform. A public frontend IP is required | General workloads, workloads that need WAF |
| Network isolated | Private-only gateways without a registration flag | No public IP allowed, forced tunneling of outbound traffic, outbound Deny All |
| Accelerated (preview) | Public, private-only, or both, without registration | Sudden traffic changes, when scaling speed and limits matter |

Limits during the preview:

- The deployment tier cannot be changed after creation. There is no in-place migration of an existing gateway (create a new one and move the configuration)
- The WAF tier, FIPS mode, TCP/TLS proxy, and Private Link are not supported
- Other features currently in preview (including #2 to #5 in this document) cannot be combined with it
- Keep at least 10 free IP addresses in the gateway subnet. Allow inbound traffic from the client IP ranges to the listener ports in the NSG
- The gateway health dashboard, the certificate metadata API, on-demand backend health, and subnet sharing are not available
- Available in 21 regions. In Japan, only Japan West (not Japan East). In the portal, create it from the preview link

Note: the Japanese Learn page (updated November 17, 2026) is older than the English page (updated November 25) and differs in the region list and limits. Check against the English page.

## 2. Advanced routing rules: five condition types in one rule

Routing that used to center on paths now also branches on attributes of the HTTP request. Rules are evaluated from the smallest priority; the request goes to the destination of the first matching rule (a backend pool or a redirect). If no rule matches, it goes to the default pool.

```text
Advanced routing map (up to 100 per gateway)
  ├─ Advanced routing rule (up to 100 per map) ... evaluated from the smallest priority
  │    ├─ Condition set ... up to 5 conditions; matches when all match (AND)
  │    │    └─ Condition ... up to 5 values; matches when any matches (OR). Values and regex up to 128 characters
  │    └─ Destination ... backend pool + HTTP settings (+ rewrite set), or a redirect
  └─ Default destination ... pool + HTTP settings (+ rewrite set) when no rule matches
Up to 10,000 condition sets per gateway
```

| Condition type | Match | Notes |
|---|---|---|
| Header | Exact / regular expression | Regular expressions must be RE2-compatible |
| QueryString | Exact / regular expression | Only QueryString accepts an empty value |
| ClientIP | IPv4 / IPv6 | CIDR notation |
| Method | Exact only | Uppercase (GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, PATCH) |
| Path | Exact / regular expression | Evaluated after URL decoding (`/foo%2Fbar` is compared as `/foo/bar`) |

Example condition (in the format Learn uses):

```json
{
  "conditionType": "Header",
  "propertyName": "X-Custom-Header",
  "propertyValueMatcher": { "pattern": "^(customer-[0-9]+|partner-[a-z]+)$" }
}
```

Limits and notes:

- Basic listeners only. Multisite listeners and L4 (TCP/TLS proxy) are not supported
- WAF is evaluated before routing. A WAF policy is per gateway or listener; it cannot be associated per rule
- Rewrite sets are applied after the routing decision, before the request is sent to the backend
- The portal's gateway creation wizard cannot configure it. After creation, update an existing Basic rule to Advanced
- The priority of an Advanced rule is separate from the priority of an ordinary routing rule

Conflicting information: the Learn overview page still has a sentence saying "only Header conditions during the public preview". The condition list on the same page, the Azure Update, and the product blog all state five types. The published demo environment also worked with, among others, an AND of a Header (regular expression) and a Path condition, so this summary treats all five types as supported. Check in the portal or API before use.

Use cases: A/B tests and canaries (header), API versioning (query / header), multitenancy (tenant ID header), read/write split (method), internal and partner paths (client IP), mobile split (User-Agent).

## 3. Advanced load balancing: pool selection and server selection in two steps

One rule can have several backend pools. The gateway first picks a pool, then a server in that pool. The two choices are independent; for example, "weighted between pools, least connections within a pool".

```text
Request
  ▼
① Pool selection (up to 5 pools per rule or default action; one method or the other)
  ├─ Weighted ... integers 0–100 set the ratio (e.g. 8:2 is 80% / 20%)
  └─ Priority ... 1–5. The highest-priority pool that meets the minimum healthy percentage (0–100%)
  ▼
② Server selection (set per pool)
  ├─ Round robin (default)
  ├─ Weighted round robin ... 0–100. Only servers registered by IP / FQDN
  └─ Least connections ...... Not applied while cookie affinity is on
```

Priority failover example (minimum healthy percentage 60%, 5 primary servers, 4 standby servers):

| Situation | Primary healthy percentage | Selected pool |
|---|---|---|
| 1 primary server down | 80% (4 of 5) | Primary |
| 3 primary servers down | 40% (2 of 5) | Standby (switches even with 2 healthy servers left) |

When no pool meets the threshold, requests go to the highest-priority pool. When a higher pool meets the threshold again, new requests go back to it at once (the return cannot be delayed).

Design pitfalls:

- Weighted selection does not look at pool health. If a pool with no healthy server is chosen, the request fails. To take a pool out, set its weight to 0; to switch by health, use priority
- With cookie affinity on, weighted selection pins existing sessions with a pool cookie (a weight change affects new sessions only). Priority selection issues no pool cookie, and on a switch the next request moves
- New instances right after a scale-out count as unhealthy until they pass the probe. The healthy percentage drops for a while and can cause an unintended switch (going from 4 to 8 servers is 50% for a while)
- Weighted round robin cannot be used in a pool that has NIC-associated VMs / VMSS
- The Basic SKU and L4 (TCP/TLS proxy) are not supported. Classic path-based rules stay at one pool. Multiple pools are set on Basic / Advanced rules (and the default action of an Advanced routing map)
- HTTP settings with Dedicated Backend Connection cannot be used for multiple pools
- API version 2026-03-01 or later is required

For AI: put a PTU (provisioned throughput) endpoint in the priority 1 pool and a pay-as-you-go endpoint in the priority 2 pool. Traffic goes to pay-as-you-go only when the provisioned side drops below the threshold. Clients need no change.

## 4. Centralized user authentication + JWT validation: moving authentication from apps to the gateway

One authentication policy can now be created and associated with routing rules on many gateways. Use OIDC user sign-in for browsers and JWT validation for APIs.

| Aspect | User authentication | JWT validation |
|---|---|---|
| Main clients | Browsers (interactive users) | APIs, service-to-service, automation |
| Method | OIDC authorization code flow | Bearer token validation (signature, issuer, audience, expiry) |
| Redirect to the IdP | Yes | No |
| Gateway session cookie | Yes (default name ApplicationGatewayUserSession, 7 days by default) | No (the token is validated every time) |
| Unauthenticated requests | Authenticate (recommended) / allow / deny (401) | Deny (401) / allow (forwarded without the identity header) |
| Headers to the backend | `x-msft-entra-identity` (`<tid>:<sub>`), plus the ID / access token when available | `x-msft-entra-identity` (`tenantId:oid`) |

Prerequisites:

- Standard_v2 / WAF_v2. An HTTPS listener is required (not HTTP)
- Applies to Basic / Advanced rules (including Advanced rules with path conditions). Classic path-based rules are not supported
- One authentication policy per rule. The policy is a regional resource in the same region as the gateway
- User authentication: the IdP is Microsoft Entra ID. Keep the client secret in Key Vault and give each gateway's managed identity read access. Up to 10 scopes (default: openid, profile, email)
- JWT validation: the gateway must reach the Microsoft Entra metadata endpoint over TCP 443

The earlier JWT validation preview:

- This JWT validation is a revision of the existing JWT validation preview. The earlier preview will not go GA and will be retired (a formal retirement notice will follow)
- Earlier policies keep working until the new centralized JWT validation is GA. There is no automatic migration
- Use centralized policies for new configurations; users of the earlier preview should plan to reconfigure

## 5. Confidential Compute: protecting data in a TEE even after decryption

The Application Gateway data plane runs in a hardware trusted execution environment (TEE), protecting data while the gateway decrypts and processes it. TLS termination, WAF, L7 routing, L4 proxy, load balancing, and monitoring work as before.

```text
Client ──TLS──▶ Application Gateway (Confidential Compute)
                  └─ In the TEE: TLS termination → WAF inspection → routing
                     (memory encrypted by hardware, isolated from the hypervisor and host)
                ──TLS──▶ Backend (e.g. Confidential VM)
```

- An add-on for Standard_v2 / WAF_v2. It can be enabled only when the gateway is created (not on an existing one)
- In the portal, select the check box at creation. In the API, `"enableConfidentialCompute": true` (API version 2026-05-01 or later)
- Pricing: "SKU fixed price + capacity units + hourly charge for the Confidential Compute add-on"
- Available in 17 regions. In Japan, only Japan East (not Japan West)
- It does not protect against vulnerabilities in app code or a compromised backend

| Key Vault type | Private key | Protection |
|---|---|---|
| Standard / Premium | The gateway gets the PFX and does TLS in the TEE | Private key and app data protected in the TEE |
| Managed HSM | The private key never leaves the HSM; the HSM does the cryptography | Key in the HSM, app data in the TEE |

Fits: workloads with financial transactions, health information, personal data, or intellectual property, and extending the protection of confidential backends (such as Confidential VMs) to the app delivery layer.

## Combination limits: four points to check before design

1. Chosen only at creation: the Accelerated tier and Confidential Compute. To use them with an existing gateway, create a new one and move the configuration
2. Try Accelerated on its own: during the preview, it cannot be combined with the WAF tier or other preview features, including #2 to #5
3. Move path-based rules to Advanced rules: multi-pool load balancing and authentication policies do not work on classic path-based rules. Replacing them with Advanced rules with Path conditions makes both available
4. Japan regions differ: Accelerated is Japan West only, Confidential Compute is Japan East only

| Feature | Add to an existing gateway | With WAF_v2 | L4 (TCP/TLS) proxy | Classic path-based rules | Japan regions |
|---|---|---|---|---|---|
| #1 Accelerated | No | No (WAF tier not supported) | No | — (tier feature) | Japan West only |
| #2 Advanced routing | Yes | Yes (WAF per gateway / listener) | No | Replacement | Not stated |
| #3 Advanced load balancing | Yes | Yes | No | No (stays at one pool) | Not stated |
| #4 User authentication / JWT | Yes | Yes | — (HTTPS listeners only) | No | Not stated |
| #5 Confidential Compute | No | Yes | Yes | — (platform feature) | Japan East only |

## Next steps: a proof of concept per scenario

| Customer problem | Feature to try | First step |
|---|---|---|
| Scaling cannot keep up with traffic spikes | #1 | In Japan West, put a workload that does not need WAF on a new gateway and measure the scaling time |
| Staged releases; making full use of AI PTUs | #2 + #3 | Update a test Basic rule on an existing gateway to Advanced, and try 90:10 weights and priority switching |
| Stop implementing authentication in every app | #4 | Create a user authentication policy for browser apps and a JWT validation policy for APIs, and associate them with several gateways |
| Protecting data in use is a requirement (finance, healthcare, and so on) | #5 | In Japan East, create a new gateway with Confidential Compute and consider Managed HSM |
| Using the earlier JWT validation preview | #4 | Plan the move to the new centralized policy and watch for the retirement notice |

All of these are previews. Decide on production use after GA and the Learn updates.

## Related updates from the same period (without the Ignite tag)

- GA: WAF Insights for Azure Application Gateway (579280, published November 23, 2026)
- Public preview: Application Gateway for Containers Private ingress (576393), MCP gateway (576388), JWT validation (576382)
- GA: Keyless TLS on Application Gateway with Azure Key Vault Managed HSM (577130)

## Results in the demo environment: Advanced routing and load balancing on a real gateway

- Published: build guide https://koudaiii.com/agw-advanced-routing-demo/ , simulator and Bicep https://github.com/koudaiii/agw-advanced-routing-demo
- Setup: WAF_v2 (capacity 1), 7 Basic listeners (:80 / :8080 / :8090 / :8100 / :8110 / :8120 / :8130), 4 Advanced rules and 3 Basic rules deployed with Bicep
- The Advanced routing CLI commands (`advanced-routing-set` / `advanced-routing-map`) are available in Azure CLI 2.92.0 and later. The demo deploys with Bicep and uses the CLI to check the real gateway
- A 90:10 weighted canary (91 / 9 over 100 requests), a header feature flag (`X-Feature: new`), and priority failover with a 60% minimum healthy percentage worked. The switch took about 2–3 minutes after the primary was stopped
- Header values were case-sensitive (`X-Feature: NEW` went to the default pool)
- Server selection: with 100 requests (6 at a time) to two servers, one of which takes 3 seconds, Round Robin sent about half to the slow server, and Least Connections sent 10 or fewer
- An encoded path (`/api%2Forders`) was evaluated by the Path condition after decoding
- Regular expressions must be RE2-compatible. Lookahead and backreferences are not available

## Sources

Azure Updates (all published November 17, 2026):

- 580428 Public Preview: Next-generation elastic architecture for Azure Application Gateway v2 — https://azure.microsoft.com/updates?id=580428
- 579324 Public Preview: Azure Application Gateway advanced routing rules — https://azure.microsoft.com/updates?id=579324
- 580423 Public Preview: Advanced load balancing in Azure Application Gateway — https://azure.microsoft.com/updates?id=580423
- 580418 Public Preview: Centralized user authentication + JWT validation for Azure Application Gateway — https://azure.microsoft.com/updates?id=580418
- 579649 Public Preview: Azure Application Gateway confidential compute support — https://azure.microsoft.com/updates?id=579649

Microsoft Learn:

- Application Gateway deployment tiers — https://learn.microsoft.com/azure/application-gateway/deployment-tier
- Advanced routing rules — https://learn.microsoft.com/azure/application-gateway/advanced-rules
- Tutorial: Configure header-based routing with Advanced rules — https://learn.microsoft.com/azure/application-gateway/configure-advanced-routing-rule
- Advanced load balancing — https://learn.microsoft.com/azure/application-gateway/advanced-load-balancing
- User authentication — https://learn.microsoft.com/azure/application-gateway/user-authentication
- JWT validation — https://learn.microsoft.com/azure/application-gateway/json-web-token-overview
- Confidential Compute overview — https://learn.microsoft.com/azure/application-gateway/confidential-compute-overview

Product blog:

- Redefining application load balancing in Azure Application Gateway (November 11, 2026) — https://techcommunity.microsoft.com/blog/AzureNetworkingBlog/redefining-application-load-balancing-in-azure-application-gateway/4572687
