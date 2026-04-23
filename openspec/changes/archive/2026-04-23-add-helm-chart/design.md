## Context

The Remnawave Panel ships only as a docker-compose stack ([upstream `docker-compose-prod.yml`](https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml)) consisting of three services:

- `remnawave` — the panel application (image `remnawave/backend:2`), exposing `APP_PORT` (3000) and `METRICS_PORT` (3001), with a `/health` endpoint on the metrics port.
- `remnawave-db` — `postgres:17.6` with a named volume.
- `remnawave-redis` — `valkey:9-alpine`, ephemeral (no AOF, no `save`), reachable from the app over a **Unix socket** in a shared volume mounted at `/var/run/valkey/valkey.sock`.

The panel reads configuration entirely from environment variables (catalogued in [docs/install/environment-variables.md](docs/install/environment-variables.md) and [`.env.sample`](https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample)). Required secrets include `JWT_AUTH_SECRET`, `JWT_API_TOKENS_SECRET`, `POSTGRES_PASSWORD`, `METRICS_PASS`, and (when notifications are enabled) `WEBHOOK_SECRET_HEADER` and `TELEGRAM_BOT_TOKEN`.

This repo (`remnawave-panel`) is the documentation site (Docusaurus) for the Remnawave project; the application source lives at `remnawave/backend`. The chart consumes the upstream image and env-var contract as-is and does not change application behavior.

## Goals / Non-Goals

**Goals:**

- Deploy the panel to a Kubernetes cluster with operational parity to the docker-compose stack: same image, same env-var surface, same `/health` semantics.
- Give operators idiomatic K8s primitives: `Ingress`, Gateway API `HTTPRoute`, `Secret`, `ConfigMap`, `ServiceAccount`, liveness/readiness probes, optional `ServiceMonitor`.
- Support both `Ingress` and Gateway API (`HTTPRoute` + `Gateway`/`GatewayClass` reference) as routing front-ends, mutually exclusive per release, so operators can pick the model their cluster uses without a chart fork.
- Allow bundled Postgres and Valkey/Redis to be disabled in favor of externally-managed instances (managed Postgres, in-cluster Operator-managed instances, etc.).
- Support both convenience (chart-managed Secret from values) and production (`existingSecret` reference) secret-handling patterns.
- Track upstream backend versions through `appVersion`, with the chart `version` following independent SemVer.
- Make the chart's full configuration surface discoverable from `values.yaml` comments and a generated values reference in the docs site.

**Non-Goals:**

- The Remnawave Node, the subscription-page sibling service, and any Remnawave plugins. (May be addressed in follow-up changes.)
- Cluster-level dependencies: cert-manager, ingress controllers, storage provisioners, Prometheus stack. The chart integrates with whatever the cluster already provides.
- A migration tool for moving existing docker-compose deployments to K8s. We document the manual cutover; we do not script it.
- Horizontal Pod Autoscaler templates in v1. Replicas are static; HPA can be layered externally and added to the chart in a follow-up.
- Backups and PITR for the bundled Postgres. Operators wanting backups should disable the bundled DB and use a managed/operator-backed Postgres.

## Decisions

### Chart location: `charts/remnawave-panel/` in this docs repo

This repo already hosts deployment documentation, the install guides users follow, and the existing static install assets. Co-locating the chart keeps docs and chart in lockstep — a chart change can ship with its docs change in a single PR. A future split into a dedicated `remnawave/helm-charts` repo remains possible (the chart is self-contained), but it's a premature step before the chart has any release history. **Alternative considered:** a new `remnawave/helm-charts` repo. Rejected for v1 to keep iteration velocity high.

### Bundle Postgres via the CloudNative-PG `cluster` subchart

The CNPG operator is the emerging standard for production PostgreSQL on Kubernetes: operator-managed `Cluster` CRs provide declarative HA (automatic failover across 3 instances), rolling updates, PITR, and built-in Prometheus metrics — capabilities that StatefulSet-based charts (Bitnami) cannot offer without significant manual scaffolding. The chart bundles the official `cnpg/cluster` Helm chart as a subchart.

**Default configuration:** 3 instances, backups disabled, storage `8Gi`. Operators wanting a lighter footprint can set `cnpg.cluster.instances: 1`. Backups are opt-in via `cnpg.backups.enabled: true` with S3/Azure/GCS provider configuration.

**Prerequisite:** The CNPG operator must be pre-installed in the cluster. The chart documents this requirement, `NOTES.txt` warns on install, and the install guide includes the one-liner (`helm install cnpg cloudnative-pg/cloudnative-pg`). This raises the bar slightly vs. a self-contained subchart, but any team running Kubernetes in production already manages operators, and the operational payoff (HA, automated failover, declarative backups) justifies the dependency.

**Alternatives considered:**

- *Bitnami `postgresql` subchart*: rejected — provides a StatefulSet with no operator-managed failover, no PITR, no declarative backups. Operators wanting HA would need to layer an external tool anyway.
- *Handwritten StatefulSet*: rejected — reimplements features badly.
- *External-only (no bundled DB)*: rejected as default — raises the bar for trying the chart. Kept as a *toggleable* option (`cnpg.enabled: false` + `externalDatabase.url`) for operators who manage Postgres outside the chart.

### Bundle Redis via the DandyDeveloper `redis-ha` subchart

The chart bundles `dandydeveloper/redis-ha` as a subchart, providing a 3-replica Redis StatefulSet with Sentinel sidecars for automatic failover and HAProxy for a stable single-endpoint connection. This gives Kubernetes-native HA without requiring the Remnawave backend to be Sentinel-aware.

**Default configuration:** 3 replicas, Sentinel quorum 2, HAProxy enabled, persistence enabled (`10Gi`). Redis config overrides upstream's ephemeral defaults where appropriate for K8s HA: persistence is on (PVC-backed, survives Pod restarts), but `maxmemory-policy` remains `noeviction` to match upstream intent.

**HAProxy:** Enabled by default. The Remnawave backend connects to a single `redis-ha-haproxy` Service on port 6379 — no Sentinel-aware client needed. HAProxy routes writes to master and can optionally expose a read-only port (6380) for read replicas.

**Why persistence is on:** Unlike the compose stack where Redis is co-located and restarts are rare, K8s Pods are rescheduled routinely (node drains, rolling updates, spot preemption). Persistence avoids a full cache miss on every Pod reschedule, reducing thundering-herd pressure on Postgres after routine cluster operations.

**Toggleable:** `redis-ha.enabled: false` + `externalRedis.host` / `externalRedis.port` for operators who manage Redis externally.

**Alternatives considered:**

- *Handwritten single-replica Deployment (ephemeral)*: rejected — no failover, cache lost on every reschedule, insufficient for production K8s.
- *Bitnami `valkey`/`redis` subchart*: rejected — heavier values surface than redis-ha for equivalent functionality, and redis-ha's Sentinel+HAProxy topology is a better fit for non-Sentinel-aware clients.

### Redis transport: TCP via HAProxy (no Unix socket option)

Shared volumes in Kubernetes only work *within* a Pod, not between Pods. The compose stack's `valkey-socket` shared volume cannot be replicated across separate Pods. Upstream's `.env.sample` already documents `REDIS_HOST` / `REDIS_PORT` as alternatives to `REDIS_SOCKET`, so this is a supported configuration. The chart sets `REDIS_HOST` to the HAProxy Service and `REDIS_PORT` to `6379`, explicitly omitting `REDIS_SOCKET`. HAProxy handles master discovery transparently — the backend sees a single stable TCP endpoint. **Alternative considered:** co-locate app + valkey in the same Pod with an `emptyDir` shared mount. Rejected — couples scaling, surprising in K8s, no upside.

### Two-track secret strategy: chart-managed Secret OR `existingSecret`

Convenience path: users put values in `values.yaml`; the chart renders a `Secret`. Production path: users create a `Secret` themselves (manually, via External Secrets Operator, sealed-secrets, etc.) and set `existingSecret: my-secret`. The chart wires `envFrom` against either source. This mirrors the Bitnami convention and makes the chart compatible with GitOps workflows that refuse to render plaintext secrets. Secret keys are documented in `values.yaml` so operators know what their `existingSecret` must contain.

### Configuration delivery: split ConfigMap + Secret, both via `envFrom`

Non-sensitive env (ports, domains, feature flags, notification thresholds) goes into a `ConfigMap`. Sensitive env (JWT secrets, DB password, metrics password, webhook secret, Telegram token) goes into a `Secret`. Both are mounted on the container with `envFrom`. **Why split:** ops can run `kubectl describe configmap` to inspect non-sensitive config without permissions on the Secret, and secret-store integrations (ESO, Vault) work cleanly when secrets live in their own object. **Trade-off:** two objects instead of one — accepted.

### Pod restarts on config/secret change via checksum annotations

Kubernetes does not restart Pods when a `ConfigMap` or `Secret` changes. The chart adds `checksum/config` and `checksum/secret` pod-template annotations computed from the rendered manifests, so a `helm upgrade` rolls Pods whenever config drifts. **Alternative considered:** require a third-party reloader (e.g., Stakater Reloader). Rejected — adds a cluster dependency for no real gain.

### `SUB_PUBLIC_DOMAIN` derivation

`SUB_PUBLIC_DOMAIN` must be set for the panel to function (per upstream docs). The chart accepts an explicit `subscription.publicDomain` value, but if empty derives it from the active routing front-end:

1. If `ingress.enabled` and `ingress.hosts[0].host` is set → `<host>/api/sub`.
2. Else if `gateway.enabled` and `gateway.hostnames[0]` is set → `<hostname>/api/sub`.
3. Else fail rendering with a clear template error.

The path suffix is overridable via `subscription.publicPath` (default `/api/sub`). This avoids the most common config mistake while letting advanced users override.

### Routing front-end: `Ingress` and Gateway API, mutually exclusive

The chart ships templates for both an `Ingress` resource and Gateway API resources (`HTTPRoute`, optionally a chart-managed `Gateway` referencing an existing `GatewayClass`). Exactly one is enabled at a time — `ingress.enabled` and `gateway.enabled` cannot both be true; the chart's `values.schema.json` enforces this and `helm template` fails fast otherwise. **Why both:** Gateway API is the K8s-blessed successor to `Ingress`, but adoption is uneven — many production clusters still standardize on `Ingress` with cluster-specific controllers (nginx, Traefik, AWS ALB), while newer GitOps shops are moving to Gateway API with Istio/Cilium/Envoy Gateway. A chart fork per model would be a maintenance burden; a values toggle keeps both first-class. **Why mutually exclusive:** routing the same Service through two front-ends simultaneously creates surprising precedence and TLS-cert duplication. Operators wanting both can run two `helm install` releases. **Alternative considered:** Gateway API only. Rejected — locks out the majority of clusters that still depend on `Ingress`. **Alternative considered:** ship both as siblings (both enabled simultaneously). Rejected for the precedence/TLS reasons above.

The `HTTPRoute` references a `parentRef` (Gateway) the operator already owns; the chart does not manage `GatewayClass` and only optionally manages `Gateway` (gated on `gateway.createGateway`, default `false`) since cluster-shared Gateways are the norm.

### Scaling: `replicaCount` is the K8s-native lever; `API_INSTANCES` stays at 1

Upstream's `API_INSTANCES` is in-process clustering (one Pod, multiple Node.js workers). On Kubernetes, the idiomatic scaling unit is the Pod. The chart defaults to `replicaCount: 1` and `API_INSTANCES=1`, and recommends increasing `replicaCount` rather than `API_INSTANCES`. Both can be combined for users who want to maximize per-Pod CPU utilization. Document that horizontal scaling relies on Redis being shared (already true).

### Probes: both probes hit `/health` on `METRICS_PORT`

Upstream's docker-compose healthcheck uses this exact endpoint, so liveness and readiness reuse it. **Trade-off:** if `/health` is "shallow" (200 even when DB is unreachable), readiness will succeed on a broken Pod. We accept this for v1 and revisit if the endpoint's behavior is clarified or extended upstream.

### Versioning policy

- `Chart.yaml.appVersion` tracks the upstream backend image major: `"2"` initially, bumped when the panel image moves to `3`.
- `Chart.yaml.version` follows independent SemVer for chart changes.
- The `image.tag` value defaults to `appVersion` (`"2"`), pinning users to the upstream major while still receiving image updates within the major.
- **Trade-off:** users get implicit upstream patch updates (matches docker-compose behavior — `image: remnawave/backend:2`). Operators wanting strict pinning override `image.tag` to a digest.

### Publishing: GitHub Container Registry (OCI)

OCI is the modern Helm distribution standard, requires no separate `gh-pages` index, and integrates cleanly with `helm install oci://...`. **Open question:** whether to also publish a classic HTTP repo (`gh-pages`) for users on Helm < 3.8. Defer until there's user demand.

### Observability: opt-in `ServiceMonitor`

Gated on `metrics.serviceMonitor.enabled`. Requires the Prometheus Operator CRD; no fallback. PrometheusRule (alerts) is out of scope until upstream publishes a canonical rule set. Basic-auth credentials for Prometheus scraping come from the same `Secret` that holds `METRICS_USER` / `METRICS_PASS`.

### Out: separate Service for metrics

The app exposes app traffic on `APP_PORT` and metrics on `METRICS_PORT` from the same Pod. The chart creates a single `Service` with two ports rather than two Services — simpler, matches the Pod model, and `ServiceMonitor` can target by port name.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| `/health` semantics may be shallow (returns 200 even when DB is down), causing readiness to lie. | Accept for v1. Document the assumption. Revisit if upstream clarifies or if operators report flapping. |
| CNPG operator must be pre-installed — chart is not self-contained for Postgres. | Document the prerequisite prominently. `NOTES.txt` warns on install. Install guide includes the operator install command. `cnpg.enabled: false` + `externalDatabase.url` as escape hatch. |
| CNPG `cluster` chart is "under active development" per upstream — breaking changes possible. | Pin to a specific chart version in `Chart.yaml` dependencies. Bump deliberately with documented upgrade notes. |
| Switching Redis from Unix socket to TCP via HAProxy adds network hops (app → HAProxy → Redis master). | Negligible at expected request volumes. HAProxy adds sub-millisecond overhead. Operators with extreme latency requirements can use `redis-ha.enabled: false` and run a co-located Redis. |
| Redis-HA persistence is on by default, diverging from upstream's ephemeral intent. | Intentional for K8s — Pods reschedule routinely and persistence avoids thundering-herd cache misses. Document the rationale. Operators can disable persistence via `redis-ha.persistentVolume.enabled: false`. |
| Secret rotation requires a Pod restart and is not automatic. | Checksum annotations on the Pod template trigger a roll on `helm upgrade`. Operators using ESO/Vault should pair with a reloader if they want auto-rotation without `helm upgrade`. |
| Users who set both `subscription.publicDomain` AND `ingress.hosts[0].host` to mismatched values get a working ingress with broken subscription URLs. | Lint warning in `NOTES.txt` after install if the explicit value diverges from the derived one. No hard error — operators may be intentionally fronting via a CDN. |
| Implicit `image.tag: "2"` pulls a moving target. | Matches upstream compose behavior. Document the digest-pinning escape hatch. |
| Bundled CNPG Postgres with 3 instances consumes more resources than a single-replica setup. | Default is production-oriented. Operators wanting a lighter footprint set `cnpg.cluster.instances: 1`. Document resource expectations. |
| Gateway API CRDs (`gateway.networking.k8s.io/v1`) may be absent on older clusters; rendering `HTTPRoute` will fail at apply time. | The `gateway.enabled` toggle defaults to `false`. `NOTES.txt` warns when Gateway API resources are enabled, listing the required CRD versions. No client-side CRD presence check (would need a custom plugin). |
| Gateway API spec churn between `v1beta1` → `v1` could break older clusters. | Target `gateway.networking.k8s.io/v1` only (stable since K8s 1.31). Document the floor; do not attempt to multi-version the templates. |
| Operator enables both `ingress.enabled` and `gateway.enabled` simultaneously. | `values.schema.json` rejects the combination; `helm template` fails with a clear message before any apply. |

## Migration Plan

This is a *new* chart with no prior version, so there is no in-chart upgrade path to define. Two flows matter:

**1. First-time install**

```
1. helm install remnawave oci://ghcr.io/remnawave/charts/remnawave-panel \
     --namespace remnawave --create-namespace \
     -f values.yaml
2. Verify Pod readiness and visit the Ingress host.
3. Complete first-run admin setup via the panel UI.
```

**2. Migrating from docker-compose to the chart** (documented, not scripted):

```
1. Install the CNPG operator if not already present.
2. Snapshot the existing Postgres (`pg_dump`) from the compose stack.
3. Stop the compose stack to freeze writes.
4. Install the chart with `cnpg.enabled: true`, wait for the CNPG Cluster
   to become ready, then restore the dump into the primary via
   `kubectl exec`. (Or install with `cnpg.enabled: false` and point at a
   managed Postgres restored from the snapshot.)
5. Reuse the existing `JWT_AUTH_SECRET` and `JWT_API_TOKENS_SECRET` values to
   keep existing user sessions and API tokens valid. (If rotated, all sessions
   invalidate — acceptable but disruptive.)
6. `SUB_PUBLIC_DOMAIN` and `PANEL_DOMAIN` must match the new ingress host
   (or the values existing user clients already have configured).
7. Cutover DNS to the new ingress.
8. Redis state is cache-only — no migration needed. Redis-HA will start fresh.
```

**Rollback:** `helm rollback remnawave <revision>` reverts the chart deployment. CNPG Cluster data persists on PVCs across rollbacks. Redis-HA data persists on PVCs across rollbacks. Document that destructive uninstalls require explicit PVC deletion.

## Open Questions

1. **Should the chart be published under `remnawave/charts` on GHCR or under a different OCI namespace?** Affects `helm install` instructions in docs.
2. **Bitnami subchart pinning policy** — pin to exact minor or allow `~` ranges? Recommend exact pin for reproducibility; opens churn cost on bumps.
3. **Should the chart enforce a `securityContext` (non-root, read-only root FS) by default?** Upstream image's behavior under restrictive contexts is unverified. Default to *opt-in* hardening for v1; flip to default-on once verified.
4. **Helm HTTP repo (`gh-pages`) in addition to OCI?** Defer until a user requests it.
5. **Subscription-page service** — same chart (multi-component), separate chart, or follow-up change? Recommendation: follow-up change to keep this proposal scoped.
6. **Resource defaults** — what `requests` / `limits` to ship by default? Upstream docs recommend 2 GB RAM, 2 CPU at minimum. Need to decide between "matches docs minimum" vs. "no defaults, operator must set."
