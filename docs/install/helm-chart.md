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

## Gateway API

To use Gateway API instead of Ingress:

```yaml title="values.yaml"
gateway:
  enabled: true
  gatewayName: "my-gateway"
  hostnames:
    - panel.example.com
```

:::warning
`ingress.enabled` and `gateway.enabled` are mutually exclusive. Do not enable both.
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
