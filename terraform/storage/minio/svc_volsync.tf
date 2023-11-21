resource "minio_s3_bucket" "volsync" {
  bucket = "volsync"
  acl    = "private"
}

resource "minio_iam_user" "volsync_user" {
  name = "volsync"
}

resource "minio_iam_policy" "volsync_private" {
  name        = "volsync_private"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "s3:ListBucket",
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ],
        Effect = "Allow",
        Resource = [
          "arn:aws:s3:::volsync/*",
          "arn:aws:s3:::volsync"
        ]
      }
    ]
  })
}

resource "minio_iam_user_policy_attachment" "volsync_user_policy_attachment" {
  user_name   = minio_iam_user.volsync_user.name
  policy_name = minio_iam_policy.volsync_private.name
}
