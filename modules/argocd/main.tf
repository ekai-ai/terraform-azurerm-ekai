# 1. Namespace for ArgoCD
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.argocd_namespace
  }
}
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  chart      = "argo-cd"
  repository = "https://argoproj.github.io/argo-helm"
  #version    = "9.3.4"         # Latest stable version
  #create_namespace = false
  #wait             = true
  #atomic           = true
  #timeout          = 1200

  #set {
  #  name  = "server.service.type"
  #  value = "ClusterIP"   # You can change this to ClusterIP if you don't need an external service
  #}

  set = [
    {
      name  = "configs.secret.argocdServerAdminPassword"
      value = var.argocd_admin_password_hashed
    },

    {
      name  = "configs.params.server\\.insecure"
      value = "true"
    },

    # Default (180s) re-renders every Application every 3 min, which for
    # self-service's helm_chart_version = "*" means re-listing every tag in
    # the OCI chart repo that often. Combined with Image Updater's own
    # polling against the same public registry, this hit ECR Public's
    # anonymous rate limit on the GCP side (confirmed live: repo-server
    # 429s, "Failed to load target state"). Not needed this often for a
    # chart that only actually changes on a new Ekai release.
    {
      name  = "configs.cm.timeout\\.reconciliation"
      value = "600s"
    },

    {
      name  = "server.ingress.enabled"
      value = "true"
    },

    {
      name  = "server.ingress.ingressClassName"
      value = "nginx"
    },

    {
      name  = "server.ingress.hostname"
      value = var.argocd_ingress_host
    },

    {
      name  = "server.ingress.tls[0].secretName"
      value = var.tls_name
    },

    # NOTE: NO `cert-manager.io/cluster-issuer` annotation here. The wildcard
    # cert (`*.<dns_zone>`) issued by the cert-manager Terraform module is
    # reflected into the argocd namespace as `<env>-ekai-wildcard-tls`. Adding
    # the annotation would make cert-manager auto-create a per-Ingress
    # Certificate that overwrites the wildcard secret with a single-host cert
    # → all other Ingresses fall back to the fake fallback cert. Always rely
    # on the reflected secret. See docs/RUNBOOK.md § "Wildcard cert rule".

    {
      name  = "server.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/rewrite-target"
      value = "/"
    },

    {
      name  = "server.ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/force-ssl-redirect"
      value = "true"
    }
  ]
  depends_on = [kubernetes_namespace.argocd]
}

# Watches images referenced by Applications that carry
# argocd-image-updater.argoproj.io/* annotations (self-service's ekai-saas
# app only — see modules/microservices_CD) and patches the Application's
# Helm parameters when a tracked tag's digest changes, so a new push to a
# mutable tag like "latest" actually triggers a sync instead of ArgoCD
# seeing no diff. A no-op for any Application without those annotations, so
# this is safe to install unconditionally alongside ArgoCD itself. Ported
# from terraform-google-ekai's modules/argocd per explicit instruction to
# match GCP.
resource "helm_release" "argocd_image_updater" {
  name            = "argocd-image-updater"
  namespace       = kubernetes_namespace.argocd.metadata[0].name
  chart           = "argocd-image-updater"
  repository      = "https://argoproj.github.io/argo-helm"
  timeout         = 1800
  cleanup_on_fail = true

  # Default (2m) polls all tracked images against the same public registry
  # ArgoCD's own chart lookup hits -- combined, this triggered ECR Public's
  # anonymous rate limit on the GCP side (confirmed live). A slower interval
  # trades a few extra minutes of lag before a new push is picked up for not
  # getting rate-limited.
  values = [yamlencode({
    extraArgs = ["--interval", "10m"]
  })]

  depends_on = [helm_release.argocd]
}

# AppProject/default is auto-created by ArgoCD with a finalizer.
# Managing it here ensures Terraform destroys it before Helm uninstall, so the
# finalizer is gone before controllers are killed and the argocd namespace
# terminates cleanly. No force_conflicts: it only does anything with
# server_side_apply, and alekc/kubectl v3 fails the plan if it's set without it.
resource "kubectl_manifest" "argocd_default_project" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name       = "default"
      namespace  = var.argocd_namespace
      finalizers = []
    }
    spec = {
      sourceRepos              = ["*"]
      destinations             = [{ namespace = "*", server = "https://kubernetes.default.svc" }]
      clusterResourceWhitelist = [{ group = "*", kind = "*" }]
    }
  })
  depends_on = [helm_release.argocd]
}

# DNS A record + wait_for_dns for argocd are NOT created here. The wildcard
# A record `*.<dns_zone>` in Layer 04 (modules/microservices_CD) reads the
# nginx-ingress LB Service IP directly (always populated as soon as the
# nginx Service exists) and covers `argocd.<env>.ekai.ai` automatically.
# Per-Ingress LB-IP lookups would race against Ingress status propagation
# and fail with "empty list of object" during apply.
