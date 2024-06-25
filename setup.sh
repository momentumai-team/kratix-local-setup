#! /bin/bash -e
function cleanup {
    kind delete clusters --all
}

function checkPorts {
if lsof -i :8080 -sTCP:LISTEN &> /dev/null; then
    echo "Port 8080 is already in use. Exiting."
    exit 1
fi

if lsof -i :8081 -sTCP:LISTEN &> /dev/null; then
    echo "Port 8081 is already in use. Exiting."
    exit 1
fi

if lsof -i :8082 -sTCP:LISTEN &> /dev/null; then
    echo "Port 8082 is already in use. Exiting."
    exit 1
fi
}

function startRegistry {
    if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" != 'true' ]; then
      docker run -d --restart=always -p "127.0.0.1:$REGISTRY_PORT:5000" --network bridge --name $REGISTRY_NAME registry:2
    fi
}
function createKindCluster {
    local name=$1
    local containerPort=$2
    local hostPort=$3

cat <<EOF | kind create cluster --name ${name} --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
nodes:
  - role: control-plane
  - role: worker
    extraPortMappings:
    - containerPort: ${containerPort}
      hostPort: ${hostPort}
      protocol: TCP
EOF

REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
for node in $(kind get nodes --name ${name}); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${REGISTRY_NAME}:5000"]
EOF
done

# 4. Connect the registry to the cluster network if not already connected
# This allows kind to bootstrap the network but ensures they're on the same network
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_NAME}")" = 'null' ]; then
  docker network connect "kind" "${REGISTRY_NAME}"
fi

# 5. Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl --context kind-${name} apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}

function setupPlatform {
    kubectl --context kind-platform apply --filename https://github.com/cert-manager/cert-manager/releases/download/v1.12.0/cert-manager.yaml
    sleep 10
    # Wait for all pods in the namespace to be ready
    kubectl --context kind-platform wait --for=condition=ready pod --all --namespace cert-manager --timeout=300s

    # Check the status of the command
    if [ $? -eq 0 ]; then
        echo "All pods in the cert-manager namespace are ready."
    else
        echo "Timeout or error occurred while waiting for pods to be ready in the cert-manager namespace."
        exit 1
    fi

    # Install Kratix
    kubectl apply --context kind-platform --filename https://github.com/syntasso/kratix/releases/latest/download/kratix.yaml
    # Install MinIO and register it as a BucketStateStore
    kubectl apply --context kind-platform --filename https://raw.githubusercontent.com/syntasso/kratix/main/config/samples/minio-install.yaml
    kubectl apply --context kind-platform --filename https://raw.githubusercontent.com/syntasso/kratix/main/config/samples/platform_v1alpha1_bucketstatestore.yaml
}

function setupWorker {
    name=$1
    kubectl apply --context kind-${name} --filename https://raw.githubusercontent.com/syntasso/kratix/main/hack/destination/gitops-tk-install.yaml
cat <<EOF | kubectl apply --context kind-${name} --filename -
---
apiVersion: source.toolkit.fluxcd.io/v1beta1
kind: Bucket
metadata:
  name: kratix-bucket
  namespace: flux-system
spec:
  interval: 10s
  provider: generic
  bucketName: kratix
  endpoint: 172.18.0.2:31337
  insecure: true
  secretRef:
    name: minio-credentials
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: flux-system
type: Opaque
data:
  accesskey: bWluaW9hZG1pbg==
  secretkey: bWluaW9hZG1pbg==
---
apiVersion: kustomize.toolkit.fluxcd.io/v1beta1
kind: Kustomization
metadata:
  name: kratix-workload-resources
  namespace: flux-system
spec:
  interval: 3s
  prune: true
  dependsOn:
  - name: kratix-workload-dependencies
  sourceRef:
    kind: Bucket
    name: kratix-bucket
  path: ./${name}/resources
  validation: client
---
apiVersion: kustomize.toolkit.fluxcd.io/v1beta1
kind: Kustomization
metadata:
  name: kratix-workload-dependencies
  namespace: flux-system
spec:
  interval: 8s
  prune: true
  sourceRef:
    kind: Bucket
    name: kratix-bucket
  path: ./${name}/dependencies
  validation: client
EOF

}

function setupDestination {
    local name=$1
cat <<EOF | kubectl apply --context kind-platform --filename -
apiVersion: platform.kratix.io/v1alpha1
kind: Destination
metadata:
  name: ${name}
  labels:
    environment: dev
    team: two
spec:
  stateStoreRef:
    name: default
    kind: BucketStateStore
EOF

}

export REGISTRY_NAME=kind-registry
export REGISTRY_PORT=30500
cleanup
checkPorts
startRegistry

createKindCluster platform 31337 8080
setupPlatform
createKindCluster worker1 30001 8081
setupWorker worker1
createKindCluster worker2 30002 8082
setupWorker worker2
setupDestination worker1
setupDestination worker2
