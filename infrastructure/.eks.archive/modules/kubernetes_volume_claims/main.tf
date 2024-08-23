
resource "kubernetes_storage_class" "efs" {
  count = length(var.efs_mounts)
  metadata {
    name = "efs-sc-${var.efs_mounts[count.index].name}"
  }
  storage_provisioner = "efs.csi.aws.com"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = var.efs_mounts[count.index].fs_id
    basePath         = "/"
    # gidRangeStart    = "1000"
    # gidRangeEnd      = "5000"
  }
}


#TODO pv
# apiVersion: v1
# kind: PersistentVolume
# metadata:
#   name: efs-pv
# spec:
#   capacity:
#     storage: 5Gi
#   volumeMode: Filesystem
#   accessModes:
#     - ReadWriteMany
#   persistentVolumeReclaimPolicy: Retain
#   storageClassName: efs-sc
#   csi:
#     driver: efs.csi.aws.com
#     volumeHandle: fs-1234

resource "kubernetes_persistent_volume" "efs" {
  count = length(var.efs_mounts)
  depends_on = [
    kubernetes_storage_class.efs
  ]
  metadata {
    name = "efs-pv-${var.efs_mounts[count.index].name}"
  }
  spec {
    capacity = {
      storage = var.efs_mounts[count.index].storage
    }
    volume_mode                      = "Filesystem"
    persistent_volume_reclaim_policy = "Retain"
    access_modes                     = var.efs_mounts[count.index].access_modes
    storage_class_name               = kubernetes_storage_class.efs[count.index].metadata[0].name
    persistent_volume_source {
      csi {
        driver        = "efs.csi.aws.com"
        volume_handle = kubernetes_storage_class.efs[count.index].parameters.fileSystemId
      }
    }
  }
}

# apiVersion: v1
# kind: PersistentVolumeClaim
# metadata:
#   name: efs-claim
# spec:
#   accessModes:
#     - ReadWriteOnce
#   storageClassName: "efs-sc"
#   resources:
#     requests:
#       storage: 5Gi
resource "kubernetes_persistent_volume_claim" "efs" {
  count = length(var.efs_mounts)
  depends_on = [
    kubernetes_storage_class.efs,
    kubernetes_persistent_volume.efs
  ]
  metadata {
    name      = "efs-claim-${var.efs_mounts[count.index].name}"
    namespace = var.efs_mounts[count.index].namespace
  }
  spec {
    access_modes = var.efs_mounts[count.index].access_modes
    resources {
      requests = {
        storage = var.efs_mounts[count.index].storage
      }
    }
    storage_class_name = kubernetes_storage_class.efs[count.index].metadata[0].name
  }
}
