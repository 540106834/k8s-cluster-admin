#!/bin/bash
set -e

HARBOR="harbor.jinshaoyong.com"
PROJECT="k8s"

images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep registry.k8s.io)

for img in ${images}
do
    # 提取 image name + tag
    repo=$(echo ${img} | awk -F: '{print $1}')
    tag=$(echo ${img} | awk -F: '{print $2}')

    # 提取最后一段作为名称
    name=$(basename ${repo})

    target="${HARBOR}/${PROJECT}/${name}:${tag}"

    echo "[TAG] ${img} -> ${target}"
    docker tag ${img} ${target}

    echo "[PUSH] ${target}"
    docker push ${target}
done

echo "DONE"