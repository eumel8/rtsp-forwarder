{{- define "recordings-web.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "recordings-web.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "recordings-web.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "recordings-web.labels" -}}
app.kubernetes.io/name: {{ include "recordings-web.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{- define "recordings-web.selectorLabels" -}}
app.kubernetes.io/name: {{ include "recordings-web.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "recordings-web.image" -}}
{{- $tag := .Values.image.tag | default "latest" -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
