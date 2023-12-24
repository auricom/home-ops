# Attic

## S3 Configuration

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

2. Create the attic user and password

   ```sh
   mc admin user add minio attic <super-secret-password>
   ```

3. Create the attic bucket

   ```sh
   mc mb minio/attic
   ```

4. Create `attic-user-policy.json`

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
         "Resource": ["arn:aws:s3:::attic/*", "arn:aws:s3:::attic"],
         "Sid": ""
       }
     ]
   }
   ```

5. Apply the bucket policies

    ```sh
    mc admin policy create minio attic-private attic-user-policy.json
    ```

6. Associate private policy with the user

    ```sh
    mc admin policy set minio attic-private user=attic
    ```
