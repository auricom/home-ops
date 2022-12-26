# Development

## thanos

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

2. Create the thanos user and password

    ```sh
    mc admin user add minio thanos <super-secret-password>
    ```

3. Create the thanos bucket

    ```sh
    mc mb minio/thanos
    ```

4. Create `thanos-user-policy.json`

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
                "Resource": ["arn:aws:s3:::thanos/*", "arn:aws:s3:::thanos"],
                "Sid": ""
            }
        ]
    }
    ```

5. Apply the bucket policies

    ```sh
    mc admin policy add minio thanos-private thanos-user-policy.json
    ```

6. Associate private policy with the user

    ```sh
    mc admin policy set minio thanos-private user=thanos
    ```
