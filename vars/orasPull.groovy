// Pull an OCI artifact from a named registry via ORAS.
// Consuming repos (devops, controller) use this to fetch Packer images or
// other artifacts published by the images pipeline.
//
// Usage:
//   orasPull(
//     registry  : 'nexus',
//     image     : 'cloud-init-ubuntu24-amd64',
//     version   : '1.2.3',
//     outputDir : './artifacts',
//   )
def call(Map config) {
    def regMap = config.registryMap ?: org.sarinslab.Registry.ALL
    def r      = org.sarinslab.Registry.get(config.registry, regMap)
    def outDir = config.outputDir ?: '.'

    withCredentials([usernamePassword(
        credentialsId: r.credId,
        usernameVariable: 'REG_USER',
        passwordVariable: 'REG_PASS'
    )]) {
        sh """
            echo \${REG_PASS} | oras login ${r.host} -u \${REG_USER} --password-stdin
            mkdir -p ${outDir}
            oras pull ${r.host}/${r.org}/${config.image}:${config.version} --output ${outDir}
        """
    }
}
