variable "project_id" { type = string }
variable "enable_cilium_monitoring" {
  type    = bool
  default = true
}
variable "enable_istio_monitoring" {
  type    = bool
  default = true
}
variable "enable_alerts" {
  type    = bool
  default = true
}
variable "mesh_namespace" {
  type    = string
  default = "bendimu-sut"
}
variable "notification_channels" {
  type    = list(string)
  default = []
}
