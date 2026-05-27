// Create (or reuse) a named Docker buildx builder with QEMU binfmt support
// for multi-arch builds. Idempotent — safe to call on every pipeline run.
//
// Usage:
//   setupDockerBuildx()                          // uses default builder name
//   setupDockerBuildx('my-custom-builder')       // custom name
def call(String builderName = 'sarins-lab-multiarch') {
    sh """
        docker run --rm --privileged multiarch/qemu-user-static --reset -p yes || true
        docker buildx inspect ${builderName} >/dev/null 2>&1 || \
          docker buildx create --name ${builderName} --driver docker-container --bootstrap
        docker buildx use ${builderName}
        docker buildx inspect --bootstrap
    """
}
