# this tells Make to run 'make help' if the user runs 'make'
# without this, Make would use the first target as the default
.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help

export REGISTRY_NAME=kind-registry
export REGISTRY_PORT=30500

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

cleanup: cleanupKindClusters cleanupRegistry ## Cleans up the kind clusters and the registry

createSudoersFile: ## Creates the sudoers file
	@source ./common.sh && createSudoersFile

cleanupKindClusters: ## Deletes kind clusters
	@source ./common.sh && cleanupKindClusters

cleanupRegistry: ## Deletes the registry
	@source ./common.sh && cleanupRegistry

setupRegistry: ## Sets up the registry
	@source ./common.sh && setupRegistry

setupPlatformCluster: ## Sets up the platform cluster
	@source ./common.sh && createKindCluster platform;
	@source ./common.sh && setupPlatform

setupWorkerCluster1: ## Sets up the worker cluster 1
	@source ./common.sh && createKindCluster worker1;
	@source ./common.sh && setupWorker worker1;
	@source ./common.sh && setupDestination worker1

setupWorkerCluster2: ## Sets up the worker cluster 2
	@source ./common.sh && createKindCluster worker2;
	@source ./common.sh && setupWorker worker2;
	@source ./common.sh && setupDestination worker2

runKindCloudProvider: ## Runs the kind cloud provider
	@source ./common.sh && runCloudProviderKindInBackground

stopsKindCloudProvider: ## Runs the kind cloud provider
	@source ./common.sh && stopCloudProviderKindInBackground

run: runKindCloudProvider ## Runs local setup
	@make -j 2 setupRegistry setupPlatformCluster
	@make -j 2 setupWorkerCluster1 setupWorkerCluster2
