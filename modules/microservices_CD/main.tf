locals {
  repo_url = var.source_type == "git" ? "https://github.com/${var.github_owner}/${var.manifests_reponame}" : var.helm_repo_url

  # ArgoCD Image Updater annotations -- self-service (source_type == "helm")
  # only. Every tracked image uses a mutable "latest" tag, so ArgoCD's own
  # diffing never notices a new push (the manifest text never changes);
  # Image Updater polls each image's digest and patches this Application's
  # Helm parameters when it changes, giving ArgoCD a real diff to sync.
  # write-back-method "argocd" patches the Application directly (there's no
  # git repo to commit to for a Helm/OCI-sourced self-service install).
  # Aliases/value paths match the chart's existing per-service
  # <service>.image.{repository,tag} values exactly -- semantics/profile are
  # skipped since they're disabled for self-service. Ported from
  # terraform-aws-ekai/terraform-google-ekai's modules/ekai_CD per explicit
  # instruction to match GCP.
  image_updater_images = {
    backend         = "backend"
    frontend        = "frontend"
    erd             = "erd"
    document-worker = "erd.documentWorker"
    profile-worker  = "erd.profileWorker"
  }

  image_updater_annotations = var.source_type != "helm" ? {} : merge(
    {
      "argocd-image-updater.argoproj.io/image-list"        = join(",", [for alias, path in local.image_updater_images : "${alias}=public.ecr.aws/s7m9t1b0/ekai/ekai-${alias}:latest"])
      "argocd-image-updater.argoproj.io/write-back-method" = "argocd"
    },
    merge([
      for alias, path in local.image_updater_images : {
        "argocd-image-updater.argoproj.io/${alias}.update-strategy" = "digest"
        "argocd-image-updater.argoproj.io/${alias}.helm.image-name" = "${path}.image.repository"
        "argocd-image-updater.argoproj.io/${alias}.helm.image-tag"  = "${path}.image.tag"
      }
    ]...)
  )
}

# Use Terraform argocd_repository_credentials to tell ArgoCD to use this repo
resource "argocd_repository_credentials" "manifests_repo_creds" {
  count    = var.source_type == "git" ? 1 : 0
  url      = local.repo_url
  username = var.github_username
  password = var.github_token
}

# ArgoCD requires Helm chart repos to be registered with type = "helm" before
# an Application can reference them via source.chart — unlike git repos,
# which ArgoCD can clone ad hoc. helm_repo_url is an OCI registry (bare
# host+path, no "oci://" prefix — ArgoCD derives the scheme from enable_oci)
# with the chart name itself NOT included in the path; the chart name is
# var.helm_chart_name, referenced separately in the Application's source.chart.
resource "argocd_repository" "helm_chart_repo" {
  count      = var.source_type == "helm" ? 1 : 0
  repo       = var.helm_repo_url
  type       = "helm"
  name       = var.helm_chart_name
  enable_oci = true

  lifecycle {
    precondition {
      condition     = var.helm_repo_url != ""
      error_message = "helm_repo_url must be set when source_type = \"helm\"."
    }
  }
}

# ArgoCD Application
resource "argocd_application" "ekai_frontend" {
  metadata {
    name        = "ekai-saas-${var.env}"
    namespace   = "argocd"
    annotations = local.image_updater_annotations
  }

  spec {
    project = "default"

    source {
      repo_url        = local.repo_url
      path            = var.source_type == "git" ? var.manifests_path : null
      chart           = var.source_type == "helm" ? var.helm_chart_name : null
      target_revision = var.source_type == "git" ? var.manifests_branch : var.helm_chart_version

      dynamic "helm" {
        for_each = var.source_type == "helm" ? [1] : []
        content {
          values = var.helm_values
        }
      }
    }

    # destination is where to deploy in your Kubernetes cluster
    destination {
      server    = "https://kubernetes.default.svc"
      namespace = var.namespace
    }

    # ensure automated sync
    sync_policy {
      automated {
        prune     = true
        self_heal = true
      }
      sync_options = ["CreateNamespace=true"]

      retry {
        limit = "5"
        backoff {
          duration     = "30s"
          max_duration = "2m"
          factor       = "2"
        }
      }
    }

  }

  depends_on = [
    argocd_repository_credentials.manifests_repo_creds,
    argocd_repository.helm_chart_repo,
    time_sleep.wait_for_argocd_prune,
  ]
}

# argocd-image-updater (v1.3.0+) doesn't scan every Application's annotations
# on its own anymore -- it only acts on Applications matched by an
# ImageUpdater CR's applicationRefs. useAnnotations = true tells it to read
# the classic argocd-image-updater.argoproj.io/* annotations already set on
# argocd_application.ekai_frontend above, rather than requiring image config
# to be duplicated into this CR's own images[] field. Confirmed live (GCP):
# without this CR, the controller logs "No ImageUpdater CRs to process" and
# never looks at the Application at all, no matter what annotations it
# carries. Ported from terraform-aws-ekai/terraform-google-ekai's
# modules/ekai_CD per explicit instruction to match GCP.
resource "kubectl_manifest" "image_updater" {
  count = var.source_type == "helm" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "argocd-image-updater.argoproj.io/v1alpha1"
    kind       = "ImageUpdater"
    metadata = {
      name      = "ekai-saas"
      namespace = "argocd"
    }
    spec = {
      applicationRefs = [{
        namePattern    = "ekai-saas-*"
        useAnnotations = true
      }]
    }
  })

  depends_on = [argocd_application.ekai_frontend]
}

# On destroy: ArgoCD prunes all K8s resources including Ingresses, nginx-ingress
# then deletes the backing Service's LoadBalancer. Gives that reconciliation
# time to finish before the namespace/platform layer destroy starts. Azure's
# ingress is nginx-ingress + a K8s Service LB (like GCP), not an ALB with its
# own deregistration delay like AWS — 5m matches GCP's equivalent wait, not
# AWS's 6m padding for a race that doesn't exist here. On apply: 0s, no impact.
resource "time_sleep" "wait_for_argocd_prune" {
  create_duration  = "0s"
  destroy_duration = "5m"
}

# Azure's external load-balancer provisioner runs asynchronously after the
# Service object itself is created (the platform submodule's helm_release
# for nginx-ingress can report success before the LB actually has a public
# IP assigned). This apply runs as a SEPARATE, later `terraform apply` from
# the one that created nginx-ingress (see cicd/main.tf's file header on why
# cicd can't be the same apply) -- normally there's already been several
# minutes of platform work (Postgres init, Redis, MinIO, Neo4j, ArgoCD) by
# the time this apply starts, which is usually enough, but nothing actually
# guarantees it if this apply is ever re-run in isolation shortly after
# platform finishes. Matches terraform-google-ekai's modules/ingress_controller
# wait_for_lb pattern (same 30s), relocated here since Azure's read of the
# LB IP happens in cicd, not in platform where nginx-ingress is installed.
resource "time_sleep" "wait_for_nginx_lb" {
  create_duration = "30s"
}

# ── DNS — single source of truth: nginx-ingress controller LB IP ────────────
# All service ingresses (frontend/backend/semantics/erd/profile) route through
# the SAME nginx-ingress LoadBalancer service. We don't need to look up each
# ingress individually — fetch the LB IP once from the nginx-ingress controller
# Service, then create a single wildcard A record `*.<dns_zone>` so every
# subdomain (`backend.<env>.ekai.ai`, `portal.<env>.ekai.ai`, etc.) resolves
# to that one IP. nginx-ingress dispatches based on Host header.
data "kubernetes_service" "nginx_ingress" {
  metadata {
    name      = "nginx-ingress-ingress-nginx-controller"
    namespace = "nginx-ingress"
  }

  depends_on = [time_sleep.wait_for_nginx_lb]
}

resource "azurerm_dns_a_record" "wildcard" {
  name                = "*"
  zone_name           = var.dns_zone
  resource_group_name = var.resource_group_name
  ttl                 = 300
  records             = [data.kubernetes_service.nginx_ingress.status[0].load_balancer[0].ingress[0].ip]
  tags                = var.tags
}
