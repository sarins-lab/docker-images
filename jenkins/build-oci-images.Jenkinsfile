// jenkins/build-oci-images.Jenkinsfile
//
// Builds and publishes OCI container images for all non-eol tracks in versions.yml.
// Shared helpers (registry auth, buildx, version resolution) come from the
// sarins-lab-pipeline library defined in vars/ and src/ of this repo.
//
// Required Jenkins credentials (Manage Jenkins → Credentials):
//   registry-ghcr      — Username/Password  (GitHub PAT with packages:write)
//   registry-nexus     — Username/Password  (Nexus deploy user)
//   registry-dockerhub — Username/Password  (Docker Hub)       [optional]
//   registry-quay      — Username/Password  (Quay.io)          [optional]

@Library('sarins-lab-pipeline') _

def SKIP = ['eol']

pipeline {
    agent any

    options {
        ansiColor('xterm')
        buildDiscarder(logRotator(numToKeepStr: '10'))
        timeout(time: 2, unit: 'HOURS')
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
            name: 'SKIP_SCAN',
            defaultValue: false,
            description: 'Skip Trivy vulnerability scan after build.'
        )
        string(
            name: 'TRACK_FILTER',
            defaultValue: '',
            description: 'Comma-separated suffix list to limit builds (e.g. ubuntu24,alpine322). Empty = all active.'
        )
    }

    environment {
        VERSIONS_FILE = 'versions.yml'
    }

    stages {

        stage('Prepare') {
            steps {
                script {
                    env.BUILD_VERSION = resolveVersion(params.VERSION)
                    env.FILTER_LIST   = params.TRACK_FILTER?.trim() ?: ''
                    echo "Version : ${env.BUILD_VERSION}"
                    echo "Filter  : ${env.FILTER_LIST ?: '(all active tracks)'}"
                    echo "Dry-run : ${params.DRY_RUN}"
                }
            }
        }

        stage('Setup Buildx') {
            steps {
                script { setupDockerBuildx() }
            }
        }

        stage('Build Base Images') {
            steps {
                script {
                    def versions     = readYaml(file: env.VERSIONS_FILE)
                    def filterSet    = env.FILTER_LIST
                        ? env.FILTER_LIST.split(',').collect { it.trim() } as Set : null
                    def parallelJobs = [:]

                    versions.tracks.each { track ->
                        if (track.status in SKIP) return
                        if (filterSet && !(track.suffix in filterSet)) return

                        track.builds.each { build ->
                            if (build.type != 'oci') return

                            def t      = track
                            def b      = build
                            def jobKey = "base/${t.suffix}"

                            parallelJobs[jobKey] = {
                                def name      = imageNameFrom(b.dockerfile)
                                def platforms = b.platforms.join(',')
                                def buildArg  = b['build-arg'] ? "--build-arg ${b['build-arg']}" : ''
                                def tags      = []

                                if (params.DRY_RUN) {
                                    tags << "--tag sarins-lab-local/${name}:dry-run-${t.suffix}"
                                } else {
                                    b.publish.each { reg ->
                                        loginRegistry(reg)
                                        tags << "--tag ${org.sarinslab.Registry.ref(reg, name, "${env.BUILD_VERSION}-${t.suffix}")}"
                                        tags << "--tag ${org.sarinslab.Registry.ref(reg, name, "latest-${t.suffix}")}"
                                    }
                                }

                                sh """
                                    docker buildx build \\
                                      --platform ${platforms} \\
                                      ${buildArg} \\
                                      ${tags.join(' \\\n                      ')} \\
                                      ${params.DRY_RUN ? '' : '--push'} \\
                                      --label org.opencontainers.image.revision=\$(git rev-parse HEAD) \\
                                      --label org.opencontainers.image.version=${env.BUILD_VERSION} \\
                                      -f ${b.dockerfile} .
                                """
                            }
                        }
                    }

                    parallelJobs ? parallel(parallelJobs) : echo('No base OCI tracks to build.')
                }
            }
        }

        stage('Build Tool Images') {
            steps {
                script {
                    def versions  = readYaml(file: env.VERSIONS_FILE)
                    def filterSet = env.FILTER_LIST
                        ? env.FILTER_LIST.split(',').collect { it.trim() } as Set : null

                    def baseNames = [:]
                    versions.tracks.each { track ->
                        track.builds.each { build ->
                            if (build.type == 'oci') baseNames[track.suffix] = imageNameFrom(build.dockerfile)
                        }
                    }

                    def parallelJobs = [:]

                    versions['tool-tracks'].each { tool ->
                        if (tool.status in SKIP) return
                        if (filterSet && !(tool.track in filterSet)) return

                        def t = tool

                        parallelJobs["tool/${t.track}"] = {
                            def name       = imageNameFrom(t.dockerfile)
                            def baseSuffix = t['base-suffix']
                            def firstReg   = t.publish[0]
                            def baseRef    = org.sarinslab.Registry.ref(firstReg, baseNames[baseSuffix], "${env.BUILD_VERSION}-${baseSuffix}")
                            def platforms  = t.platforms.join(',')
                            def tags       = []

                            if (params.DRY_RUN) {
                                tags << "--tag sarins-lab-local/${name}:dry-run-${t.track}"
                            } else {
                                t.publish.each { reg ->
                                    loginRegistry(reg)
                                    tags << "--tag ${org.sarinslab.Registry.ref(reg, name, "${env.BUILD_VERSION}-${baseSuffix}")}"
                                    tags << "--tag ${org.sarinslab.Registry.ref(reg, name, "latest-${baseSuffix}")}"
                                }
                            }

                            sh """
                                docker buildx build \\
                                  --platform ${platforms} \\
                                  --build-arg BASE_IMAGE=${baseRef} \\
                                  ${tags.join(' \\\n                      ')} \\
                                  ${params.DRY_RUN ? '' : '--push'} \\
                                  --label org.opencontainers.image.revision=\$(git rev-parse HEAD) \\
                                  --label org.opencontainers.image.version=${env.BUILD_VERSION} \\
                                  -f ${t.dockerfile} .
                            """
                        }
                    }

                    parallelJobs ? parallel(parallelJobs) : echo('No tool OCI tracks to build.')
                }
            }
        }

        stage('Build Agent Images') {
            steps {
                script {
                    def versions  = readYaml(file: env.VERSIONS_FILE)
                    def filterSet = env.FILTER_LIST
                        ? env.FILTER_LIST.split(',').collect { it.trim() } as Set : null

                    def baseNames = [:]
                    versions.tracks.each { track ->
                        track.builds.each { build ->
                            if (build.type == 'oci') baseNames[track.suffix] = imageNameFrom(build.dockerfile)
                        }
                    }

                    def parallelJobs = [:]

                    versions['agent-tracks'].each { agent ->
                        if (agent.status in SKIP) return
                        if (filterSet && !(agent.track in filterSet)) return

                        def a = agent

                        parallelJobs["agent/${a.track}"] = {
                            def name       = imageNameFrom(a.dockerfile)
                            def baseSuffix = a['base-suffix']
                            def firstReg   = a.publish[0]
                            def baseRef    = org.sarinslab.Registry.ref(firstReg, baseNames[baseSuffix], "${env.BUILD_VERSION}-${baseSuffix}")
                            def platforms  = a.platforms.join(',')
                            def tags       = []

                            if (params.DRY_RUN) {
                                tags << "--tag sarins-lab-local/${name}:dry-run-${a.track}"
                            } else {
                                a.publish.each { reg ->
                                    loginRegistry(reg)
                                    tags << "--tag ${org.sarinslab.Registry.ref(reg, name, "${env.BUILD_VERSION}-${a.track}")}"
                                    tags << "--tag ${org.sarinslab.Registry.ref(reg, name, "latest-${a.track}")}"
                                }
                            }

                            sh """
                                docker buildx build \\
                                  --platform ${platforms} \\
                                  --build-arg BASE_IMAGE=${baseRef} \\
                                  ${tags.join(' \\\n                      ')} \\
                                  ${params.DRY_RUN ? '' : '--push'} \\
                                  --label org.opencontainers.image.revision=\$(git rev-parse HEAD) \\
                                  --label org.opencontainers.image.version=${env.BUILD_VERSION} \\
                                  -f ${a.dockerfile} .
                            """
                        }
                    }

                    parallelJobs ? parallel(parallelJobs) : echo('No agent tracks to build.')
                }
            }
        }

        stage('Scan') {
            when {
                allOf {
                    not { expression { return params.DRY_RUN } }
                    not { expression { return params.SKIP_SCAN } }
                }
            }
            steps {
                sh """
                    python3 scripts/trivy_images.py \\
                      --versions-file ${env.VERSIONS_FILE} \\
                      --version ${env.BUILD_VERSION} \\
                      --git-sha \$(git rev-parse HEAD) \\
                      --ignore-file .trivyignore \\
                      --severity HIGH,CRITICAL \\
                      --ignore-unfixed
                """
                archiveArtifacts(artifacts: '.trivy/results/**', allowEmptyArchive: true)
            }
        }
    }

    post {
        always { logoutAllRegistries() }
    }
}
