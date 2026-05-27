// Log in to a named registry using the standard Jenkins credential for that registry.
// Registry names and credential IDs are defined in src/org/sarinslab/Registry.groovy.
//
// Usage:
//   loginRegistry('ghcr')
//   loginRegistry('nexus')
def call(String registry) {
    def r = org.sarinslab.Registry.get(registry)
    withCredentials([usernamePassword(
        credentialsId: r.credId,
        usernameVariable: 'REG_USER',
        passwordVariable: 'REG_PASS'
    )]) {
        sh "echo \${REG_PASS} | docker login ${r.host} -u \${REG_USER} --password-stdin"
    }
}
