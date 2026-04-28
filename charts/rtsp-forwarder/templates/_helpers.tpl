{{/*
Expand chart name.
*/}}
{{- define "rtsp-forwarder.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rtsp-forwarder.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "rtsp-forwarder.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rtsp-forwarder.labels" -}}
app.kubernetes.io/name: {{ include "rtsp-forwarder.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{- define "rtsp-forwarder.image" -}}
{{- $tag := .Values.image.tag | default "latest" -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
