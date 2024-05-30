#!/bin/bash -e
docker pull busybox
docker tag busybox 127.0.0.1:30500/busybox
docker push 127.0.0.1:30500/busybox
