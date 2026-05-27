// Push a file as an OCI artifact to a named registry via ORAS.
// Registry names and credential IDs are defined in src/org/sarinslab/Registry.groovy.
//
// Usage:
//   orasPush(
//     registry  : 'nexus',
//     image     : 'cloud-init-ubuntu24-amd64',
//     version   : '1.2.3',
//     filePath  : '.packer/output/disk.qcow2',
//     mediaType : 'application/vnd.sarins-lab.qcow2',
//   )
//
// Optional:
//   registryMap : org.sarinslab.Registry.PACKER  (use packer-specific org path)
def call(Map config) {
    def regMap = config.registryMap ?: org.sarinslab.Registry.ALL
    def r      = org.sarinslab.Registry.get(config.registry, regMap)

    withCredentials([usernamePassword(
        credentialsId: r.credId,
        usernameVariable: 'REG_USER',
        passwordVariable: 'REG_PASS'
    )]) {
        sh """
            echo \${REG_PASS} | oras login ${r.host} -u \${REG_USER} --password-stdin
            oras push ${r.host}/${r.org}/${config.image}:${config.version} \\
              --artifact-type application/vnd.sarins-lab.packer-image.v1 \\
              ${config.filePath}:${config.mediaType}
        """
    }
}
