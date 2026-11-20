
resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "cert_manager" {
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "1.14.2" # app version 1.14.2

  values = [
    yamlencode({
      installCRDs = true
      serviceAccount = {
        name = "cert-manager"
        annotations = {
          "azure.workload.identity/client-id" = var.client_id
        }
      }
      podLabels = {
        "azure.workload.identity/use" = "true"
      }
    })
  ]
  depends_on = [
    kubernetes_namespace.cert_manager
  ]
}

# The ClusterIssuer CRD is registered by the Helm chart's installCRDs step.
# Kubernetes API server discovery caches take ~10-30s to reflect newly
# registered CRDs, so the kubectl_manifest calls below would get "no kind is
# registered" without this guard. Ported from terraform-google-ekai's
# modules/cert_manager per explicit instruction to match GCP -- this repo's
# cert-manager module didn't have this wait at all before.
resource "time_sleep" "wait_for_crds" {
  create_duration = "30s"

  depends_on = [helm_release.cert_manager]
}

# Both issuers are always created (self-deploy.sh/self-deploy-destroy.sh get
# apply/destroy cycled repeatedly during development — staging avoids
# burning Let's Encrypt's production rate limit, 5 duplicate certs/week per
# domain). var.cluster_issuer_name picks which one the wildcard Certificate
# below actually uses; switch it to "letsencrypt-prod" for a real cutover.
resource "kubectl_manifest" "cluster_issuer_staging" {
  depends_on = [
    time_sleep.wait_for_crds
  ]

  yaml_body = <<YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    email: ${var.acme_email}
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - dns01:
        azureDNS:
          subscriptionID: ${var.subscription_id}
          resourceGroupName: ${var.resource_group_name}
          hostedZoneName: ${var.dns_zone}
          environment: AzurePublicCloud
          managedIdentity:
              clientID: "${var.client_id}"
YAML
}

resource "kubectl_manifest" "cluster_issuer_prod" {
  depends_on = [
    time_sleep.wait_for_crds
  ]

  yaml_body = <<YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ${var.acme_email}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - dns01:
        azureDNS:
          subscriptionID: ${var.subscription_id}
          resourceGroupName: ${var.resource_group_name}
          hostedZoneName: ${var.dns_zone}
          environment: AzurePublicCloud
          managedIdentity:
              clientID: "${var.client_id}"
YAML
}
resource "kubectl_manifest" "ekai_wildcard_cert" {

  yaml_body  = <<YAML
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: "${var.tls_name}"
  namespace: cert-manager
spec:
  secretName: "${var.tls_name}"
  issuerRef:
    name: ${var.cluster_issuer_name}
    kind: ClusterIssuer
  dnsNames:
    - "*.${var.dns_zone}"
  secretTemplate:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "${var.namespace},minio,argocd"
YAML
  depends_on = [kubectl_manifest.cluster_issuer_staging, kubectl_manifest.cluster_issuer_prod]
}
resource "helm_release" "reflector" {
  name       = "reflector"
  namespace  = "kube-system"
  repository = "https://emberstack.github.io/helm-charts"
  chart      = "reflector"
  #version    = "7.1.0"
  depends_on = [kubectl_manifest.ekai_wildcard_cert]
}

