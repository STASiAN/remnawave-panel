---
sidebar_position: 3
title: Helm Chart (Kubernetes)
---

# Helm Chart (Kubernetes)

Deploy Remnawave Panel on Kubernetes using Helm.

## Prerequisites

- Kubernetes >= 1.29
- Helm >= 3.8
- [CloudNative-PG operator](https://cloudnative-pg.io/) installed in the cluster

### Install the CNPG operator

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm install cnpg cnpg/cloudnative-pg --namespace cnpg-system --create-namespace
```

## Fresh Install

### Step 1 — Add the chart repository

```bash
helm repo add remnawave-panel https://stasian.github.io/remnawave-panel
helm repo update
```

### Step 2 — Create a `values.yaml`

At minimum you need to set the subscription domain and JWT secrets:

```yaml title="values.yaml"
subscription:
  publicDomain: "panel.example.com/api/sub"

jwt:
  authSecret: "your-strong-secret-min-64-chars"
  apiTokensSecret: "another-strong-secret-min-64-chars"

metrics:
  pass: "your-metrics-password"

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: panel.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: panel-tls
      hosts:
        - panel.example.com
```

Generate secrets with:

```bash
openssl rand -hex 64
```

### Step 3 — Install

```bash
helm install remnawave remnawave-panel/remnawave-panel \
  --namespace remnawave --create-namespace \
  -f values.yaml
```

### Step 4 — Verify

```bash
kubectl -n remnawave get pods
kubectl -n remnawave get svc
```

Wait for all pods to become `Running`. The CNPG operator will create the PostgreSQL cluster (3 instances by default). Once the panel pod is ready, access it via your ingress host.

## Using an Existing Secret

For production, avoid putting secrets in `values.yaml`. Create a Kubernetes Secret and reference it:

```yaml title="values.yaml"
existingSecret: "remnawave-secrets"
```

The secret must contain these keys:

| Key | Required | Description |
|-----|----------|-------------|
| `JWT_AUTH_SECRET` | Yes | Auth JWT signing key |
| `JWT_API_TOKENS_SECRET` | Yes | API token JWT signing key |
| `METRICS_PASS` | Yes | Prometheus metrics password |
| `METRICS_USER` | Yes | Prometheus metrics username |
| `DATABASE_URL` | When `cnpg.enabled=false` | PostgreSQL connection URL |
| `WEBHOOK_SECRET_HEADER` | When webhooks enabled | Webhook signature key |
| `TELEGRAM_BOT_TOKEN` | When Telegram enabled | Telegram bot token |
| `REDIS_PASSWORD` | When Redis auth enabled | Redis password |

## External Database

To use a managed PostgreSQL instead of the bundled CNPG cluster:

```yaml title="values.yaml"
cnpg:
  enabled: false

externalDatabase:
  url: "postgresql://user:password@db.example.com:5432/remnawave"
```

## External Redis

To use a managed Redis instead of the bundled Redis HA:

```yaml title="values.yaml"
redis-ha:
  enabled: false

externalRedis:
  host: "redis.example.com"
  port: 6379
```

## Gateway API {#gateway-api}

As an alternative to `Ingress`, the chart can render Gateway API resources (`gateway.networking.k8s.io/v1`). `ingress.enabled` and `gateway.enabled` are mutually exclusive — enable only one routing front-end. The Gateway API CRDs must already be installed in the cluster.

### Attach to an existing Gateway

```yaml title="values.yaml"
ingress:
  enabled: false

gateway:
  enabled: true
  # Reference a Gateway managed outside this chart:
  gatewayName: "shared-gateway"
  # Or use full parentRefs for cross-namespace attachment:
  # parentRefs:
  #   - name: shared-gateway
  #     namespace: infra
  #     sectionName: https
  hostnames:
    - panel.example.com
```

This renders an `HTTPRoute` for the panel with a `PathPrefix /` rule backed by the panel Service.

### Chart-managed Gateway

```yaml title="values.yaml"
gateway:
  enabled: true
  createGateway: true
  gatewayClassName: "cilium"   # required with createGateway=true
  hostnames:
    - panel.example.com
  # Optional HTTPS listener on :443:
  tls:
    mode: Terminate
    certificateRefs:
      - name: panel-tls
  # e.g. external-dns / cert-manager hints:
  annotations: {}
```

When `gatewayName` is empty and `createGateway: true`, the panel `HTTPRoute` automatically attaches to the chart-managed `Gateway`.

### Subscription page over Gateway API

With `subscription.enabled: true`, set `subscription.gateway.hostnames` to render a second `HTTPRoute` backed by the subscription-page Service:

```yaml title="values.yaml"
subscription:
  enabled: true
  publicPath: ""
  gateway:
    hostnames:
      - subs.example.com
    # parentRefs default to the panel HTTPRoute's parentRefs; override to differ.
    # parentRefs: []
```

`SUB_PUBLIC_DOMAIN` derives from `subscription.gateway.hostnames[0]` plus `subscription.publicPath`, same as the Ingress-based derivation.

## Subscription Page {#subscription-page-sidecar}

The chart ships an opt-in `remnawave/subscription-page` Deployment that serves the branded subscription page alongside the panel. This is the K8s counterpart to the compose ["Bundled" install](/install/subscription-page/bundled) — the subscription-page runs as its own Deployment and Service (`<release>-remnawave-panel-subscription`) and talks to the panel through the panel Service. It scales independently via `subscription.replicaCount`.

### Enable the subscription page

```yaml title="values.yaml"
subscription:
  enabled: true
  # Generate this via the panel UI (Settings → API Tokens) and inject via --set
  # or an existingSecret rather than committing it to values.yaml.
  apiToken: ""

  # Subscription page is served at the root of this host.
  # Set subscription.publicPath: "" so SUB_PUBLIC_DOMAIN doesn't get /api/sub appended.
  publicPath: ""

  ingress:
    hosts:
      - host: subs.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - secretName: subs-tls
        hosts:
          - subs.example.com
```

With `ingress.enabled: true` already set for the panel, a separate `Ingress` resource is rendered for `subs.example.com` pointing at the subscription-page Service.

### Generating the API token

1. Install the chart with `subscription.apiToken: ""` first so the pod starts.
2. Complete first-run panel setup, then go to Settings → API Tokens and generate a token.
3. Apply it via helm upgrade:
   ```bash
   helm upgrade remnawave remnawave-panel/remnawave-panel \
     --reuse-values \
     --set subscription.apiToken=<generated-token>
   ```
4. The pods roll automatically via the `checksum/secret` annotation.

For production, put the token in an `existingSecret` under the `REMNAWAVE_API_TOKEN` key instead.

### Migrating from compose-bundled subscription-page

Preserve the existing `REMNAWAVE_API_TOKEN` from your compose `.env` to avoid invalidating subscription links clients have already fetched. Set `subscription.ingress.hosts[0].host` to the same subscription hostname already serving traffic so DNS cutover is the last step.

### Custom sub-path under the subscription host

If the subscription-page is served under a custom path (`CUSTOM_SUB_PREFIX=sub`), set both the upstream env and the derived URL suffix:

```yaml title="values.yaml"
subscription:
  enabled: true
  customSubPrefix: "sub"
  publicPath: "/sub"
  ingress:
    hosts:
      - host: panel.example.com
        paths:
          - path: /sub
            pathType: Prefix
```

:::note
When `subscription.enabled: true`, `SUB_PUBLIC_DOMAIN` is derived from `subscription.ingress.hosts[0].host` (or `subscription.gateway.hostnames[0]` with Gateway API) plus `subscription.publicPath`. Set `subscription.publicDomain` explicitly to bypass the derivation — useful when fronting the subscription page via a CDN or custom URL.
:::

## Prometheus Monitoring

Enable the ServiceMonitor for automatic Prometheus scraping:

```yaml title="values.yaml"
metrics:
  serviceMonitor:
    enabled: true
    interval: "30s"
```

Requires the Prometheus Operator CRDs in your cluster.

## Migrating from Docker Compose

1. Install the CNPG operator (see Prerequisites above)
2. Snapshot your existing Postgres: `pg_dump` from the compose stack
3. Stop the compose stack to freeze writes
4. Install the chart, wait for CNPG Cluster to become ready
5. Restore the dump into the CNPG primary:
   ```bash
   kubectl -n remnawave exec -it <cnpg-primary-pod> -- psql -U remnawave -d remnawave < dump.sql
   ```
6. **Keep the same** `JWT_AUTH_SECRET` and `JWT_API_TOKENS_SECRET` values to preserve existing sessions
7. Ensure `SUB_PUBLIC_DOMAIN` and `PANEL_DOMAIN` match your new ingress host
8. Cutover DNS to the new ingress
9. Redis state is cache-only — no migration needed

## Upgrading

```bash
helm repo update
helm upgrade remnawave remnawave-panel/remnawave-panel \
  --namespace remnawave \
  -f values.yaml
```

Configuration and secret changes trigger automatic Pod rolling updates via checksum annotations.

## Values Reference

See the full [values.yaml](https://github.com/remnawave/remnawave-panel/blob/main/charts/remnawave-panel/values.yaml) for all available configuration options. Every environment variable documented in the [Environment Variables](/install/environment-variables) page is addressable through the chart values.
