#!/bin/bash
# Inspired by: https://github.com/linuxserver/docker-mods/blob/mod-scripts/docker-mods.v3
# POC works with dockerhub only

# Exit immediately if a command exits with a non-zero status.
set -o errexit
set -o pipefail
# set -o verbose
set -o xtrace

# get_architecture will check `uname -m` and based on that map it to docker's expected architecture convention
get_architecture() {
    case "$(uname -m)" in
        "x86_64") ARCH="amd64" ;;
        "aarch64") ARCH="arm64" ;;
        "ppc64le") ARCH="ppc64le" ;;
        *) ARCH="unknown" ;;
    esac

    echo -n $ARCH
    return 0
}

get_registry_auth_url() {
    IMAGE=$1
    if [[ -z $IMAGE ]] then
        echo "get_registry_auth_url expects the docker image as a parameter, but none were passed" 1>&2
        exit 1
    fi

    REGISTRY_AUTH_URL="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${IMAGE}:pull"
    echo -n $REGISTRY_AUTH_URL
    return 0
}

get_registry_api_url() {
    IMAGE=$1
    if [[ -z $IMAGE ]] then
        echo "get_registry_api_url expects the docker image as a parameter, but none were passed" 1>&2
        exit 1
    fi

    REGISTRY_API_URL="https://registry-1.docker.io/v2/${IMAGE}"
    echo -n $REGISTRY_API_URL
    return 0
}

get_auth_token() {
    IMAGE=$1
    if [[ -z $1 ]] then
        echo "get_auth_token expects the docker image as a parameter, but none were passed" 1>&2
        exit 1
    fi
    
    REGISTRY_AUTH_URL=$(get_registry_auth_url $IMAGE)
    TOKEN=$(curl -s -f "${REGISTRY_AUTH_URL}" | jq -r '.token')

    if [ -z "${TOKEN}" ]; then
        echo "❌ Error: Failed to fetch authentication token. Cannot download mod."
        exit 1
    fi
    echo -n $TOKEN
    return 0
}

# get_manifest_sha will retrieve the correct sha of the layer to download
# $1 is the image
# $2 is the token
get_layer_sha() {
    IMAGE=$1
    TOKEN=$2
    REGISTRY_API_URL=$(get_registry_api_url $IMAGE)
    MANIFEST=$(curl -s -f -H "Accept: application/vnd.oci.image.index.v1+json" -H "Authorization: Bearer ${TOKEN}" "${REGISTRY_API_URL}/manifests/latest")

    ARCH=$(get_architecture)

    SPECIFIC_MANIFEST_DIGEST=$(echo "${MANIFEST}" | jq -r --arg ARCHITECTURE "${ARCH}" '.manifests[] | select(.platform.architecture == $ARCHITECTURE) | .digest')

    if [ -z "${SPECIFIC_MANIFEST_DIGEST}" ]; then
        echo "❌ Error: Could not find manifest for ${ARCH} architecture."
        exit 1
    fi

    ARCH_MANIFEST=$(curl -s -f -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        -H "Authorization: Bearer ${TOKEN}" \
        "${REGISTRY_API_URL}/manifests/${SPECIFIC_MANIFEST_DIGEST}")

    LAYER_DIGEST=$(echo "${ARCH_MANIFEST}" | jq -r '.layers[0].digest')

    if [ -z "${LAYER_DIGEST}" ]; then
        echo "❌ Error: Could not find layer digest in manifest. Cannot download mod."
        exit 1
    fi

    echo -n $LAYER_DIGEST
    return 0
}

# download_mod_layer will download the correct layer that holds the mod files in a temp folder
# $1 is the IMAGE
# $2 is the TOKEN
# $3 is the layer digest see get_layer_sha
# RETURNS the temp folder location
download_mod_layer() {
    IMAGE=$1
    TOKEN=$2
    LAYER_DIGEST=$3
    TEMP_MOD_DIR=$(mktemp -d)
    REGISTRY_API_URL=$(get_registry_api_url $IMAGE)
    curl -s -f -L -H "Authorization: Bearer ${TOKEN}" \
        "${REGISTRY_API_URL}/blobs/${LAYER_DIGEST}" \
        > "${TEMP_MOD_DIR}/mod.tar"

    echo -n $TEMP_MOD_DIR
    return 0
}

# do_apply_mod extracts the `mod.tar` from the temp folder and executes it. Expects the mod folder to contain a `mod.sh`
# $1 TEMP_MOD_DIR is the temp location where the mod was downloaded
do_apply_mod() {
    TEMP_MOD_DIR=$1
    echo $TEMP_MOD_DIR
    tar -xf "${TEMP_MOD_DIR}/mod.tar" -C "${TEMP_MOD_DIR}"

    if [ -f "${TEMP_MOD_DIR}/mod/mod.sh" ]; then
        chmod +x "${TEMP_MOD_DIR}/mod/mod.sh"
        cd ${TEMP_MOD_DIR}/mod
        echo "============================== SCRIPT START 📜 =============================="
        "${TEMP_MOD_DIR}/mod/mod.sh"
        echo "============================== SCRIPT END 🏁 =============================="
        cd -
    else
        echo "⚠️ Warning: Mod script not found at ${TEMP_MOD_DIR}/mod/mod.sh"
    fi
}


# apply_mod will download and execute the docker mod.
# $1 is the IMAGE name eg stefangenov/test-mod
apply_mod() {
    IMAGE=$1

    echo "Fetching authentication token... ✅"
    TOKEN=$(get_auth_token $IMAGE)

    echo "Fetching architecture-specific layer manifest for image $IMAGE... ✅"
    LAYER_DIGEST=$(get_layer_sha $IMAGE $TOKEN)
    echo "Found layer digest: ${LAYER_DIGEST} ✅"

    echo "Downloading mod layer... ✅"
    TEMP_MOD_DIR=$(download_mod_layer $IMAGE $TOKEN $LAYER_DIGEST)

    echo "Extracting to ${TEMP_MOD_DIR} and running mod script... 🚀"
    do_apply_mod $TEMP_MOD_DIR

    echo "Cleaning up ${TEMP_MOD_DIR} ✅"
    rm -rf "${TEMP_MOD_DIR}"
}

if [ ! -z "${DOCKER_MODS}" ]; then
    echo "DOCKER_MODS variable found. Attempting to apply mod(s) from Docker Hub... 🐳"
    # @TODO: Split the mods, csv
    apply_mod $DOCKER_MODS
else
    echo "❌ DOCKER_MODS env variable is required. Example: stefangenov/test-mod"
    exit 1
fi
