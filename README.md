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

- This will run a local [registry](http://localhost:35000/v2/_catalog) that can be accessed via port 35000
- A gitea server with userid/pwd as gitea_admin/gitea_admin on [Gitea](http://localhost:33000)

```bash
make run
```
