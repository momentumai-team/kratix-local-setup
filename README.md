# kratix-local-setup

This is a local setup for testing the Kratix platform with multiple kind clusters, a local registry and local git server. It uses the following components:

## Dependencies

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) and Docker Compose (comes with Docker Desktop)
- [Gitea](https://gitea.io/en-us/)
- [Registry:2](https://hub.docker.com/_/registry/tags)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/)

To list all the registry images:

- [jq](https://stedolan.github.io/jq/download/)

## Validated on

- MacOS ☑️

## Setup

- This will run a local [registry](http://127.0.0.1:35000/v2/_catalog) that can be accessed via port 35000
- A gitea server with userid/pwd as gitea_admin/gitea_admin on [Gitea](http://localhost:33000)

```bash
make run
```

## Validate

Ensure you have added the following to your docker daemon configuration:

```json
{
  "insecure-registries": ["localhost:35000"]
}
```

- To validate the setup, run the following command:

```bash
docker buildx imagetools create --tag localhost:35000/nginx:latest nginx:latest
kubectl --context kind-worker1 create deployment nginx \
    --namespace=default \
    --replicas=2 \
    --image=localhost:35000/nginx:latest
```
