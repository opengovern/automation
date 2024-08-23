variable "efs_mounts" {
  type = list(object({
    name         = string
    fs_id        = string
    storage      = string
    access_modes = list(string)
    namespace    = string
  }))
  description = "EFS Mounts and Volume Claims"
  default     = []
}

