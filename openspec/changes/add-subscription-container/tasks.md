## 1. Values Surface

- [x] 1.1 Add `subscription.*` block to [charts/remnawave-panel/values.yaml](charts/remnawave-panel/values.yaml): `enabled` (default `false`), `image.{repository,tag,digest,pullPolicy}`, `port` (default `3010`), `panelUrl` (default empty → derived to `http://localhost:<app.port>`), `apiToken` (empty, stored in Secret), `customSubPrefix` (empty), `marzbanLegacy.{enabled,secretKey}` (disabled, empty), `caddyAuthApiToken` (empty, stored in Secret), `resources` (low defaults), `probes.{liveness,readiness}` (tcpSocket defaults), `ingress.hosts` (empty list), `gateway.hostnames` (empty list)
- [x] 1.2 Extend `existingSecret` documentation in `values.yaml` to list subscription-specific required keys: `REMNAWAVE_API_TOKEN` (when `subscription.enabled`), `MARZBAN_LEGACY_SECRET_KEY` (when `subscription.marzbanLegacy.enabled`), `CADDY_AUTH_API_TOKEN` (when provided)
- [x] 1.3 Update [charts/remnawave-panel/values.schema.json](charts/remnawave-panel/values.schema.json) with the new `subscription.*` key definitions, type constraints, and mutual-exclusion: render-time failure when `subscription.enabled: true` AND neither `ingress.enabled` nor `gateway.enabled` is true

## 2. Helpers

- [x] 2.1 Add `remnawave-panel.subscription.image` helper in [charts/remnawave-panel/templates/_helpers.tpl](charts/remnawave-panel/templates/_helpers.tpl), mirroring the panel `image` helper (tag vs digest precedence, fallback to default tag)
- [x] 2.2 Update the `SUB_PUBLIC_DOMAIN` derivation helper to prefer `subscription.ingress.hosts[0].host` / `subscription.gateway.hostnames[0]` when `subscription.enabled: true`, falling back to the panel host only when `subscription.enabled: false` (preserving current behavior); `fail` when sidecar is enabled without a derivable or explicit value
- [x] 2.3 Adjust default `subscription.publicPath` handling so it is `""` in sidecar mode and remains `/api/sub` in non-sidecar mode; document the two meanings in a `values.yaml` comment

## 3. ConfigMap and Secret

- [x] 3.1 Extend [charts/remnawave-panel/templates/configmap.yaml](charts/remnawave-panel/templates/configmap.yaml) with the sidecar's non-sensitive env keys when `subscription.enabled: true`: `REMNAWAVE_PANEL_URL`, `CUSTOM_SUB_PREFIX`, `MARZBAN_LEGACY_LINK_ENABLED` — omit keys with empty values
- [x] 3.2 Extend [charts/remnawave-panel/templates/secret.yaml](charts/remnawave-panel/templates/secret.yaml) with the sidecar's sensitive keys when `subscription.enabled: true` AND `existingSecret` unset: `REMNAWAVE_API_TOKEN`, `MARZBAN_LEGACY_SECRET_KEY` (when provided), `CADDY_AUTH_API_TOKEN` (when provided) — omit empty
- [x] 3.3 Verify the existing `checksum/config` and `checksum/secret` pod-template annotations continue to cover these additions (no template change expected; add a render test asserting the checksum differs when `subscription.apiToken` changes)

## 4. Deployment: Sidecar Container

- [x] 4.1 Add a second container (`subscription-page`) to [charts/remnawave-panel/templates/deployment.yaml](charts/remnawave-panel/templates/deployment.yaml), gated on `subscription.enabled: true`: image via helper, one named container port (`subscription`) at `subscription.port`, `envFrom` referencing the shared `ConfigMap` and `Secret` (chart-managed or `existingSecret`), plus a container-level `env:` entry setting `APP_PORT` to `subscription.port` to override the shared ConfigMap's panel `APP_PORT`
- [x] 4.2 Set the sidecar's `REMNAWAVE_PANEL_URL` to `subscription.panelUrl` when non-empty, else to `http://localhost:{{ .Values.app.port }}`, via a container-level `env:` entry
- [x] 4.3 Render the sidecar's liveness/readiness probes from `subscription.probes.*`, defaulting to `tcpSocket` on `subscription.port` and allowing `httpGet` / `exec` overrides
- [x] 4.4 Render `subscription.resources` on the sidecar container
- [x] 4.5 Apply the same `securityContext` pattern on the sidecar as the panel container (inherits `subscription.securityContext` when set, otherwise nothing)

## 5. Service

- [x] 5.1 Extend [charts/remnawave-panel/templates/service.yaml](charts/remnawave-panel/templates/service.yaml) to declare a third named port (`subscription`) targeting the sidecar's container port, gated on `subscription.enabled: true`
- [x] 5.2 Verify the `Service` continues to expose exactly two ports (`http`, `metrics`) when `subscription.enabled: false`

## 6. Routing

- [x] 6.1 Extend [charts/remnawave-panel/templates/ingress.yaml](charts/remnawave-panel/templates/ingress.yaml) to emit an additional rule for each entry in `subscription.ingress.hosts` when `subscription.enabled: true` and `ingress.enabled: true`, with the backend set to the `subscription` named port; support per-host paths and TLS entries
- [x] 6.2 Extend [charts/remnawave-panel/templates/httproute.yaml](charts/remnawave-panel/templates/httproute.yaml) (or add a sibling `templates/httproute-subscription.yaml`) to emit an additional `HTTPRoute` for `subscription.gateway.hostnames` when `subscription.enabled: true` and `gateway.enabled: true`, with `backendRefs` targeting the `subscription` named port and `parentRefs` inherited from the panel `HTTPRoute` unless overridden
- [x] 6.3 Update [charts/remnawave-panel/templates/validate.yaml](charts/remnawave-panel/templates/validate.yaml) (or equivalent template-time `fail` guard) so rendering fails when `subscription.enabled: true` AND neither `ingress.enabled` nor `gateway.enabled` is true, with a message that names the missing toggle

## 7. Post-Install Notes

- [x] 7.1 Extend [charts/remnawave-panel/templates/NOTES.txt](charts/remnawave-panel/templates/NOTES.txt) with a subscription-page section that appears only when `subscription.enabled: true`: the resolved subscription URL, the `existingSecret` key requirements for the sidecar (`REMNAWAVE_API_TOKEN` etc.), and a reminder to generate the API token via the panel UI if `apiToken`/existing secret is empty

## 8. Lint, Template, and Render Tests

- [x] 8.1 Run `helm lint charts/remnawave-panel` and `helm template charts/remnawave-panel` with default values; both MUST exit 0 (no behavior change vs. today)
- [x] 8.2 Run `helm template charts/remnawave-panel --set subscription.enabled=true --set subscription.ingress.hosts[0].host=subs.example.com --set ingress.enabled=true`; assert exit 0, two containers in the Deployment, three named ports on the Service, an Ingress rule for `subs.example.com` pointing at the `subscription` port, `APP_PORT=3010` as a direct env entry on the sidecar
- [x] 8.3 Run `helm template` with `subscription.enabled=true` and both `ingress.enabled=false` / `gateway.enabled=false`; assert non-zero exit with a clear subscription-specific routing error
- [x] 8.4 Run `helm template` with `subscription.enabled=true`, `subscription.publicDomain` unset, and no subscription host configured; assert non-zero exit with the new derivation error
- [x] 8.5 Run `helm template` with `subscription.enabled=true` and `existingSecret=my-secret`; assert no chart-managed Secret for panel is rendered, and both panel and sidecar `envFrom` reference `my-secret`
- [x] 8.6 Run `helm template` with `subscription.enabled=true`, `gateway.enabled=true`, and `subscription.gateway.hostnames[0]=subs.example.com`; assert two `HTTPRoute` resources (one panel, one subscription) with matching `parentRefs`

## 9. Documentation

- [x] 9.1 Add a bundled-subscription-page section to [docs/install/helm-chart.md](docs/install/helm-chart.md) covering: enabling the sidecar, generating and setting `REMNAWAVE_API_TOKEN`, configuring `subscription.ingress.hosts` / `subscription.gateway.hostnames`, and mapping from the compose "bundled" install to the chart
- [x] 9.2 Cross-link the new helm-chart section from [docs/install/subscription-page/index.md](docs/install/subscription-page/index.md) as the K8s counterpart to the compose bundled install
