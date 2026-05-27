// Read the OCI image title from a Dockerfile's org.opencontainers.image.title label.
//
// Usage:
//   def name = imageNameFrom('ubuntu.dockerfile')
def call(String dockerfile) {
    return sh(
        script: "grep -m1 'org.opencontainers.image.title' ${dockerfile} | sed 's/.*=\"//;s/\"//'",
        returnStdout: true
    ).trim()
}
