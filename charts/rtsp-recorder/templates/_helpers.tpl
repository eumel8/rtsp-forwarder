{{- define "rtsp-recorder.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rtsp-recorder.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "rtsp-recorder.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "rtsp-recorder.labels" -}}
app.kubernetes.io/name: {{ include "rtsp-recorder.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{- define "rtsp-recorder.image" -}}
{{- $tag := .Values.image.tag | default "latest" -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
