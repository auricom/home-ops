<!-- markdownlint-disable MD033 MD041 -->
<div align="center">

<!-- markdownlint-disable MD033 -->
<img src="https://raw.githubusercontent.com/siderolabs/talos/main/website/assets/icons/logo.svg" align="center" width="144px"/>

### Talos Linux cluster

... managed with Talhelper :robot:

</div>

## :book:&nbsp; Overview

This directory contains my [Talos](https://www.talos.dev/) Kubernetes cluster in declarative state.
I use my own tool [Talhelper](https://github.com/budimanjojo/talhelper) to create the `machineconfig` files of all my nodes.
The secrets are encrypted with [SOPS](https://toolkit.fluxcd.io/guides/mozilla-sops/).

Feel free to open a [Github issue](https://github.com/budimanjojo/home-cluster/issues/new/choose) if you have any questions.

---

## :scroll:&nbsp; How to apply

1. Prepare your nodes with `Talos Linux`
2. Install `talhelper`.
3. Create your own [talconfig.yaml](https://github.com/budimanjojo/home-cluster/blob/main/talos/talconfig.yaml).
4. Run `talhelper gensecret > talsecret.sops.yaml` if you don't have `machineconfig` before or `talhelper gensecret -f <your-machineconfig.yaml> > talsecret.sops.yaml` if you already have one.
5. Run `sops -e -i talsecret.sops.yaml` to encrypt your secrets (make sure you already have your own `.sops.yaml`) file.
6. Run `talhelper genconfig` and the files will be generated in `./clusterconfig` directory by default.
7. Copy the generated `./clusterconfig/talosconfig` to your `~/.talos/config`.
8. Run `talosctl -n <node-ip> apply-config --insecure --file ./clusterconfig/<clustername>-<hostname>.yaml` on each of your node. Don't forget to run `talosctl -n <node-ip> bootstrap` on one of your controlplane node.
9. Push your current directory to your git repository of choice. :wink:

---

## :memo:&nbsp; After bootstrap

1. Deploy [cilium](https://cilium.io/) : `kubectl kustomize --enable-helm ./cni | kubectl apply -f -`
2. Deploy [kubelet-csr-approver](https://github.com/postfinance/kubelet-csr-approver) `kubectl kustomize --enable-helm ./kubelet-csr-approver | kubectl apply -f -` to approve csr issued by talos nodes (that will allow to see pods logs).
3. Deploy [flux](https://github.com/fluxcd/flux2) `kubectl apply -k ./flux`
4. Create flux github secret `kubectl apply -f ./flux/.decrypted\~github-deploy-key.sops.yaml`
5. Create sops secret `cat ~/.config/sops/age/keys.txt | kubectl create secret generic sops-age --namespace=flux-system --from-file=age.agekey=/dev/stdin`
6. Apply flux cluster configuration `kubectl apply -k kubernetes/flux`
7. Apply flux base configuration `kubectl apply -f kubernetes/base/flux.yaml`
8. Apply flux core `kubectl apply -f kubernetes/cluster-0/core/flux.yaml`
9. Apply flux apps `kubectl apply -f kubernetes/cluster-0/apps/flux.yaml`
