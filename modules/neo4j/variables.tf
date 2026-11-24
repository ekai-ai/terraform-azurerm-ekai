variable "namespace" {
  type    = string
  default = "neo4j"
}

variable "chart_version" {
  type    = string
  default = "5.26.0"
}

variable "neo4j_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "storage_size" {
  type    = string
  default = "20Gi"
}

variable "storage_class" {
  description = "StorageClass for the Neo4j data volume. null uses AKS's default StorageClass. A PVC's class can't change after it's created, so don't set this on an install that already has one."
  type        = string
  default     = null
}

variable "memory_request" {
  type    = string
  default = "2Gi"
}

variable "memory_limit" {
  type    = string
  default = "4Gi"
}

variable "cpu_request" {
  type    = string
  default = "500m"
}

variable "cpu_limit" {
  type    = string
  default = "2"
}
