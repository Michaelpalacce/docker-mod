#!/bin/bash
# Inspired by: https://github.com/linuxserver/docker-mods/blob/mod-scripts/docker-mods.v3
# POC works with dockerhub only

# Exit immediately if a command exits with a non-zero status.
# set -e

# get_architecture will check `uname -m` and based on that map it to docker's expected architecture convention
get_architecture() {
    case "$(uname -m)" in
        "x86_64") ARCH="amd64" ;;
        "aarch64") ARCH="arm64" ;;
        "ppc64le") ARCH="ppc64le" ;;
        *) ARCH="unknown" ;;
    esac

    echo $ARCH
    return 0
}

get_registry_auth_url() {
    if [[ -z $1 ]] then
        echo "get_registry_auth_url expects the docker image as a parameter, but none were passed" 1>&2
        exit 1
    fi

    REGISTRY_AUTH_URL="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${1}:pull"
    echo $REGISTRY_AUTH_URL
    return 0
}

get_registry_api_url() {
    if [[ -z $1 ]] then
        echo "get_registry_api_url expects the docker image as a parameter, but none were passed" 1>&2
        exit 1
    fi

    REGISTRY_API_URL="https://registry-1.docker.io/v2/${1}"
    echo $REGISTRY_API_URL
    return 0
}

# get_auth_token is used to retrieve an authentication token for the given repo.
# The Docker API requires this
get_auth_token() {
    if [[ -z $1 ]] then
        echo "get_auth_token expects the docker image as a parameter, but none were passed" 1>&2
        exit 1
    fi

    REGISTRY_AUTH_URL=$(get_registry_auth_url $1)
    REGISTRY_API_URL=$(get_registry_api_url $1)

    echo "Fetching authentication token... 🔑"
    TOKEN=$(curl -s -f "${REGISTRY_AUTH_URL}" | jq -r '.token')

    if [ -z "${TOKEN}" ]; then
        echo "❌ Error: Failed to fetch authentication token. Cannot download mod."
        exit 1
    fi

    echo $TOKEN
    return 0
}

# apply_mod will download and execute the docker mod.
apply_mod() {
    TOKEN=$(get_auth_token $1)
    REGISTRY_AUTH_URL=$(get_registry_auth_url $1)
    REGISTRY_API_URL=$(get_registry_api_url $1)
    echo $REGISTRY_API_URL
    echo $REGISTRY_AUTH_URL

    echo "Fetching image manifest... 📄"
    MANIFEST=$(curl -v -H "Accept: application/vnd.oci.image.index.v1+json" -H "Authorization: Bearer ${TOKEN}" "${REGISTRY_API_URL}/manifests/latest")

    echo 1

    ARCH=$(get_architecture)

    SPECIFIC_MANIFEST_DIGEST=$(echo "${MANIFEST}" | jq -r --arg ARCHITECTURE "${ARCH}" '.manifests[] | select(.platform.architecture == $ARCHITECTURE) | .digest')

    if [ -z "${SPECIFIC_MANIFEST_DIGEST}" ]; then
        echo "❌ Error: Could not find manifest for ${ARCH} architecture."
        exit 1
    fi

    echo "Fetching architecture-specific manifest... 💻"
    ARCH_MANIFEST=$(curl -s -f -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        -H "Authorization: Bearer ${TOKEN}" \
        "${REGISTRY_API_URL}/manifests/${SPECIFIC_MANIFEST_DIGEST}")

    LAYER_DIGEST=$(echo "${ARCH_MANIFEST}" | jq -r '.layers[0].digest')

    if [ -z "${LAYER_DIGEST}" ]; then
        echo "❌ Error: Could not find layer digest in manifest. Cannot download mod."
        exit 1
    fi

    echo "Found layer digest: ${LAYER_DIGEST} ✅"

    echo "Downloading mod layer... 📥"
    TEMP_MOD_DIR=$(mktemp -d)
    curl -s -f -L -H "Authorization: Bearer ${TOKEN}" \
        "${REGISTRY_API_URL}/blobs/${LAYER_DIGEST}" \
        > "${TEMP_MOD_DIR}/mod.tar"

    echo "Extracting to ${TEMP_MOD_DIR} and running mod script... 🚀"
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
