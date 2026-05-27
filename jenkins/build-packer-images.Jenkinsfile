// jenkins/build-packer-images.Jenkinsfile
//
// Builds and publishes Packer OS images for all non-eol tracks in versions.yml.
// Handles packer-cloud-init and packer-discovery build types.
// Shared helpers come from the sarins-lab-pipeline library in vars/ and src/.
//
// Required Jenkins credentials (Manage Jenkins → Credentials):
//   registry-ghcr             — Username/Password  (GHCR, cloud-init ORAS push)
//   registry-nexus            — Username/Password  (Nexus ORAS push)
//   pki-root-ca-cert          — Secret file        (pki/root-ca.crt)
//   pki-discovery-enroll-cert — Secret file        (pki/discovery-enrollment.crt)
//   pki-discovery-enroll-key  — Secret file        (pki/discovery-enrollment.key)
//
// Required agent label: packer
// Agent must have: packer >= 1.11, qemu-system-x86_64, oras

@Library('sarins-lab-pipeline') _

def SKIP = ['eol']

pipeline {
    agent { label 'packer' }

    options {
        ansiColor('xterm')
        buildDiscarder(logRotator(numToKeepStr: '5'))
        timeout(time: 4, unit: 'HOURS')
    }

    parameters {
        string(
            name: 'VERSION',
            defaultValue: '',
            description: 'Semver (e.g. v1.2.3). Leave blank to use the latest git tag.'
        )
        booleanParam(
            name: 'DRY_RUN',
            defaultValue: false,
            description: 'Build images but skip push to any registry.'
        )
        booleanParam(
            name: 'BUILD_CLOUD_INIT',
            defaultValue: true,
            description: 'Build packer-cloud-init tracks.'
        )
        booleanParam(
            name: 'BUILD_DISCOVERY',
            defaultValue: true,
            description: 'Build packer-discovery tracks (requires PKI credentials).'
        )
        string(
            name: 'TRACK_FILTER',
            defaultValue: '',
            description: 'Comma-separated OS suffix list (e.g. ubuntu24,rocky9). Empty = all active.'
        )
    }

    environment {
        VERSIONS_FILE     = 'versions.yml'
        PACKER_LOG        = '1'
        PACKER_LOG_PATH   = '.packer/packer.log'
        PACKER_OUTPUT_DIR = '.packer/output'
    }

    stages {

        stage('Prepare') {
            steps {
                script {
                    sh 'mkdir -p .packer/output'
                    env.BUILD_VERSION = resolveVersion(params.VERSION)
                    env.FILTER_LIST   = params.TRACK_FILTER?.trim() ?: ''
                    echo "Version          : ${env.BUILD_VERSION}"
                    echo "Filter           : ${env.FILTER_LIST ?: '(all active tracks)'}"
                    echo "Build cloud-init : ${params.BUILD_CLOUD_INIT}"
                    echo "Build discovery  : ${params.BUILD_DISCOVERY}"
                    echo "Dry-run          : ${params.DRY_RUN}"
                    sh 'packer version && oras version'
                }
            }
        }

        stage('Packer Init') {
            steps {
                sh '''
                    for tmpl in packer/*.pkr.hcl; do
                        echo "--- packer init ${tmpl} ---"
                        packer init "${tmpl}" || true
                    done
                '''
            }
        }

        stage('Build Cloud-Init Templates') {
            when { expression { return params.BUILD_CLOUD_INIT } }
            steps {
                script {
                    def versions     = readYaml(file: env.VERSIONS_FILE)
                    def filterSet    = env.FILTER_LIST
                        ? env.FILTER_LIST.split(',').collect { it.trim() } as Set : null
                    def parallelJobs = [:]

                    withCredentials([file(credentialsId: 'pki-root-ca-cert', variable: 'ROOT_CA_CERT')]) {
                        versions.tracks.each { track ->
                            if (track.status in SKIP) return
                            if (filterSet && !(track.suffix in filterSet)) return

                            track.builds.each { build ->
                                if (build.type != 'packer-cloud-init') return

                                def t = track
                                def b = build

                                b.platforms.each { platform ->
                                    def outDir  = "${env.PACKER_OUTPUT_DIR}/${t.suffix}-cloud-init-${platform}"
                                    def outFile = "${outDir}/disk.qcow2"
                                    def image   = "cloud-init-${t.suffix}-${platform}"

                                    parallelJobs["cloud-init/${t.suffix}/${platform}"] = {
                                        sh "mkdir -p ${outDir}"
                                        sh """
                                            packer build \\
                                              -var 'root_ca_cert=${ROOT_CA_CERT}' \\
                                              -var 'output_directory=${outDir}' \\
                                              -var 'os_variant=${t.suffix}' \\
                                              -var 'arch=${platform}' \\
                                              ${b.template}
                                        """
                                        if (!params.DRY_RUN) {
                                            b.publish.each { reg ->
                                                orasPush(
                                                    registry    : reg,
                                                    image       : image,
                                                    version     : env.BUILD_VERSION,
                                                    filePath    : outFile,
                                                    mediaType   : 'application/vnd.sarins-lab.qcow2',
                                                    registryMap : org.sarinslab.Registry.PACKER,
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        parallelJobs ? parallel(parallelJobs) : echo('No packer-cloud-init tracks found.')
                    }
                }
            }
        }

        stage('Build Discovery Images') {
            when { expression { return params.BUILD_DISCOVERY } }
            steps {
                script {
                    def versions     = readYaml(file: env.VERSIONS_FILE)
                    def filterSet    = env.FILTER_LIST
                        ? env.FILTER_LIST.split(',').collect { it.trim() } as Set : null
                    def parallelJobs = [:]

                    withCredentials([
                        file(credentialsId: 'pki-root-ca-cert',          variable: 'ROOT_CA_CERT'),
                        file(credentialsId: 'pki-discovery-enroll-cert', variable: 'DISCOVERY_CERT'),
                        file(credentialsId: 'pki-discovery-enroll-key',  variable: 'DISCOVERY_KEY'),
                    ]) {
                        versions.tracks.each { track ->
                            if (track.status in SKIP) return
                            if (filterSet && !(track.suffix in filterSet)) return

                            track.builds.each { build ->
                                if (build.type != 'packer-discovery') return

                                def t = track
                                def b = build

                                b.platforms.each { platform ->
                                    def ext     = b.outputs.contains('img') ? 'img' : 'qcow2'
                                    def outDir  = "${env.PACKER_OUTPUT_DIR}/${t.suffix}-discovery-${platform}"
                                    def outFile = "${outDir}/disk.${ext}"
                                    def image   = "discovery-${t.suffix}-${platform}"

                                    parallelJobs["discovery/${t.suffix}/${platform}"] = {
                                        sh "mkdir -p ${outDir}"
                                        sh """
                                            packer build \\
                                              -var 'root_ca_cert=${ROOT_CA_CERT}' \\
                                              -var 'discovery_enrollment_cert=${DISCOVERY_CERT}' \\
                                              -var 'discovery_enrollment_key=${DISCOVERY_KEY}' \\
                                              -var 'genie_endpoint=${env.GENIE_ENDPOINT ?: ''}' \\
                                              -var 'output_directory=${outDir}' \\
                                              -var 'os_variant=${t.suffix}' \\
                                              -var 'arch=${platform}' \\
                                              ${b.template}
                                        """
                                        if (!params.DRY_RUN) {
                                            b.publish.each { reg ->
                                                orasPush(
                                                    registry    : reg,
                                                    image       : image,
                                                    version     : env.BUILD_VERSION,
                                                    filePath    : outFile,
                                                    mediaType   : "application/vnd.sarins-lab.${ext}",
                                                    registryMap : org.sarinslab.Registry.PACKER,
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        parallelJobs ? parallel(parallelJobs) : echo('No packer-discovery tracks found.')
                    }
                }
            }
        }

    }

    post {
        always {
            archiveArtifacts(artifacts: '.packer/packer.log', allowEmptyArchive: true)
            logoutAllRegistries()
        }
        cleanup {
            sh 'rm -rf .packer/output || true'
        }
    }
}
