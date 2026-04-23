## ADDED Requirements

### Requirement: Panel Deployment

The chart SHALL deploy the Remnawave Panel as a Kubernetes `Deployment` running the upstream `remnawave/backend` image, with the application reachable in-cluster via a `Service`.

#### Scenario: Default install renders required workload resources

- **WHEN** `helm template <release> .` is executed against default values
- **THEN** the rendered output contains exactly one `Deployment` named after the release and a `Service` selecting that `Deployment`'s pods
- **AND** the `Deployment`'s pod template references the `remnawave/backend` image

#### Scenario: Container exposes app and metrics ports

- **WHEN** the chart is rendered with default values
- **THEN** the panel container declares two named container ports corresponding to `APP_PORT` and `METRICS_PORT`
- **AND** the `Service` exposes both ports by the same names

### Requirement: Image Sourcing and Version Tracking

The chart's `appVersion` SHALL track the upstream Remnawave backend image major version, and the default container image tag SHALL match `appVersion` so that operators receive upstream patch updates within the pinned major unless they override.

#### Scenario: Default image tag matches appVersion

- **WHEN** the chart is rendered with default values
- **THEN** the panel container's image reference resolves to `remnawave/backend:<appVersion>`

#### Scenario: Operator overrides image tag

- **WHEN** the chart is rendered with `--set image.tag=2.5.1`
- **THEN** the panel container's image reference resolves to `remnawave/backend:2.5.1`
- **AND** the rendered output is not affected by `appVersion`

#### Scenario: Operator pins image by digest

- **WHEN** the chart is rendered with `--set image.digest=sha256:abc...`
- **THEN** the panel container's image reference includes the digest and excludes the tag

### Requirement: Configuration Surface

The chart SHALL expose every environment variable documented in the upstream Remnawave Panel `.env.sample` and [docs/install/environment-variables.md](docs/install/environment-variables.md) as a configurable value, grouped by concern in `values.yaml`.

#### Scenario: All documented env vars are addressable

- **WHEN** an operator inspects `values.yaml`
- **THEN** every variable from these groups is settable: app ports, API scaling, database, Redis, JWT secrets, domains, documentation toggles, Prometheus metrics, Telegram notifications, webhook, bandwidth-usage notifications, not-connected-users notifications, miscellaneous tuning

#### Scenario: Unset optional env vars do not appear in container env

- **WHEN** an optional env var (for example `TELEGRAM_BOT_TOKEN`) is left empty in values
- **THEN** the rendered `ConfigMap` and `Secret` omit that key entirely rather than emitting an empty string

### Requirement: Two-Track Secret Handling

The chart SHALL support two mutually exclusive sources for sensitive configuration: a chart-managed `Secret` rendered from values, or an operator-supplied `existingSecret` referenced by name.

#### Scenario: Chart-managed Secret is rendered when existingSecret is unset

- **WHEN** the chart is rendered with `jwt.authSecret`, `jwt.apiTokensSecret`, `metrics.password`, and (if applicable) `webhook.secretHeader` and `telegram.botToken` provided in values, and `existingSecret` unset
- **THEN** the rendered output contains a `Secret` whose data fields correspond to those values
- **AND** the panel container's `envFrom` references this rendered `Secret`

#### Scenario: Existing Secret is referenced when set

- **WHEN** the chart is rendered with `existingSecret: my-prebuilt-secret`
- **THEN** the rendered output contains no chart-managed `Secret` for panel credentials
- **AND** the panel container's `envFrom` references `my-prebuilt-secret`

#### Scenario: Required secret keys are documented

- **WHEN** an operator inspects `values.yaml`
- **THEN** the documentation enumerates the exact keys an `existingSecret` must provide (`JWT_AUTH_SECRET`, `JWT_API_TOKENS_SECRET`, `METRICS_PASS`, `POSTGRES_PASSWORD` when bundled DB is enabled, `WEBHOOK_SECRET_HEADER` when webhooks are enabled, `TELEGRAM_BOT_TOKEN` when Telegram is enabled)

### Requirement: Configuration Rotation via Pod Template Annotations

The chart SHALL annotate the panel `Deployment`'s pod template with checksums of the rendered `ConfigMap` and `Secret`, so that `helm upgrade` rolls pods whenever non-image configuration changes.

#### Scenario: ConfigMap content change forces a rolling update

- **WHEN** any non-secret configuration value changes between two `helm template` invocations
- **THEN** the pod template's `checksum/config` annotation differs between the two outputs

#### Scenario: Secret content change forces a rolling update

- **WHEN** any value contributing to the chart-managed `Secret` changes between two `helm template` invocations
- **THEN** the pod template's `checksum/secret` annotation differs between the two outputs

### Requirement: Routing Front-End

The chart SHALL provide an HTTP routing front-end via either a Kubernetes `Ingress` resource or a Gateway API `HTTPRoute` resource, and SHALL reject configurations that enable both simultaneously.

#### Scenario: Ingress mode renders an Ingress resource

- **WHEN** the chart is rendered with `ingress.enabled: true` and `gateway.enabled: false`
- **THEN** the rendered output contains an `Ingress` whose backend points to the panel `Service` on the app port
- **AND** the rendered output contains no `HTTPRoute`

#### Scenario: Gateway mode renders an HTTPRoute resource

- **WHEN** the chart is rendered with `gateway.enabled: true` and `ingress.enabled: false`
- **THEN** the rendered output contains an `HTTPRoute` (apiVersion `gateway.networking.k8s.io/v1`) whose `backendRefs` point to the panel `Service` on the app port
- **AND** the rendered output contains no `Ingress`

#### Scenario: Mutual exclusion is enforced at template time

- **WHEN** the chart is rendered with both `ingress.enabled: true` and `gateway.enabled: true`
- **THEN** rendering fails with a clear error message identifying the conflict
- **AND** no manifests are emitted

#### Scenario: Operator can opt out of both front-ends

- **WHEN** the chart is rendered with `ingress.enabled: false` and `gateway.enabled: false`
- **THEN** the rendered output contains neither `Ingress` nor `HTTPRoute`
- **AND** the panel `Service` is still rendered

#### Scenario: Gateway resource is opt-in

- **WHEN** the chart is rendered with `gateway.enabled: true` and `gateway.createGateway: false`
- **THEN** the rendered output contains an `HTTPRoute` referencing an externally-owned `Gateway` via `parentRefs`
- **AND** the rendered output contains no `Gateway` resource

### Requirement: Subscription Domain Derivation

The chart SHALL set the panel's `SUB_PUBLIC_DOMAIN` environment variable from an explicit value when provided, otherwise derive it from the active routing front-end's host plus a configurable path suffix.

#### Scenario: Explicit value takes precedence

- **WHEN** the chart is rendered with `subscription.publicDomain: subs.example.com/custom`
- **THEN** the panel container's `SUB_PUBLIC_DOMAIN` is `subs.example.com/custom` regardless of ingress or gateway host configuration

#### Scenario: Derivation from Ingress host

- **WHEN** the chart is rendered with `subscription.publicDomain` unset, `ingress.enabled: true`, and `ingress.hosts[0].host: panel.example.com`
- **THEN** the panel container's `SUB_PUBLIC_DOMAIN` is `panel.example.com/api/sub`

#### Scenario: Derivation from Gateway hostname

- **WHEN** the chart is rendered with `subscription.publicDomain` unset, `gateway.enabled: true`, and `gateway.hostnames[0]: panel.example.com`
- **THEN** the panel container's `SUB_PUBLIC_DOMAIN` is `panel.example.com/api/sub`

#### Scenario: Custom path suffix

- **WHEN** the chart is rendered with `subscription.publicPath: /sub` and a derivable host
- **THEN** the panel container's `SUB_PUBLIC_DOMAIN` ends with `/sub` instead of `/api/sub`

#### Scenario: No host available and no explicit value

- **WHEN** the chart is rendered with `subscription.publicDomain` unset, `ingress.enabled: false`, and `gateway.enabled: false`
- **THEN** rendering fails with a message instructing the operator to set `subscription.publicDomain` explicitly

### Requirement: Bundled Postgres via CloudNative-PG

The chart SHALL bundle Postgres as a toggleable CNPG `Cluster` subchart (from `cnpg/cluster`) so that operators get operator-managed HA Postgres by default or can point at an externally-managed Postgres.

#### Scenario: Bundled CNPG Cluster is enabled by default with 3 instances

- **WHEN** the chart is rendered with default values
- **THEN** the rendered output contains a CNPG `Cluster` resource configured with 3 instances
- **AND** the panel container's `DATABASE_URL` references the CNPG Cluster's read-write `Service`

#### Scenario: Backups are disabled by default

- **WHEN** the chart is rendered with default values
- **THEN** the rendered output does not contain `ScheduledBackup` or backup-related resources

#### Scenario: External Postgres replaces the bundled one

- **WHEN** the chart is rendered with `cnpg.enabled: false` and `externalDatabase.url: postgresql://user:pass@db.internal:5432/remnawave`
- **THEN** the rendered output contains no CNPG `Cluster` resource
- **AND** the panel container's `DATABASE_URL` is `postgresql://user:pass@db.internal:5432/remnawave`

#### Scenario: CNPG operator prerequisite is documented

- **WHEN** the chart is installed without the CNPG operator CRDs present
- **THEN** `NOTES.txt` warns about the operator prerequisite and provides install instructions

### Requirement: Bundled Redis HA with TCP Transport

The chart SHALL bundle Redis as a toggleable HA subchart (`dandydeveloper/redis-ha`) with Sentinel failover and HAProxy for a stable single-endpoint connection, with persistence enabled.

#### Scenario: Bundled Redis-HA is enabled by default with 3 replicas

- **WHEN** the chart is rendered with default values
- **THEN** the rendered output contains a Redis-HA `StatefulSet` with 3 replicas, Sentinel sidecars, and an HAProxy `Deployment`
- **AND** `PersistentVolumeClaim` resources are created for Redis data

#### Scenario: HAProxy provides a stable endpoint

- **WHEN** the chart is rendered with default values
- **THEN** the rendered output contains an HAProxy `Service` on port 6379
- **AND** the panel container's `REDIS_HOST` references the HAProxy `Service`
- **AND** the panel container's `REDIS_PORT` is `6379`

#### Scenario: Panel connects via TCP through HAProxy, not Unix socket

- **WHEN** the chart is rendered with `redis-ha.enabled: true`
- **THEN** the panel container's environment includes `REDIS_HOST` and `REDIS_PORT` referencing the HAProxy `Service`
- **AND** the panel container's environment does not include `REDIS_SOCKET`

#### Scenario: Redis uses noeviction policy

- **WHEN** the chart is rendered with default values
- **THEN** the Redis configuration includes `maxmemory-policy noeviction` to match upstream behavior

#### Scenario: External Redis replaces the bundled one

- **WHEN** the chart is rendered with `redis-ha.enabled: false` and `externalRedis.host: cache.internal` and `externalRedis.port: 6379`
- **THEN** the rendered output contains no Redis-HA `StatefulSet`, Sentinel, or HAProxy resources
- **AND** the panel container's `REDIS_HOST` is `cache.internal` and `REDIS_PORT` is `6379`

### Requirement: Health Probes

The chart SHALL configure both liveness and readiness probes on the panel container against the upstream `/health` endpoint on the metrics port.

#### Scenario: Probes target /health on the metrics port

- **WHEN** the chart is rendered with default values
- **THEN** the panel container's `livenessProbe` and `readinessProbe` are HTTP GET probes against path `/health` on the port named for `METRICS_PORT`

#### Scenario: Probe timing is overridable

- **WHEN** the chart is rendered with `probes.liveness.initialDelaySeconds: 60`
- **THEN** the panel container's `livenessProbe.initialDelaySeconds` is `60`

### Requirement: Service Exposure

The chart SHALL expose the panel via a single in-cluster `Service` carrying both the app port and the metrics port as named ports.

#### Scenario: Service has named ports for app and metrics

- **WHEN** the chart is rendered with default values
- **THEN** the rendered `Service` declares two ports with stable names targeting `APP_PORT` and `METRICS_PORT` respectively

#### Scenario: Service type is configurable

- **WHEN** the chart is rendered with `service.type: NodePort`
- **THEN** the rendered `Service` has `type: NodePort`

### Requirement: Horizontal Scaling

The chart SHALL support multi-pod horizontal scaling through `replicaCount`, with `API_INSTANCES` defaulting to `1` so that the Kubernetes pod is the unit of scale.

#### Scenario: Multi-replica deployment

- **WHEN** the chart is rendered with `replicaCount: 3`
- **THEN** the rendered `Deployment` declares `replicas: 3`

#### Scenario: API_INSTANCES default is 1

- **WHEN** the chart is rendered with default values
- **THEN** the panel container's `API_INSTANCES` environment variable is `1`

### Requirement: Prometheus Integration

The chart SHALL provide an opt-in `ServiceMonitor` resource (Prometheus Operator) that scrapes the metrics port of the panel `Service` using the same basic-auth credentials configured for the panel.

#### Scenario: ServiceMonitor is opt-in

- **WHEN** the chart is rendered with default values (`metrics.serviceMonitor.enabled: false`)
- **THEN** the rendered output contains no `ServiceMonitor`

#### Scenario: ServiceMonitor targets the metrics port

- **WHEN** the chart is rendered with `metrics.serviceMonitor.enabled: true`
- **THEN** the rendered output contains a `ServiceMonitor` selecting the panel `Service` and scraping the named metrics port at `/metrics`
- **AND** the `ServiceMonitor` references basic-auth credentials sourced from the same `Secret` (or `existingSecret`) that supplies `METRICS_USER` and `METRICS_PASS`

### Requirement: Chart Validity

The chart SHALL pass `helm lint`, render successfully under default values, and validate operator-supplied values against a `values.schema.json` that enforces type and mutual-exclusion constraints.

#### Scenario: Default values render and lint cleanly

- **WHEN** `helm lint .` and `helm template <release> .` are executed against default values
- **THEN** both commands exit with status `0`

#### Scenario: Schema rejects mutually exclusive routing front-ends

- **WHEN** `helm template <release> . --set ingress.enabled=true --set gateway.enabled=true` is executed
- **THEN** the command fails with a non-zero exit and a message identifying the conflict

#### Scenario: Schema rejects unknown top-level keys

- **WHEN** `helm template <release> . --set unknownTopLevelKey=value` is executed and strict schema validation is enabled
- **THEN** the command fails with a non-zero exit and a message identifying the unknown key
