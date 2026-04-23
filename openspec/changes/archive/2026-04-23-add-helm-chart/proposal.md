## Why

Remnawave Panel ships only a docker-compose deployment path, which forces Kubernetes operators to either run it outside their cluster, hand-roll manifests, or fork the upstream stack. A first-class Helm chart lets K8s teams deploy the panel using the tooling they already have — GitOps controllers, external secret managers, ingress controllers, service meshes, and Prometheus-based observability — without giving up parity with the supported docker-compose configuration.

## What Changes

- Add a Helm chart that deploys the Remnawave Panel (`remnawave/backend:2`) on Kubernetes.
- Surface the panel's full environment-variable configuration through `values.yaml`, grouped by concern (database, Redis, JWT secrets, domains, Telegram/webhook notifications, metrics, miscellaneous tuning).
- Bundle optional dependencies as toggleable subcomponents: Postgres (StatefulSet + PVC) and Valkey/Redis (Deployment, ephemeral). Both default to enabled but can be disabled in favor of externally-managed instances.
- **BREAKING vs. compose**: switch Redis transport from the compose stack's Unix socket (`REDIS_SOCKET=/var/run/valkey/valkey.sock`, shared volume) to TCP (`REDIS_HOST` / `REDIS_PORT`). Required because shared volumes do not work across separate Pods in Kubernetes. The upstream backend already supports TCP via existing env vars.
- Provide Kubernetes-native primitives: routing front-end via either `Ingress` or Gateway API `HTTPRoute` (mutually exclusive, with `SUB_PUBLIC_DOMAIN` derivable from the active host), `Service`, `ServiceAccount`, liveness/readiness probes against the existing `/health` endpoint on `METRICS_PORT`, and an optional `ServiceMonitor` for Prometheus.
- Support secret injection via either chart-managed `Secret` objects or a user-supplied `existingSecret` reference, so JWT keys and the Postgres password do not need to live in `values.yaml`.
- Add an install guide for the chart under [docs/install/](docs/install/) alongside the existing docker-compose instructions.

## Capabilities

### New Capabilities

- `helm-chart`: A Helm chart that deploys Remnawave Panel on Kubernetes with operational parity to the docker-compose stack, adapted to Kubernetes primitives. Defines the chart's resource surface, configuration values, secret-handling contract, dependency-bundling behavior, upgrade semantics, and version-tracking policy relative to the upstream backend image.

### Modified Capabilities

None. No specs currently exist under [openspec/specs/](openspec/specs/).

## Impact

- **New code**: A new chart directory (location decided in `design.md` — likely `charts/remnawave-panel/` in this repo, but a separate `remnawave/helm-charts` repo is on the table).
- **New docs**: An install guide under [docs/install/](docs/install/) and likely a values-reference page generated from chart metadata.
- **No changes to the backend**: The upstream `remnawave/backend` image and its env-var contract are consumed as-is. No app code changes required.
- **No changes to the compose stack**: The existing docker-compose deployment continues to use the Unix-socket Redis configuration unchanged. Chart users get TCP; compose users do not regress.
- **Release pipeline**: A publishing target (OCI registry or `gh-pages`-hosted Helm repo) and a chart-version policy tied to the backend `appVersion` will be needed — scope and ownership are deferred to `design.md`.
- **Out of scope for this change**: the subscription-page sibling service, the Remnawave Node, and any cluster-level concerns (cert-manager, ingress controllers, storage classes) — the chart will integrate with whatever the cluster already provides.
