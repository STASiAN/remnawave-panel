## Context

The `remnawave/subscription-page` service is the branded, localized HTML front-end that renders the subscription links the panel issues. The panel's own `/api/sub` endpoint serves raw subscription data for client apps, but user-facing subscription links point at the subscription-page. Upstream docker-compose users install it one of two ways:

- **Bundled** — same host as the panel, shared docker network, reached on its own subdomain via the reverse proxy ([docs/install/subscription-page/bundled.md](docs/install/subscription-page/bundled.md)).
- **Separate server** — different host entirely, panel reached over the public URL with an API token ([docs/install/subscription-page/separate-server.md](docs/install/subscription-page/separate-server.md)).

The subscription-page container is a small Node.js app that:

- Listens on `APP_PORT` (default `3010`).
- Calls the panel via `REMNAWAVE_PANEL_URL` with `REMNAWAVE_API_TOKEN` as bearer auth.
- Optionally supports `CUSTOM_SUB_PREFIX` (sub-path mode), `MARZBAN_LEGACY_LINK_ENABLED` + `MARZBAN_LEGACY_SECRET_KEY` (Marzban migration), and `CADDY_AUTH_API_TOKEN` (for the Caddy-with-security addon).

The existing chart (see [charts/remnawave-panel/](charts/remnawave-panel/)) ships a panel `Deployment`, `ConfigMap`, `Secret`, `Service`, opt-in `Ingress` / `HTTPRoute`, and derives `SUB_PUBLIC_DOMAIN` from the active routing front-end's host. The archived chart proposal explicitly deferred the subscription-page to a follow-up change — this is that change.

## Goals / Non-Goals

**Goals:**

- Map the bundled-on-same-host docker-compose topology to an idiomatic Kubernetes shape, with minimal new values surface.
- Keep the subscription-page strictly opt-in so existing chart users see zero behavioral change on upgrade.
- Expose the same env-var configuration as the upstream image, with secrets flowing through the chart's existing two-track (`chart-managed Secret` OR `existingSecret`) pattern.
- Make the public URL story coherent: `SUB_PUBLIC_DOMAIN` must resolve to wherever the subscription-page is actually reachable from users, not the panel.
- Fit the existing routing front-end model: `Ingress` XOR Gateway API, with the subscription-page getting its own host/hostname that shares the same front-end choice as the panel.

**Non-Goals:**

- Separate-server topology (subscription-page on a different cluster or a standalone chart). Operators who need that can run a second chart release or a dedicated chart; this change targets the bundled case only.
- HPA for the subscription-page. Scales with `replicaCount` as a sidecar; independent scaling is a later concern.
- Scripting migration from a compose-bundled subscription-page to the chart. Document the manual cutover (API token stays the same, DNS moves to the new ingress host).
- Managing the `REMNAWAVE_API_TOKEN` lifecycle (generation, rotation). Users generate it via the panel UI; the chart just plumbs it through.

## Decisions

### Topology: sidecar in the panel Pod, not a separate Deployment

The subscription-page runs as a second container inside the panel Pod. Rationale:

- **Matches the "bundled" compose topology.** Upstream's bundled install puts both services on the same host and same network. In K8s, the closest analog is same-Pod, same-netns.
- **Eliminates a Service for panel discovery.** The subscription-page calls `http://localhost:<APP_PORT>` — no DNS, no ClusterIP, no mTLS concerns between sibling services. `REMNAWAVE_PANEL_URL` defaults to `http://localhost:3000`.
- **Simpler values surface.** One fewer workload means no second `Deployment` block to parametrize (`replicaCount`, probes, resources, etc.).
- **Lifecycle coupling is acceptable here.** The subscription-page is stateless and its only job is to render pages from panel data — if the panel is down, the subscription-page has nothing to serve anyway. Having them restart together is a feature, not a bug.

**Alternatives considered:**

- *Separate `Deployment` + `Service`*. More K8s-idiomatic in the abstract, and the right answer if the subscription-page needed independent scaling. Rejected for v1: the coupled-scaling concern is theoretical (the subscription-page is cheap and its request rate tracks the panel's), the extra workload + Service + RBAC surface is real, and a future change can split them if pressure materializes. Upgrade path: flip a single `Deployment` block into two, keep the same values keys under `subscription.*`.
- *Separate chart (`remnawave-subscription-page`)*. Rejected: the bundled case is by far the common case in the compose docs, and forcing two `helm install` invocations for it adds friction without payoff. A dedicated separate-server chart is a future option if demand appears.

### Container image, tag, and digest follow the panel's image pattern

A new `subscription.image.{repository,tag,digest,pullPolicy}` block mirrors the existing `image.*` shape. Default `repository: remnawave/subscription-page`, default `tag: ""` (empty → resolves via helpers to `appVersion` of a dedicated subscription-page version stanza, or falls back to `"latest"` in v1 since upstream doesn't publish a stable major tag for the subscription-page). **Trade-off:** `latest` drift is real; document the digest-pinning escape hatch and revisit once upstream publishes major-pinned tags.

### Config split: new subscription keys in the existing ConfigMap/Secret, distinguished by name

Non-sensitive subscription-page env (`APP_PORT`, `REMNAWAVE_PANEL_URL`, `CUSTOM_SUB_PREFIX`, `MARZBAN_LEGACY_LINK_ENABLED`) goes into the existing panel `ConfigMap`. Sensitive keys (`REMNAWAVE_API_TOKEN`, `MARZBAN_LEGACY_SECRET_KEY`, `CADDY_AUTH_API_TOKEN`) go into the existing chart-managed `Secret`, or must be provided by `existingSecret` when `subscription.enabled: true`.

**Why not a dedicated ConfigMap/Secret per sidecar?** The panel and subscription-page share a Pod, so their env is scoped to the same Pod anyway. Two objects per side doubles the API surface without adding isolation. The subscription-page container gets its env via `envFrom` selecting the same `ConfigMap` and `Secret` — harmless, because panel env keys don't collide with subscription-page env keys (different prefixes: `REMNAWAVE_*` / `CUSTOM_SUB_PREFIX` / `MARZBAN_LEGACY_*` / `CADDY_AUTH_API_TOKEN` / the subscription-page's `APP_PORT`).

**Wait — `APP_PORT` DOES collide.** Both containers read `APP_PORT` from env, and the panel uses `3000` while the subscription-page uses `3010`. To avoid the collision, the subscription-page container gets `APP_PORT` via a direct `env:` entry (from `.Values.subscription.port`) rather than `envFrom`, taking precedence over any `ConfigMap` value. The `ConfigMap` continues to carry the panel's `APP_PORT` unchanged. This is the only collision and it's handled at the container-level env-merge layer — no new ConfigMap needed.

**Alternative considered:** rename the subscription-page's port value to a non-colliding key and patch upstream. Rejected — changes upstream contract.

**Checksum annotations** extend cleanly: `checksum/config` and `checksum/secret` already cover the full rendered object, so adding subscription keys automatically triggers pod restarts on change. No new annotations needed.

### Service: add a third named port (`subscription`) on the existing Service

The panel `Service` already carries `http` + `metrics` as named ports. Add `subscription` as a third named port targeting `containerPort: 3010` on the sidecar. Rationale:

- Single Service keeps the selectors aligned (both containers live in the same Pod, same labels).
- Named ports on the existing `Service` mean `HTTPRoute.backendRefs` and `Ingress.backend` can address them unambiguously.
- No new `ServiceAccount` or selector concerns.

**Alternative considered:** a dedicated `Service` for the subscription-page. Rejected — single Pod, single selector, the Service split adds no benefit and makes subscription-specific Service annotations (e.g., for an ALB) harder to reason about.

### Routing: separate subscription host/route, sharing the same front-end choice

The subscription-page needs its own public URL distinct from the panel. The chart adds `subscription.ingress.hosts` (mirrors `ingress.hosts`) and `subscription.gateway.hostnames` (mirrors `gateway.hostnames`). When `subscription.enabled: true`:

- If `ingress.enabled: true` → the `Ingress` resource carries an additional rule for the subscription host, with its backend set to the `subscription` named port.
- If `gateway.enabled: true` → a second `HTTPRoute` is rendered for the subscription hostname, with `backendRefs` targeting the `subscription` named port. Same `parentRef(s)` as the panel `HTTPRoute` unless overridden.

**Why in the same `Ingress` / coexisting `HTTPRoute` rather than forcing a second release?** Operators already accept the mutual-exclusion constraint (`Ingress` XOR Gateway) for the whole release; extending the chosen front-end to cover both panel and subscription hosts is the lowest-friction model. The existing mutual-exclusion validation gate stays unchanged.

**Alternative considered:** require a second `helm install` for the subscription-page ingress. Rejected — couples the chart's front-end choice with deployment topology awkwardly, and operators would then need to duplicate TLS cert references.

### `SUB_PUBLIC_DOMAIN` derivation: prefer subscription host when the sidecar is enabled

Today's derivation order is: explicit `subscription.publicDomain` → panel ingress host → panel gateway hostname → fail. The new order when `subscription.enabled: true`:

1. Explicit `subscription.publicDomain` (unchanged — still highest precedence).
2. `subscription.ingress.hosts[0].host` + `subscription.publicPath` (default `/`, since the subscription-page serves on root, not `/api/sub`).
3. `subscription.gateway.hostnames[0]` + `subscription.publicPath`.
4. Fallback to the old behavior (panel host + `/api/sub`) is suppressed — if the sidecar is enabled without a subscription host or explicit publicDomain, rendering fails with a clear error.

When `subscription.enabled: false`, derivation is exactly today's behavior. This preserves backward compatibility for chart users who point `SUB_PUBLIC_DOMAIN` at the panel's own `/api/sub` endpoint.

**Default `subscription.publicPath`:** changes from `/api/sub` to empty string when the sidecar is enabled, because the subscription-page serves on the root of its host. Operators using `CUSTOM_SUB_PREFIX=sub` should set `subscription.publicPath: /sub` to match.

**Note on `subscription.publicPath` semantics:** the existing key's meaning is slightly different between modes. In sidecar mode it is the path the subscription-page is served under (matching `CUSTOM_SUB_PREFIX`). In non-sidecar mode it remains the path suffix appended to the panel host (default `/api/sub`). Documented explicitly; no rename (would churn the existing chart's contract).

### Probes for the subscription-page sidecar

The subscription-page does not document a `/health` endpoint. Use a `tcpSocket` probe against `APP_PORT` for liveness and readiness by default, with the same override surface (`subscription.probes.*`) as the panel. **Trade-off:** TCP probes only confirm the port is bound; they will not detect app-level hangs. Acceptable for v1 — the subscription-page is simple enough that a port-bound process is nearly always healthy. Document that an HTTP probe can be set via `subscription.probes.liveness.httpGet` override if upstream adds a health endpoint later.

### Secret contract when `existingSecret` is used

When `existingSecret` is set and `subscription.enabled: true`, the named `Secret` MUST additionally contain `REMNAWAVE_API_TOKEN`. If `subscription.marzbanLegacy.enabled: true`, it MUST also contain `MARZBAN_LEGACY_SECRET_KEY`. If `subscription.caddyAuthApiToken` is not empty, the operator instead puts it in `existingSecret` under the key `CADDY_AUTH_API_TOKEN`. The chart's `values.yaml` documents the full key set, continuing the pattern from the existing `existingSecret` contract.

The chart does not fail-fast at render time when `existingSecret` lacks these keys — the panel pod would crash-loop with a clear upstream error. `NOTES.txt` lists the required keys on install so operators see the expected contract.

### Deployment container ordering and startup

The sidecar is declared after the panel container in the Pod spec. Kubernetes does not guarantee startup order without init containers or the native sidecars feature (`restartPolicy: Always` on init containers). Two options:

- **Simple approach (chosen):** both containers start in parallel. The subscription-page's initial calls to `http://localhost:3000` may fail until the panel is ready; it retries at the app layer (it's a stateless client that retries each incoming request). Readiness gating on the Pod uses the panel's readiness probe — the Pod is "Ready" only when the panel is healthy, so external traffic is not routed to the subscription-page port until the panel is up.
- **Native sidecars (deferred):** set the subscription-page as a `restartPolicy: Always` init container to guarantee panel-first startup. Rejected for v1: requires K8s 1.29+ as stable, adds template complexity, and the parallel-start failure mode is self-healing within seconds.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Sidecar coupling: subscription-page scales 1:1 with panel, wasting resources under light subscription traffic. | Subscription-page is tiny (Node.js app serving static renders). Resource requests default to low values (`50m` CPU, `128Mi` memory). Operators can set `subscription.resources` for tighter tuning. Revisit if operational data shows meaningful waste. |
| Sidecar coupling: heavy subscription-page load takes the panel Pod's CPU down with it. | Set separate `subscription.resources.requests/limits` to cap the sidecar. Document that operators expecting high subscription-page RPS should either crank `replicaCount` or migrate to a separate Deployment in a follow-up. |
| `APP_PORT` collision between panel and subscription-page via shared `ConfigMap`. | Handled: subscription-page container overrides `APP_PORT` via a direct `env:` entry (higher precedence than `envFrom`). Regression test: `helm template` asserts the sidecar container's `APP_PORT` resolves to `subscription.port` (`3010`). |
| Subscription-page tag defaults to `latest` — implicit upstream drift. | Document digest-pinning. Revisit when upstream publishes major-pinned tags. A values comment flags the caveat. |
| Subscription-page lacks a `/health` endpoint; TCP probes may mask app-level hangs. | Accepted for v1. Values surface allows operators to override to an HTTP probe if/when upstream adds one. |
| Existing chart users upgrading pick up subscription values keys by accident. | `subscription.enabled: false` default keeps behavior identical. The new `subscription.*` block is additive. Upgrade notes in `NOTES.txt`/CHANGELOG. |
| Routing: operators configuring `subscription.ingress.hosts` without also enabling `ingress.enabled` see nothing routed. | Render-time validation: fail fast when `subscription.enabled: true` and neither `ingress.enabled` nor `gateway.enabled` is true (no way to reach the subscription-page from outside the cluster). |
| `SUB_PUBLIC_DOMAIN` derivation change is a behavior change for users who enable `subscription.*`. | Tightly gated on `subscription.enabled: true` — users not enabling the sidecar see zero change. Explicit `subscription.publicDomain` still wins at the top of the precedence chain. |
| `existingSecret` users don't realize they need to add `REMNAWAVE_API_TOKEN` when enabling the sidecar. | `NOTES.txt` lists required keys. `values.yaml` comment under `existingSecret` enumerates the full contract. Pod will crash-loop with a clear error if missing — failure mode is loud, not silent. |
| Native sidecars (`restartPolicy: Always` init containers) are the "right" K8s pattern for a follower process, but we skip them. | Document the decision. The practical impact is small (seconds of 5xx on cold start until the panel is ready), and readiness-gated Service routing already prevents external traffic from hitting a not-yet-ready Pod. Revisit if users report slow-start issues in production. |

## Migration Plan

This is an additive change to an existing chart. Two flows:

**1. New install enabling the sidecar:**

```
1. helm install remnawave oci://ghcr.io/remnawave/charts/remnawave-panel \
     --namespace remnawave --create-namespace \
     -f values.yaml  # with subscription.enabled: true, subscription.apiToken, subscription.ingress.hosts set
2. After first-run admin setup, generate an API token in the panel UI.
3. Update the release with the generated token (helm upgrade ... --set subscription.apiToken=...
   or update existingSecret) — pod rolls automatically via checksum annotation.
4. Verify subscription.example.com renders a test subscription link.
```

**2. Existing chart release migrating off a compose-bundled subscription-page:**

```
1. Preserve the existing REMNAWAVE_API_TOKEN from the compose .env (avoids
   re-minting and breaking issued subscription links that clients have cached).
2. helm upgrade with subscription.enabled: true, subscription.ingress.hosts set
   to the same subscription hostname already serving traffic, subscription.apiToken
   set to the preserved token.
3. Cut over DNS from the compose stack to the chart's ingress.
4. Stop the compose subscription-page container.
```

**Rollback:** `helm rollback` reverts the sidecar. The chart-managed `Secret` rolls back with it; `existingSecret` is unchanged (operators control it).

## Open Questions

1. **Should `subscription.publicPath` default to `""` when `subscription.enabled: true` and `/api/sub` otherwise?** Current design: yes, with a values comment explaining the two meanings. Alternative: introduce a separate key to avoid the semantic overload. The rename is cleaner but churns the contract — defer unless surprising in practice.
2. **Native sidecars (`restartPolicy: Always` init containers)?** K8s 1.29+ stable. If the user base's min-supported K8s version is ≥ 1.29, prefer native sidecars. Defer until chart has a stated min-K8s version.
3. **Should we render a `PodDisruptionBudget` for the panel Pod once the sidecar makes the Pod more valuable?** Out of scope for this change; consider in a follow-up that adds PDB coverage across all workloads.
4. **`image.tag` default for the subscription-page**: `latest` is dangerous, but upstream doesn't publish a stable major. Recommendation: pin to a specific `vX.Y.Z` in chart values with a CI bot bumping it, and document that operators must update deliberately. Decision deferred to implementation.
