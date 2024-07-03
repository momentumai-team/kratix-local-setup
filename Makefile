# this tells Make to run 'make help' if the user runs 'make'
# without this, Make would use the first target as the default
.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

define runScript
	@echo "Running $(1)"
    @source ./common.sh && $(1) $(args)
endef

setupDockerCompose: ## Sets up the registry and gitea
	$(call runScript, setupDockerCompose)

setupPlatformCluster: ## Sets up the platform cluster
	$(call runScript, createKindCluster platform)
	$(call runScript, setupPlatform)

setupWorkerCluster1: ## Sets up the worker cluster 1
	$(call runScript, createKindCluster worker1)
	$(call runScript, setupWorker worker1)
	$(call runScript, setupDestination worker1 dev team1)

setupWorkerCluster2: ## Sets up the worker cluster 2
	$(call runScript, createKindCluster worker2)
	$(call runScript, setupWorker worker2)
	$(call runScript, setupDestination worker2 prod team1)

run: ## Runs local setup
	@make -j 2 setupDockerCompose setupPlatformCluster
	@make -j 2 setupWorkerCluster1 setupWorkerCluster2

listRegistryImages: ## Lists all the images in the registry
	$(call runScript, listRegistryImages)

cleanup: ## Cleans up the kind clusters and docker composed registry/gitea
	$(call runScript, cleanup)

cleanupKindClusters: ## Deletes kind clusters
	$(call runScript, cleanupKindClusters)

cleanupDockerCompose: ## Deletes the registry and gitea
	$(call runScript, cleanupDockerCompose)

wipeState: cleanup wipeGiteState wipeRegistryState ## Resets all the state for gitea and registry

wipeGiteState: ## Remove all gitea state
	$(call runScript, wipeGiteaState)

wipeRegistryState: ## Remove all registry state
	$(call runScript, wipeRegistryState)

testRegistry: ## Tests to make sure you can push images to the registry
	$(call runScript, testRegistry)
