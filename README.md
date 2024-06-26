# kratix-local-setup

## Dependencies

Minio MC client

```bash
brew install minio-mc
```

Kind Cloud Provider

```bash
go install sigs.k8s.io/cloud-provider-kind@latest
```

# Setup

Must first give access to cloud-provider-kind to run as sudo without password which will prompt for sudo password

```bash
make createSudoersFile
```
