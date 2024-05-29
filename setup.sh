#! /bin/bash -e
docker rm -f kind-registry || true
kind delete clusters --all

if lsof -i :5000 -sTCP:LISTEN &> /dev/null; then
    echo "Port 5000 is already in use. Exiting."
    exit 1
fi

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



docker run -d -p 5000:5000 --name kind-registry registry:2

cat <<EOF | kind create cluster --name platform --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
      endpoint = ["http://kind-registry:5000"]
nodes:
  - role: control-plane
  - role: worker
    extraPortMappings:
    - containerPort: 31337
      hostPort: 8080
      protocol: TCP
EOF

kubectl --context kind-platform apply --filename https://github.com/cert-manager/cert-manager/releases/download/v1.12.0/cert-manager.yaml

cat <<EOF | kind create cluster --name worker1 --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
      endpoint = ["http://kind-registry:5000"]
nodes:
  - role: control-plane
  - role: worker
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8081
        protocol: TCP
EOF

cat <<EOF | kind create cluster --name worker2 --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
      endpoint = ["http://kind-registry:5000"]
nodes:
  - role: control-plane
  - role: worker
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8082
        protocol: TCP
EOF

docker network connect "kind" "kind-registry"

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

# Install flux on the worker
kubectl apply --context kind-worker1 --filename https://raw.githubusercontent.com/syntasso/kratix/main/hack/destination/gitops-tk-install.yaml
kubectl apply --context kind-worker2 --filename https://raw.githubusercontent.com/syntasso/kratix/main/hack/destination/gitops-tk-install.yaml

cat <<EOF | kubectl apply --context kind-worker1 --filename -
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
  path: ./worker-1/resources
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
  path: ./worker-1/dependencies
  validation: client
EOF

cat <<EOF | kubectl apply --context kind-worker2 --filename -
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
  path: ./worker-2/resources
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
  path: ./worker-2/dependencies
  validation: client
EOF

cat <<EOF | kubectl apply --context kind-platform --filename -
apiVersion: platform.kratix.io/v1alpha1
kind: Destination
metadata:
  name: worker-1
  labels:
    environment: dev
    team: one
spec:
  stateStoreRef:
    name: default
    kind: BucketStateStore
EOF

cat <<EOF | kubectl apply --context kind-platform --filename -
apiVersion: platform.kratix.io/v1alpha1
kind: Destination
metadata:
  name: worker-2
  labels:
    environment: dev
    team: two
spec:
  stateStoreRef:
    name: default
    kind: BucketStateStore
EOF
