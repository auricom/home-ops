# truenas

## truenas-backup S3 Configuration

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

2. Create the truenas user and password

   ```sh
   mc admin user add minio truenas <super-secret-password>
   ```

3. Create the truenas bucket

   ```sh
   mc mb minio/truenas
   ```

4. Create `truenas-user-policy.json`

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
         "Resource": ["arn:aws:s3:::truenas/*", "arn:aws:s3:::truenas"],
         "Sid": ""
       }
     ]
   }
   ```

5. Apply the bucket policies

    ```sh
    mc admin policy add minio truenas-private truenas-user-policy.json
    ```

6. Associate private policy with the user

    ```sh
    mc admin policy set minio truenas-private user=truenas
    ```

7. Create a retention policy

    ```sh
    mc ilm add minio/truenas --expire-days "90"
    ```

## minio-rclone S3 Configuration

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

2. Create the rclone user and password

   ```sh
   mc admin user add minio rclone <super-secret-password>
   ```


3. Create `rclone-user-policy.json`

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Action": [
           "s3:ListBucket",
           "s3:GetObject"
         ],
         "Effect": "Allow",
         "Resource": ["arn:aws:s3:::opnsense/*", "arn:aws:s3:::opnsense","arn:aws:s3:::truenas/*", "arn:aws:s3:::truenas"],
         "Sid": ""
       }
     ]
   }
   ```

4. Apply the bucket policies

    ```sh
    mc admin policy add minio rclone-private rclone-user-policy.json
    ```

5. Associate private policy with the user

    ```sh
    mc admin policy set minio rclone-private user=rclone
    ```
