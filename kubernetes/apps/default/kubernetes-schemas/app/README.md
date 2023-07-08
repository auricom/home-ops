extract_ca_crt_from_secret
kubectl get secret kubernetes-schemas-sa -o json | jq -r '.data["ca.crt"]' | base64 -d > ca.crt

get_user_token_from_secret
USER_TOKEN=$(kubectl get secret kubernetes-schemas-sa -o json | jq -r '.data["token"]' | base64 -d)

Create token
context=$(kubectl config current-context)
CLUSTER_NAME=$(kubectl config get-contexts "$context" | awk '{print $3}' | tail -n 1)
ENDPOINT=$(kubectl config view -o jsonpath="{.clusters[?(@.name == \"${CLUSTER_NAME}\")].cluster.server}")
kubectl config set-cluster "${CLUSTER_NAME}" --kubeconfig=kubernetes-schemas-config --server="${ENDPOINT}" --certificate-authority="ca.crt" --embed-certs=true
kubectl config set-credentials "kubernetes-schemas-default-${CLUSTER_NAME}" --kubeconfig="kubernetes-schemas-config" --token="${USER_TOKEN}"
kubectl config set-context "kubernetes-schemas-default-${CLUSTER_NAME}" --kubeconfig="kubernetes-schemas-config" --cluster="${CLUSTER_NAME}" --user="kubernetes-schemas-default-${CLUSTER_NAME}" --namespace="default"
kubectl config use-context "kubernetes-schemas-default-${CLUSTER_NAME}" --kubeconfig="kubernetes-schemas-config"

# Test

KUBECONFIG=kubernetes-schemas-config kubectl get pods --all-namespaces
KUBECONFIG=kubernetes-schemas-config kubectl get crds
