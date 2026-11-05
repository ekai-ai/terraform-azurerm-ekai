# ──────────────────────────────────────────────────────────────────────────
# ACR image mirror — `az acr import` each source image into our ACR.
#
# Why: third-party registries (Docker Hub) rotate / delete pinned tags. We
# pull everything we depend on into the client's ACR ONCE so chart Helm
# releases pull from a registry we control. Bitnami's Aug 2025 namespace
# move (free images → bitnamilegacy/) won't break us anymore.
#
# Each source image is mirrored to <acr>/<dest_repo>:<dest_tag>. Layer 03's
# Helm values reference these mirrored images.
#
# `az acr import` is idempotent — re-running with the same source/dest is a
# no-op once the image already exists in ACR.
# ──────────────────────────────────────────────────────────────────────────

resource "null_resource" "import" {
  for_each = var.images

  triggers = {
    # Re-run only when the source ref or dest ref changes
    src     = each.value.source
    dest    = "${each.value.dest_repo}:${each.value.dest_tag}"
    acr     = var.acr_name
    version = "v1"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      DEST="${each.value.dest_repo}:${each.value.dest_tag}"
      # Unique per instance -- these `for_each` resources' local-exec
      # provisioners run in parallel, and a shared fixed path here meant
      # every concurrent import's output interleaved into the same file,
      # so one image's failure/success grep could match on a completely
      # different image's output.
      LOG_FILE=$(mktemp /tmp/acr_import.XXXXXX.log)
      trap 'rm -f "$LOG_FILE"' EXIT

      # Idempotent: import succeeds even if target already exists, OR returns
      # ResourceAlreadyExistsError which we tolerate.
      az acr import \
        --name "${var.acr_name}" \
        --source "${each.value.source}" \
        --image  "$DEST" \
        --force 2>&1 | tee "$LOG_FILE" || {
          # If the failure is "already exists", treat as success
          grep -qiE "already exist|tag is already imported" "$LOG_FILE" && {
            echo "::notice::image already exists in ACR — skipping"
            exit 0
          }
          echo "::error::az acr import failed for $DEST"
          exit 1
        }

      echo "✅ mirrored ${each.value.source} → ${var.acr_name}.azurecr.io/$DEST"
    EOT
  }
}
