{{/*
Kargo project name - prefixed to avoid namespace conflicts
*/}}
{{- define "kargo-loader.kargoProject" -}}
{{- .Values.kargo.project | default (printf "kargo-%s" .Values.name) }}
{{- end }}
