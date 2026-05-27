// Log out of all known registries. Intended for post { always { } } blocks.
//
// Usage:
//   logoutAllRegistries()
def call() {
    sh '''
        docker logout ghcr.io               || true
        docker logout nexus.mgt.sarins.info  || true
        docker logout registry-1.docker.io   || true
        docker logout quay.io                || true
        oras   logout ghcr.io               || true
        oras   logout nexus.mgt.sarins.info  || true
    '''
}
