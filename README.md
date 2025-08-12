# How to run a docker mod

This script allows for storing files in a docker registry for the purpose of applying a runtime patch to an image.

## Build the mod to have it

```sh
docker buildx build . -t stefangenov/test-mod --push 
```

## Running it

```sh
DOCKER_MODS=stefangenov/test-mod ./mod_runner.sh 2>out.log
```


