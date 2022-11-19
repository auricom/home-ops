# Databases

## Sharry

### S3 Configuration

1. Create `~/.mc/config.json`

    ```json
    {
        "version": "10",
        "aliases": {
            "minio": {
                "url": "https://s3.<domain>",
                "accessKey": "<access-key>",
                "secretKey": "<secret-key>",
                "api": "S3v4",
                "path": "auto"
            }
        }
    }
    ```

2. Create the outline user and password

    ```sh
    mc admin user add minio sharry <super-secret-password>
    ```

3. Create the outline bucket

    ```sh
    mc mb minio/sharry
    ```

4. Create `sharry-user-policy.json`

    ```json
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Action": [
                    "s3:ListBucket",
                    "s3:PutObject",
                    "s3:GetObject",
                    "s3:DeleteObject"
                ],
                "Effect": "Allow",
                "Resource": ["arn:aws:s3:::sharry/*", "arn:aws:s3:::sharry"],
                "Sid": ""
            }
        ]
    }
    ```

5. Apply the bucket policies

    ```sh
    mc admin policy add minio sharry-private sharry-user-policy.json
    ```

6. Associate private policy with the user

    ```sh
    mc admin policy set minio sharry-private user=sharry
    ```
