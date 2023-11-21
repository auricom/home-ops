provider "minio" {
  minio_server   = data.sops_file.secrets.data["minio_server"]
  minio_user     = data.sops_file.secrets.data["minio_root_user"]
  minio_password = data.sops_file.secrets.data["minio_root_password"]
  minio_region   = "us-east-1"
  minio_ssl      = true
}
