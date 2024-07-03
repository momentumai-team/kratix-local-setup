#! /bin/bash -e

function cleanupKindClusters {
    kind delete clusters --all
}

function cleanupDockerCompose {
    docker-compose -p kratix down
}

function cleanup {
    cleanupKindClusters
    cleanupDockerCompose
    docker network rm kind >> /dev/null 2>&1 || true
}

function wipeGiteaState {
    rm -rf gitea/data
    mkdir -p gitea/data
}

function wipeRegistryState {
    rm -rf registry/data
    mkdir -p registry/data
}

function setupDockerCompose {
    mkdir -p registry/{auth,data}
    mkdir -p gitea/data
    docker-compose -p kratix up -d
    sleep 10
    docker exec gitea gitea admin user create --admin --username "gitea_admin" --password "gitea_admin" --email "gitea@local.domain" --must-change-password=false || true
    git ls-remote http://gitea_admin:gitea_admin@localhost:33000/gitea_admin/kratix.git > /dev/null 2>&1
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        tmp=$(mktemp -d)
        pushd $tmp
            git init --initial-branch=main
            git -c "user.name='kratix'" -c "user.email='kratix@kratix.io'" commit --allow-empty -m "Kratix verify demo repo exists"
            git push http://gitea_admin:gitea_admin@localhost:33000/gitea_admin/kratix.git --all
        popd
    fi
}

function createKindCluster {
   local name=$1
# for creating a non-ipv6 network for kind
docker network inspect kind &>/dev/null || docker network create kind

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
EOF

REGISTRY_DIR="/etc/containerd/certs.d/localhost:35000"
for node in $(kind get nodes --name ${name}); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://registry:5000"]
EOF
done

if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "registry")" = 'null' ]; then
  docker network connect "kind" "registry"
fi

if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "gitea")" = 'null' ]; then
  docker network connect "kind" "gitea"
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
    host: "localhost:35000"
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
    kubectl --context kind-platform create namespace gitea || true
    kubectl create secret generic gitea-credentials \
        --context kind-platform \
        --from-literal=username="gitea_admin" \
        --from-literal=password="gitea_admin" \
        --namespace=default \
        --dry-run=client -o yaml | kubectl apply --context kind-platform -f -
cat <<EOF | kubectl apply --context kind-platform --filename -
---
apiVersion: platform.kratix.io/v1alpha1
kind: GitStateStore
metadata:
  name: default
spec:
  secretRef:
    name: gitea-credentials
    namespace: default
  url: http://gitea:3000/gitea_admin/kratix
  branch: main
EOF
}

function setupWorker {
    name=$1
    kubectl apply --context kind-${name} --filename https://raw.githubusercontent.com/syntasso/kratix/main/hack/destination/gitops-tk-install.yaml
    kubectl create secret generic gitea-credentials \
        --context kind-platform \
        --from-literal=username="gitea_admin" \
        --from-literal=password="gitea_admin" \
        --namespace=flux-system \
        --dry-run=client -o yaml | kubectl apply --context kind-${name} -f -
cat <<EOF | kubectl apply --context kind-${name} --filename -
---
apiVersion: source.toolkit.fluxcd.io/v1beta1
kind: GitRepository
metadata:
  name: kratix-workload-resources
  namespace: flux-system
spec:
  interval: 5s
  url: http://gitea:3000/gitea_admin/kratix
  ref:
    branch: main
  secretRef:
    name: gitea-credentials
---
apiVersion: kustomize.toolkit.fluxcd.io/v1beta1
kind: Kustomization
metadata:
  name: kratix-workload-resources
  namespace: flux-system
spec:
  interval: 3s
  dependsOn:
    - name: kratix-workload-dependencies
  sourceRef:
    kind: GitRepository
    name: kratix-workload-resources
  path: "./${name}/resources/"
  prune: true
---
apiVersion: source.toolkit.fluxcd.io/v1beta1
kind: GitRepository
metadata:
  name: kratix-workload-dependencies
  namespace: flux-system
spec:
  interval: 5s
  url: http://gitea:3000/gitea_admin/kratix
  ref:
    branch: main
  secretRef:
    name: gitea-credentials
---
apiVersion: kustomize.toolkit.fluxcd.io/v1beta1
kind: Kustomization
metadata:
  name: kratix-workload-dependencies
  namespace: flux-system
spec:
  interval: 8s
  sourceRef:
    kind: GitRepository
    name: kratix-workload-dependencies
  path: "./${name}/dependencies/"
  prune: true
EOF
}

function setupDestination {
    local name=$1
    local environment=$2
    local team=$3
cat <<EOF | kubectl apply --context kind-platform --filename -
apiVersion: platform.kratix.io/v1alpha1
kind: Destination
metadata:
  name: ${name}
  labels:
    environment: ${environment}
    team: ${team}
spec:
  stateStoreRef:
    name: default
    kind: GitStateStore
EOF
}

function listRegistryImages {
    REGISTRY_URL="127.0.0.1:35000"

    # List all repositories
    REPOS=$(curl -s "http://$REGISTRY_URL/v2/_catalog" | jq -r '.repositories[]')

    # Loop through each repository and list its tags
    for REPO in $REPOS; do
        echo "Repository: $REPO"
        TAGS=$(curl -s "http://$REGISTRY_URL/v2/$REPO/tags/list" | jq -r '.tags[]')
        for TAG in $TAGS; do
            # Fetch the manifest for the given repository and tag
            response=$(curl -s -D - -H "Accept: application/vnd.docker.distribution.manifest.v2+json" "http://$REGISTRY_URL/v2/$REPO/manifests/$TAG")
            # Extract the Docker-Content-Digest header value
            sha256=$(echo "$response" | grep -i Docker-Content-Digest | awk '{print $2}' | tr -d '\r')

            # Print the SHA256 digest
            echo "  Tag: $TAG with SHA256 Digest: $sha256"
        done
    done
}

function testRegistry {
    docker pull nginx@sha256:db5e49f40979ce521f05f0bc9f513d0abacce47904e229f3a95c2e6d9b47f244
    docker tag nginx@sha256:db5e49f40979ce521f05f0bc9f513d0abacce47904e229f3a95c2e6d9b47f244 localhost:35000/nginx:latest
    docker push localhost:35000/nginx:latest
}
