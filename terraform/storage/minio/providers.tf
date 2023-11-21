provider "aws" {
  access_key = base64decode(data.sops_file.secrets.data["minio_root_user"])
  secret_key = base64decode(data.sops_file.secrets.data["minio_root_password"])
  region     = "us-east-1"
  endpoints {
    s3 = base64decode(data.sops_file.secrets.data["minio_endpoint"])
  }
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_force_path_style         = true
}
