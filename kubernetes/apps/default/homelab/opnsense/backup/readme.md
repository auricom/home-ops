# Opnsense

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

2. Create the opnsense user and password

   ```sh
   mc admin user add minio opnsense <super-secret-password>
   ```

3. Create the opnsense bucket

   ```sh
   mc mb minio/opnsense
   ```

4. Create `opnsense-user-policy.json`

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
         "Resource": ["arn:aws:s3:::opnsense/*", "arn:aws:s3:::opnsense"],
         "Sid": ""
       }
     ]
   }
   ```

5. Apply the bucket policies

    ```sh
    mc admin policy add minio opnsense-private opnsense-user-policy.json
    ```

6. Associate private policy with the user

    ```sh
    mc admin policy set minio opnsense-private user=opnsense
    ```

7. Create a retention policy

    ```sh
    mc ilm add minio/opnsense --expire-days "90"
    ```
