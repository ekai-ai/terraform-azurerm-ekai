# Ported verbatim from terraform-google-ekai's modules/neo4j (per explicit
# instruction to match GCP exactly) -- Neo4j Community Edition via the
# official Helm chart, in-cluster only (no ingress). With var.storage_class
# left null the data volume uses AKS's default StorageClass (the chart's
# "defaultStorageClass" mode), which is what every install so far has used;
# setting it switches to "dynamic" mode with that class, like
# terraform-aws-ekai's copy of this module.
resource "random_password" "neo4j" {
  count   = var.neo4j_password == "" ? 1 : 0
  length  = 24
  upper   = true
  lower   = true
  numeric = true
  special = false
}

locals {
  password = var.neo4j_password != "" ? var.neo4j_password : random_password.neo4j[0].result
}

resource "kubernetes_namespace" "neo4j" {
  metadata { name = var.namespace }
}

resource "helm_release" "neo4j" {
  name       = "neo4j"
  namespace  = kubernetes_namespace.neo4j.metadata[0].name
  repository = "https://helm.neo4j.com/neo4j"
  chart      = "neo4j"
  version    = var.chart_version

  values = [yamlencode({
    neo4j = {
      name     = "neo4j"
      password = local.password
      edition  = "community"
    }

    # jsonencode/jsondecode because the two branches are objects with
    # different attributes, which a plain conditional can't return.
    volumes = {
      data = jsondecode(var.storage_class == null ? jsonencode({
        mode                = "defaultStorageClass"
        defaultStorageClass = { requests = { storage = var.storage_size } }
        }) : jsonencode({
        mode    = "dynamic"
        dynamic = { storageClassName = var.storage_class, requests = { storage = var.storage_size } }
      }))
    }

    resources = {
      requests = { cpu = var.cpu_request, memory = var.memory_request }
      limits   = { cpu = var.cpu_limit, memory = var.memory_limit }
    }

    # Expose only within cluster
    services = {
      neo4j = {
        enabled = true
        spec    = { type = "ClusterIP" }
      }
    }

    ingress = { enabled = false }
  })]

  depends_on = [kubernetes_namespace.neo4j]
}

# PodDisruptionBudget — ensures at least 1 pod available during node drain
resource "kubernetes_pod_disruption_budget_v1" "neo4j" {
  metadata {
    name      = "neo4j-pdb"
    namespace = kubernetes_namespace.neo4j.metadata[0].name
  }
  spec {
    min_available = "1"
    selector {
      match_labels = { "helm.neo4j.com/neo4j.name" = "neo4j" }
    }
  }
  depends_on = [helm_release.neo4j]
}
