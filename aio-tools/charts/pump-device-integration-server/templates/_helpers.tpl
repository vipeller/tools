{{- define "pump.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "pump.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "pump.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "pump.selectorLabels" -}}
app.kubernetes.io/name: pump-device-integration-server
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "pump.labels" -}}
{{ include "pump.selectorLabels" . }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "pump.pkiClaim" -}}
{{- default (printf "%s-pki" (include "pump.fullname" .) | trunc 63 | trimSuffix "-") .Values.persistence.existingClaim -}}
{{- end -}}
