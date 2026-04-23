## ADDED Requirements

### Requirement: Subscription Page Sidecar Container

The chart SHALL support an opt-in subscription-page sidecar container (`remnawave/subscription-page`) co-located in the panel `Deployment`'s pod template, gated on `subscription.enabled` (default `false`).

#### Scenario: Sidecar is disabled by default

- **WHEN** the chart is rendered with default values
- **THEN** the panel `Deployment` contains exactly one container (the panel)
- **AND** the rendered output contains no subscription-page container definition

#### Scenario: Sidecar is added when enabled

- **WHEN** the chart is rendered with `subscription.enabled: true`
- **THEN** the panel `Deployment`'s pod template contains a second container named `subscription-page`
- **AND** the sidecar's image reference resolves to `remnawave/subscription-page:<subscription.image.tag>` (or the default tag when unset)
- **AND** the sidecar declares one container port targeting `subscription.port` (default `3010`)

#### Scenario: Sidecar talks to the panel over localhost

- **WHEN** the chart is rendered with `subscription.enabled: true` and `subscription.panelUrl` unset
- **THEN** the sidecar's `REMNAWAVE_PANEL_URL` environment variable is `http://localhost:<app.port>` (e.g., `http://localhost:3000`)

#### Scenario: Operator overrides the sidecar image tag

- **WHEN** the chart is rendered with `--set subscription.enabled=true --set subscription.image.tag=1.2.3`
- **THEN** the sidecar container's image reference resolves to `remnawave/subscription-page:1.2.3`

#### Scenario: Operator pins the sidecar by digest

- **WHEN** the chart is rendered with `subscription.enabled: true` and `subscription.image.digest: sha256:abc...`
- **THEN** the sidecar container's image reference includes the digest and excludes the tag

#### Scenario: APP_PORT does not collide between containers

- **WHEN** the chart is rendered with `subscription.enabled: true`, `app.port: 3000`, and `subscription.port: 3010`
- **THEN** the panel container's `APP_PORT` environment variable resolves to `3000` via the shared `ConfigMap`
- **AND** the subscription-page container's `APP_PORT` environment variable resolves to `3010` via a container-level `env:` entry that takes precedence over `envFrom`

### Requirement: Subscription Page Configuration Surface

The chart SHALL expose every environment variable documented by the upstream subscription-page image as a configurable value under `subscription.*` in `values.yaml`, with the same empty-value-omission behavior as the panel's configuration.

#### Scenario: Subscription env vars are addressable

- **WHEN** an operator inspects `values.yaml` with the subscription block
- **THEN** the following keys are settable under `subscription.*`: `enabled`, `image.{repository,tag,digest,pullPolicy}`, `port`, `panelUrl`, `apiToken`, `customSubPrefix`, `marzbanLegacy.{enabled,secretKey}`, `caddyAuthApiToken`, `resources`, `probes`, `ingress.hosts`, `gateway.hostnames`, `publicDomain`, `publicPath`

#### Scenario: Unset optional subscription env vars are omitted from the container env

- **WHEN** the chart is rendered with `subscription.enabled: true` and optional keys (`customSubPrefix`, `caddyAuthApiToken`, `marzbanLegacy.secretKey`) left empty
- **THEN** the rendered `ConfigMap` and `Secret` omit those keys entirely rather than emitting empty strings

### Requirement: Subscription Page Service Port

The chart SHALL expose the subscription-page via a third named port (`subscription`) on the existing panel `Service` when `subscription.enabled: true`.

#### Scenario: Subscription port appears on the Service when enabled

- **WHEN** the chart is rendered with `subscription.enabled: true`
- **THEN** the panel `Service` declares three named ports: `http`, `metrics`, and `subscription`
- **AND** the `subscription` port targets the sidecar's container port (`subscription.port`, default `3010`)

#### Scenario: Subscription port is absent when disabled

- **WHEN** the chart is rendered with default values
- **THEN** the panel `Service` declares exactly two named ports: `http` and `metrics`
- **AND** no `subscription` port is present

### Requirement: Subscription Page Routing

The chart SHALL route external traffic to the subscription-page via a dedicated host on the active routing front-end (`Ingress` or `HTTPRoute`), sharing the existing mutual-exclusion rule between `ingress.enabled` and `gateway.enabled`.

#### Scenario: Ingress mode adds a subscription host rule

- **WHEN** the chart is rendered with `subscription.enabled: true`, `ingress.enabled: true`, `gateway.enabled: false`, and `subscription.ingress.hosts[0].host: subs.example.com`
- **THEN** the rendered `Ingress` contains a rule for `subs.example.com` whose backend points to the panel `Service` on the `subscription` named port
- **AND** the existing panel-host rule is unchanged

#### Scenario: Gateway mode adds a subscription HTTPRoute

- **WHEN** the chart is rendered with `subscription.enabled: true`, `gateway.enabled: true`, `ingress.enabled: false`, and `subscription.gateway.hostnames[0]: subs.example.com`
- **THEN** the rendered output contains a second `HTTPRoute` whose `hostnames` include `subs.example.com`
- **AND** the `HTTPRoute`'s `backendRefs` point to the panel `Service` on the `subscription` named port
- **AND** the subscription `HTTPRoute`'s `parentRefs` match the panel `HTTPRoute`'s `parentRefs` unless overridden

#### Scenario: Enabling the sidecar without a front-end fails rendering

- **WHEN** the chart is rendered with `subscription.enabled: true`, `ingress.enabled: false`, and `gateway.enabled: false`
- **THEN** rendering fails with a clear error message instructing the operator to enable either `ingress` or `gateway` and configure a subscription host
- **AND** no manifests are emitted

#### Scenario: Sidecar routing inherits the front-end mutual exclusion

- **WHEN** the chart is rendered with `subscription.enabled: true`, `ingress.enabled: true`, and `gateway.enabled: true`
- **THEN** rendering fails with the existing mutual-exclusion error
- **AND** the subscription-specific routing blocks do not alter this behavior

### Requirement: Subscription Page Probes

The chart SHALL configure liveness and readiness probes on the subscription-page sidecar container, defaulting to a `tcpSocket` probe against the sidecar's port with fully overridable timing and probe-type.

#### Scenario: Default probes are TCP against the subscription port

- **WHEN** the chart is rendered with `subscription.enabled: true` and default `subscription.probes.*`
- **THEN** the sidecar container's `livenessProbe` and `readinessProbe` are `tcpSocket` probes against port `subscription.port`

#### Scenario: Operator overrides to an HTTP probe

- **WHEN** the chart is rendered with `subscription.probes.liveness.httpGet.path: /healthz`
- **THEN** the sidecar container's `livenessProbe` is an HTTP GET probe against `/healthz`

## MODIFIED Requirements

### Requirement: Two-Track Secret Handling

The chart SHALL support two mutually exclusive sources for sensitive configuration: a chart-managed `Secret` rendered from values, or an operator-supplied `existingSecret` referenced by name. When `subscription.enabled: true`, the secret contract SHALL additionally cover the subscription-page's sensitive keys.

#### Scenario: Chart-managed Secret is rendered when existingSecret is unset

- **WHEN** the chart is rendered with `jwt.authSecret`, `jwt.apiTokensSecret`, `metrics.password`, and (if applicable) `webhook.secretHeader` and `telegram.botToken` provided in values, and `existingSecret` unset
- **THEN** the rendered output contains a `Secret` whose data fields correspond to those values
- **AND** the panel container's `envFrom` references this rendered `Secret`

#### Scenario: Chart-managed Secret includes subscription keys when sidecar is enabled

- **WHEN** the chart is rendered with `subscription.enabled: true`, `subscription.apiToken: <token>`, `existingSecret` unset, and (if applicable) `subscription.marzbanLegacy.enabled: true` with `subscription.marzbanLegacy.secretKey: <key>`, and (if applicable) `subscription.caddyAuthApiToken: <token>`
- **THEN** the rendered `Secret` contains `REMNAWAVE_API_TOKEN` and, where provided, `MARZBAN_LEGACY_SECRET_KEY` and `CADDY_AUTH_API_TOKEN`
- **AND** the sidecar container's `envFrom` references this rendered `Secret`

#### Scenario: Existing Secret is referenced when set

- **WHEN** the chart is rendered with `existingSecret: my-prebuilt-secret`
- **THEN** the rendered output contains no chart-managed `Secret` for panel credentials
- **AND** the panel container's `envFrom` references `my-prebuilt-secret`

#### Scenario: Existing Secret is referenced by the sidecar as well

- **WHEN** the chart is rendered with `subscription.enabled: true` and `existingSecret: my-prebuilt-secret`
- **THEN** the sidecar container's `envFrom` references `my-prebuilt-secret`
- **AND** the chart emits no additional subscription-specific `Secret`

#### Scenario: Required secret keys are documented

- **WHEN** an operator inspects `values.yaml`
- **THEN** the documentation enumerates the exact keys an `existingSecret` must provide: `JWT_AUTH_SECRET`, `JWT_API_TOKENS_SECRET`, `METRICS_PASS`, `POSTGRES_PASSWORD` when bundled DB is enabled, `WEBHOOK_SECRET_HEADER` when webhooks are enabled, `TELEGRAM_BOT_TOKEN` when Telegram is enabled, `REMNAWAVE_API_TOKEN` when `subscription.enabled: true`, `MARZBAN_LEGACY_SECRET_KEY` when `subscription.marzbanLegacy.enabled: true`, `CADDY_AUTH_API_TOKEN` when the Caddy-with-security addon is in use

### Requirement: Subscription Domain Derivation

The chart SHALL set the panel's `SUB_PUBLIC_DOMAIN` environment variable from an explicit value when provided, otherwise derive it from the subscription-page's routing host when the sidecar is enabled, otherwise from the panel's routing host plus a configurable path suffix. When the sidecar is enabled without any derivable or explicit host, rendering SHALL fail.

#### Scenario: Explicit value takes precedence

- **WHEN** the chart is rendered with `subscription.publicDomain: subs.example.com/custom`
- **THEN** the panel container's `SUB_PUBLIC_DOMAIN` is `subs.example.com/custom` regardless of ingress, gateway, or subscription-host configuration

#### Scenario: Derivation from subscription Ingress host when sidecar is enabled

- **WHEN** the chart is rendered with `subscription.enabled: true`, `subscription.publicDomain` unset, `ingress.enabled: true`, and `subscription.ingress.hosts[0].host: subs.example.com`
- **THEN** the panel container's `SUB_PUBLIC_DOMAIN` is `subs.example.com` (with empty `subscription.publicPath`)

#### Scenario: Derivation from subscription Gateway hostname when sidecar is enabled

- **WHEN** the chart is rendered with `subscription.enabled: true`, `subscription.publicDomain` unset, `gateway.enabled: true`, and `subscription.gateway.hostnames[0]: subs.example.com`
- **THEN** the panel container's `SUB_PUBLIC_DOMAIN` is `subs.example.com` (with empty `subscription.publicPath`)

#### Scenario: Derivation from panel Ingress host when sidecar is disabled

- **WHEN** the chart is rendered with `subscription.enabled: false`, `subscription.publicDomain` unset, `ingress.enabled: true`, and `ingress.hosts[0].host: panel.example.com`
- **THEN** the panel container's `SUB_PUBLIC_DOMAIN` is `panel.example.com/api/sub`

#### Scenario: Derivation from panel Gateway hostname when sidecar is disabled

- **WHEN** the chart is rendered with `subscription.enabled: false`, `subscription.publicDomain` unset, `gateway.enabled: true`, and `gateway.hostnames[0]: panel.example.com`
- **THEN** the panel container's `SUB_PUBLIC_DOMAIN` is `panel.example.com/api/sub`

#### Scenario: Custom path suffix

- **WHEN** the chart is rendered with `subscription.publicPath: /sub` and a derivable host (either subscription or panel)
- **THEN** the panel container's `SUB_PUBLIC_DOMAIN` ends with `/sub`

#### Scenario: Sidecar enabled without a derivable host and no explicit value

- **WHEN** the chart is rendered with `subscription.enabled: true`, `subscription.publicDomain` unset, and no `subscription.ingress.hosts` or `subscription.gateway.hostnames` entries
- **THEN** rendering fails with a message instructing the operator to set `subscription.publicDomain` or configure a subscription host

#### Scenario: No host available and no explicit value with sidecar disabled

- **WHEN** the chart is rendered with `subscription.enabled: false`, `subscription.publicDomain` unset, `ingress.enabled: false`, and `gateway.enabled: false`
- **THEN** rendering fails with a message instructing the operator to set `subscription.publicDomain` explicitly
