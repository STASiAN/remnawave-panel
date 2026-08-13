{{/*
Expand the name of the chart.
*/}}
{{- define "remnawave-panel.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "remnawave-panel.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "remnawave-panel.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "remnawave-panel.labels" -}}
helm.sh/chart: {{ include "remnawave-panel.chart" . }}
{{ include "remnawave-panel.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "remnawave-panel.selectorLabels" -}}
app.kubernetes.io/name: {{ include "remnawave-panel.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "remnawave-panel.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "remnawave-panel.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Container image reference: supports tag, digest, and appVersion fallback.
*/}}
{{- define "remnawave-panel.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}
{{- end }}

{{/*
Subscription-page deployment fullname.
*/}}
{{- define "remnawave-panel.subscription.fullname" -}}
{{- printf "%s-subscription" (include "remnawave-panel.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Subscription-page selector labels. Uses a distinct app.kubernetes.io/name so the
panel Deployment/Service selectors (which predate the split and are immutable)
never match subscription pods.
*/}}
{{- define "remnawave-panel.subscription.selectorLabels" -}}
app.kubernetes.io/name: {{ printf "%s-subscription" (include "remnawave-panel.name" .) | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Subscription-page common labels.
*/}}
{{- define "remnawave-panel.subscription.labels" -}}
helm.sh/chart: {{ include "remnawave-panel.chart" . }}
{{ include "remnawave-panel.subscription.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: subscription-page
{{- end }}

{{/*
Subscription-page image reference: digest wins, else tag (default "latest").
*/}}
{{- define "remnawave-panel.subscription.image" -}}
{{- if .Values.subscription.image.digest }}
{{- printf "%s@%s" .Values.subscription.image.repository .Values.subscription.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.subscription.image.repository (default "latest" .Values.subscription.image.tag) }}
{{- end }}
{{- end }}

{{/*
Subscription HTTP→HTTPS redirect toggle. Falls back to gateway.httpsRedirect
.enabled when subscription.gateway.httpsRedirect.enabled is unset (null).
Renders "true" or "false" — compare with eq.
*/}}
{{- define "remnawave-panel.subscription.httpsRedirect.enabled" -}}
{{- $sub := .Values.subscription.gateway.httpsRedirect -}}
{{- if kindIs "invalid" $sub.enabled -}}
{{- .Values.gateway.httpsRedirect.enabled | toString -}}
{{- else -}}
{{- $sub.enabled | toString -}}
{{- end -}}
{{- end }}

{{/*
Subscription redirect status code, falling back to gateway.httpsRedirect.statusCode.
*/}}
{{- define "remnawave-panel.subscription.httpsRedirect.statusCode" -}}
{{- $sub := .Values.subscription.gateway.httpsRedirect -}}
{{- if kindIs "invalid" $sub.statusCode -}}
{{- .Values.gateway.httpsRedirect.statusCode -}}
{{- else -}}
{{- $sub.statusCode -}}
{{- end -}}
{{- end }}

{{/*
Whether the chart can pin routes to named listeners on a chart-managed Gateway
(createGateway with an HTTPS listener, i.e. gateway.tls set).
*/}}
{{- define "remnawave-panel.gateway.managedListeners" -}}
{{- if and .Values.gateway.createGateway (not .Values.gateway.gatewayName) .Values.gateway.tls -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Whether the panel HTTP→HTTPS redirect route renders. Requires gateway mode, the
toggle, and a way to target the Gateway's HTTP listener: explicit
gateway.httpsRedirect.parentRefs, or the chart-managed Gateway's `http` listener.
*/}}
{{- define "remnawave-panel.gateway.httpsRedirect.render" -}}
{{- $targetable := or (gt (len .Values.gateway.httpsRedirect.parentRefs) 0) (eq (include "remnawave-panel.gateway.managedListeners" .) "true") -}}
{{- if and .Values.gateway.enabled .Values.gateway.httpsRedirect.enabled $targetable -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Whether the subscription HTTP→HTTPS redirect route renders. Its parentRefs only
fall back to the panel's redirect refs when the subscription route follows the
panel's Gateway (subscription.gateway.parentRefs empty) — a fallback across
Gateways would attach the redirect to the wrong one.
*/}}
{{- define "remnawave-panel.subscription.httpsRedirect.render" -}}
{{- $follows := eq (len .Values.subscription.gateway.parentRefs) 0 -}}
{{- $inherited := or (gt (len .Values.gateway.httpsRedirect.parentRefs) 0) (eq (include "remnawave-panel.gateway.managedListeners" .) "true") -}}
{{- $targetable := or (gt (len .Values.subscription.gateway.httpsRedirect.parentRefs) 0) (and $follows $inherited) -}}
{{- $on := eq (include "remnawave-panel.subscription.httpsRedirect.enabled" .) "true" -}}
{{- if and .Values.gateway.enabled .Values.subscription.enabled (gt (len .Values.subscription.gateway.hostnames) 0) $on $targetable -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/*
Secret name: chart-managed or existing.
*/}}
{{- define "remnawave-panel.secretName" -}}
{{- if .Values.existingSecret }}
{{- .Values.existingSecret }}
{{- else }}
{{- include "remnawave-panel.fullname" . }}
{{- end }}
{{- end }}

{{/*
CNPG Cluster fullname (relies on nameOverride: cnpg in subchart values).
*/}}
{{- define "remnawave-panel.cnpg.fullname" -}}
{{- printf "%s-cnpg" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
CNPG app user secret name (auto-generated by the operator).
*/}}
{{- define "remnawave-panel.cnpg.secretName" -}}
{{- printf "%s-app" (include "remnawave-panel.cnpg.fullname" .) }}
{{- end }}

{{/*
CNPG read-write service name.
*/}}
{{- define "remnawave-panel.cnpg.rw" -}}
{{- printf "%s-rw" (include "remnawave-panel.cnpg.fullname" .) }}
{{- end }}

{{/*
Redis HA HAProxy service name.
*/}}
{{- define "remnawave-panel.redis.host" -}}
{{- printf "%s-redis-ha-haproxy" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Effective REDIS_HOST: HAProxy service when bundled, external otherwise.
*/}}
{{- define "remnawave-panel.redis.effectiveHost" -}}
{{- if (index .Values "redis-ha" "enabled") }}
{{- include "remnawave-panel.redis.host" . }}
{{- else }}
{{- .Values.externalRedis.host }}
{{- end }}
{{- end }}

{{/*
Effective REDIS_PORT.
*/}}
{{- define "remnawave-panel.redis.effectivePort" -}}
{{- if (index .Values "redis-ha" "enabled") }}
{{- "6379" }}
{{- else }}
{{- .Values.externalRedis.port | default "6379" | toString }}
{{- end }}
{{- end }}

{{/*
Derive SUB_PUBLIC_DOMAIN.
Priority:
  1. Explicit subscription.publicDomain (always wins).
  2. When subscription.enabled=true: subscription.ingress.hosts[0].host or
     subscription.gateway.hostnames[0] (matching front-end) + publicPath.
  3. When subscription.enabled=false: ingress.hosts[0].host or
     gateway.hostnames[0] (matching front-end) + publicPath.
Fails if none are available.
*/}}
{{- define "remnawave-panel.subPublicDomain" -}}
{{- if .Values.subscription.publicDomain }}
{{- .Values.subscription.publicDomain }}
{{- else if .Values.subscription.enabled }}
{{- if and .Values.ingress.enabled (gt (len .Values.subscription.ingress.hosts) 0) }}
{{- $host := (index .Values.subscription.ingress.hosts 0).host }}
{{- printf "%s%s" $host .Values.subscription.publicPath }}
{{- else if and .Values.gateway.enabled (gt (len .Values.subscription.gateway.hostnames) 0) }}
{{- $host := index .Values.subscription.gateway.hostnames 0 }}
{{- printf "%s%s" $host .Values.subscription.publicPath }}
{{- else }}
{{- fail "subscription.enabled=true requires subscription.publicDomain to be set explicitly, or a subscription.ingress.hosts[].host / subscription.gateway.hostnames[] entry with the matching front-end enabled" }}
{{- end }}
{{- else if and .Values.ingress.enabled (gt (len .Values.ingress.hosts) 0) }}
{{- $host := (index .Values.ingress.hosts 0).host }}
{{- printf "%s%s" $host .Values.subscription.publicPath }}
{{- else if and .Values.gateway.enabled (gt (len .Values.gateway.hostnames) 0) }}
{{- $host := index .Values.gateway.hostnames 0 }}
{{- printf "%s%s" $host .Values.subscription.publicPath }}
{{- else }}
{{- fail "subscription.publicDomain must be set explicitly, or enable ingress/gateway with a host" }}
{{- end }}
{{- end }}
