
output "kubernetes_storage_class_efs" {
  value = kubernetes_storage_class.efs
}


output "kubernetes_persistent_volume_efs" {
  value = kubernetes_persistent_volume.efs
}


output "kubernetes_persistent_volume_claim_efs" {
  value = kubernetes_persistent_volume_claim.efs
}
