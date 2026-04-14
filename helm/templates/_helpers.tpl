{{/* Fully-qualified release name for naming Kubernetes resources. */}}
{{- define "ic-gateway.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 56 | trimSuffix "-" -}}
{{- end -}}

{{- define "ic-gateway.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "ic-gateway.secretName" -}}
{{- if .Values.secret.existingName -}}
{{ .Values.secret.existingName }}
{{- else -}}
{{ include "ic-gateway.fullname" . }}-secrets
{{- end -}}
{{- end -}}

{{- /*
  Build the Postgres URL with the password inlined. When externalDatabase.url
  is provided we use it verbatim; otherwise we require `secret.pgPassword`
  and embed it directly so the relay/litellm containers need zero extra env
  vars to reach the DB.
*/ -}}
{{- define "ic-gateway.databaseUrl" -}}
{{- if .Values.externalDatabase.url -}}
{{ .Values.externalDatabase.url }}
{{- else -}}
{{- $pw := required "secret.pgPassword is required when externalDatabase.url is unset" .Values.secret.pgPassword -}}
postgres://{{ .Values.postgresql.auth.username }}:{{ $pw }}@{{ .Release.Name }}-postgresql.{{ .Release.Namespace }}.svc:5432/{{ .Values.postgresql.auth.database }}?sslmode=disable
{{- end -}}
{{- end -}}

