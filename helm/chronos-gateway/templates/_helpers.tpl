{{- define "gateway.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "gateway.labels" -}}
app.kubernetes.io/name: chronos-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "gateway.selector" -}}
app.kubernetes.io/name: chronos-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "gateway.serviceAccount" -}}
{{- if .Values.serviceAccount.create -}}
{{- .Values.serviceAccount.name | default (include "gateway.name" .) -}}
{{- else -}}
{{- .Values.serviceAccount.name | default "default" -}}
{{- end -}}
{{- end -}}

{{/* GATEWAY_PUBLIC_URL: publicUrl, else the ingress's host, else empty (the gateway's own default) */}}
{{- define "gateway.publicUrl" -}}
{{- if .Values.publicUrl -}}
{{- .Values.publicUrl | trimSuffix "/" -}}
{{- else if and .Values.ingress.enabled .Values.ingress.host -}}
{{- printf "%s://%s" (ternary "https" "http" .Values.ingress.tls.enabled) .Values.ingress.host -}}
{{- end -}}
{{- end -}}

{{/* whether Postgres is connected at start, from a file */}}
{{- define "gateway.hasPostgres" -}}
{{- if or .Values.postgres.existingSecret .Values.postgres.url }}true{{ end -}}
{{- end -}}

{{- define "gateway.postgresSecret" -}}
{{- .Values.postgres.existingSecret | default (include "gateway.name" .) -}}
{{- end -}}

{{- define "gateway.ssoSecret" -}}
{{- .Values.sso.existingSecret | default (include "gateway.name" .) -}}
{{- end -}}

{{/* whether the chart makes its own Secret: an inline Postgres URL or client secret */}}
{{- define "gateway.ownSecret" -}}
{{- if or (and .Values.postgres.url (not .Values.postgres.existingSecret)) (and .Values.sso.clientSecret (not .Values.sso.existingSecret)) }}true{{ end -}}
{{- end -}}

{{/* settings that can't work together fail the install with a sentence that says what to set */}}
{{- define "gateway.validate" -}}
{{- if and .Values.postgres.tables (not (include "gateway.hasPostgres" .)) -}}
{{- fail "postgres.tables needs postgres.existingSecret or postgres.url (the tables are attached from that Postgres at the first start)" -}}
{{- end -}}
{{- if and .Values.postgres.tenantColumn (not .Values.postgres.tables) -}}
{{- fail "postgres.tenantColumn needs postgres.tables" -}}
{{- end -}}
{{- if .Values.sso.issuer -}}
{{- if not .Values.sso.clientId -}}{{- fail "sso.issuer needs sso.clientId" -}}{{- end -}}
{{- if not (or .Values.sso.existingSecret .Values.sso.clientSecret) -}}{{- fail "sso.issuer needs sso.existingSecret (key clientSecret) or sso.clientSecret" -}}{{- end -}}
{{- if not .Values.sso.allow -}}{{- fail "sso.issuer needs sso.allow: who may approve (emails, @domains, group:names)" -}}{{- end -}}
{{- if not (hasPrefix "https://" (include "gateway.publicUrl" .)) -}}{{- fail "sso.issuer needs an https:// address: set publicUrl, or turn on the ingress with TLS" -}}{{- end -}}
{{- end -}}
{{- if and .Values.ingress.enabled (not .Values.ingress.host) -}}
{{- fail "ingress.enabled needs ingress.host (gateway.example.com)" -}}
{{- end -}}
{{- if and .Values.networkPolicy.enabled (not .Values.networkPolicy.postgres.cidrs) -}}
{{- fail "networkPolicy.enabled needs networkPolicy.postgres.cidrs (your Postgres's addresses), or networkPolicy.enabled=false" -}}
{{- end -}}
{{- range $k, $v := .Values.env -}}
{{- if not (hasPrefix "GATEWAY_" $k) -}}{{- fail (printf "env.%s: env takes GATEWAY_* settings only (use extraEnv for anything else)" $k) -}}{{- end -}}
{{- if has $k (list "GATEWAY_DATA" "GATEWAY_LISTEN" "GATEWAY_SOURCE_FILE") -}}{{- fail (printf "env.%s is set by the chart" $k) -}}{{- end -}}
{{- end -}}
{{- end -}}
