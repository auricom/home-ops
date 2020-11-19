# home-cluster

## Bootstrap Flux

```bash
flux bootstrap github \
  --version=latest \
  --owner=auricom \
  --repository=home-cluster \
  --path=cluster \
  --personal \
  --network-policy=false
```
## SOPS secret from GPG key

```bash
gpg --export-secret-keys --armor <GPG_KEY_ID> | kubectl create secret generic sops-gpg --namespace=flux-system --from-file=sops.asc=/dev/stdin
```

## Encrypt kubernetes resources with sops binary

```bash
sops --encrypt --pgp=<GPG_KEY_ID> --encrypted-regex '^(data|stringData)$' --in-place <FILE_PATH>
```