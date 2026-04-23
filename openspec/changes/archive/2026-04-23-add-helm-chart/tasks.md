## 1. Chart Scaffolding

- [x] 1.1 Create `charts/remnawave-panel/Chart.yaml` with chart metadata, `appVersion: "2"`, independent SemVer `version`, CNPG `cluster` subchart dependency, and DandyDeveloper `redis-ha` subchart dependency
- [x] 1.2 Create `charts/remnawave-panel/values.yaml` with all configuration groups (app ports, scaling, CNPG cluster, external database, redis-ha, external Redis, JWT, domains, subscription, Telegram, webhook, bandwidth notifications, disconnected-user notifications, metrics, probes, ingress, gateway, serviceAccount, resources) — every env var from `.env.sample` addressable, grouped by concern
- [x] 1.3 Create `charts/remnawave-panel/values.schema.json` enforcing type constraints, required fields, and mutual exclusion of `ingress.enabled` + `gateway.enabled`
- [x] 1.4 Create `.helmignore` to exclude non-chart files
- [x] 1.5 Run `helm dependency update` to pull CNPG cluster and redis-ha subchart archives

## 2. Core Workload Templates

- [x] 2.1 Create `templates/deployment.yaml` — panel Deployment referencing the `remnawave/backend` image, two named container ports (app + metrics), `envFrom` for ConfigMap and Secret, checksum annotations for config/secret rotation, configurable `replicaCount`
- [x] 2.2 Create `templates/service.yaml` — single Service with two named ports (app + metrics), configurable `service.type`
- [x] 2.3 Create `templates/serviceaccount.yaml` — opt-in ServiceAccount with configurable annotations
- [x] 2.4 Create `templates/_helpers.tpl` — shared template helpers (fullname, labels, selectors, image reference with tag/digest support)

## 3. Configuration Templates

- [x] 3.1 Create `templates/configmap.yaml` — non-sensitive env vars from values, omitting keys whose values are empty
- [x] 3.2 Create `templates/secret.yaml` — chart-managed Secret (JWT secrets, DB password, metrics password, webhook secret, Telegram token), conditionally rendered only when `existingSecret` is unset; omit empty optional keys
- [x] 3.3 Wire `envFrom` in the Deployment to reference either chart-managed Secret or `existingSecret` by name

## 4. Subscription Domain Derivation

- [x] 4.1 Add template logic to derive `SUB_PUBLIC_DOMAIN` from explicit value, or from `ingress.hosts[0].host` / `gateway.hostnames[0]` + configurable path suffix (`/api/sub` default)
- [x] 4.2 Add `fail` guard when no explicit value and no routing host is derivable

## 5. Routing Front-End Templates

- [x] 5.1 Create `templates/ingress.yaml` — standard Ingress resource gated on `ingress.enabled`, supporting TLS, annotations, and `ingressClassName`
- [x] 5.2 Create `templates/httproute.yaml` — Gateway API `HTTPRoute` (`gateway.networking.k8s.io/v1`) gated on `gateway.enabled`, with `parentRefs` to operator-owned Gateway
- [x] 5.3 Create `templates/gateway.yaml` — optional chart-managed Gateway resource gated on `gateway.createGateway`, referencing an existing `GatewayClass`
- [x] 5.4 Add mutual-exclusion validation template that fails rendering when both `ingress.enabled` and `gateway.enabled` are true

## 6. Health Probes

- [x] 6.1 Add liveness and readiness HTTP GET probes to the Deployment targeting `/health` on the metrics port, with overridable timing parameters

## 7. Bundled Postgres (CNPG Cluster Subchart)

- [x] 7.1 Configure CNPG `cluster` subchart defaults under `cnpg.*` in `values.yaml`: 3 instances, `8Gi` storage, backups disabled, database name and credentials
- [x] 7.2 Add template logic to construct `DATABASE_URL` from CNPG Cluster read-write Service when `cnpg.enabled: true`, or from `externalDatabase.url` when disabled
- [x] 7.3 Add `NOTES.txt` warning about CNPG operator prerequisite with install instructions

## 8. Bundled Redis (redis-ha Subchart)

- [x] 8.1 Configure `redis-ha` subchart defaults under `redis-ha.*` in `values.yaml`: 3 replicas, HAProxy enabled, persistence enabled (`10Gi`), `maxmemory-policy noeviction`
- [x] 8.2 Add template logic to set `REDIS_HOST` / `REDIS_PORT` from HAProxy Service when `redis-ha.enabled: true`, or from `externalRedis.host` / `externalRedis.port` when disabled; never emit `REDIS_SOCKET`

## 9. Observability

- [x] 9.1 Create `templates/servicemonitor.yaml` — Prometheus Operator `ServiceMonitor` gated on `metrics.serviceMonitor.enabled`, scraping the metrics port at `/metrics` with basic-auth from the panel Secret

## 10. Post-Install Notes and Lint

- [x] 10.1 Create `templates/NOTES.txt` with install summary, access instructions, and lint warnings (mismatched `subscription.publicDomain` vs ingress host, Gateway API CRD reminder)
- [x] 10.2 Verify `helm lint` and `helm template` pass with default values
- [x] 10.3 Verify `helm template` fails with clear error when both `ingress.enabled` and `gateway.enabled` are true

## 11. Documentation

- [x] 11.1 Add Helm install guide under `docs/install/` covering fresh install, values reference, and docker-compose migration steps
