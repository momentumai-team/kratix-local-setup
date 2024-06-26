#!/bin/bash -e
LB_IP=$(kubectl --context kind-platform -n kratix-platform-system get svc/minio -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')
mc alias set kratix http://$LB_IP:80 minioadmin minioadmin
mc ls -r kratix
