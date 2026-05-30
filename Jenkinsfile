@Library('sarins-lab-pipeline') _
import com.sarinslab.pipeline.events.EventType

// Jenkinsfile — Build, scan, sign, and publish Lab Platform images
//
// Drives the repo's EXISTING versions.yml-based tooling (do NOT reinvent the
// build matrix here): scripts/images_from_versions.py via the Makefile targets
// build-all / list-images / trivy-images. Then pushes, cosign-signs by digest,
// and emits images.build.completed on the platform event bus.
//
// Environment-agnostic: same flow on the rehearsal rig and real infra; only
// REGISTRY / TARGET_ENV / correlation id differ.

// Collected across stages: [{ref, digest, signature}, ...] — signed images only.
def signedImages = []

pipeline {
  agent any

  parameters {
    string(name: 'CORRELATION_ID', defaultValue: '', description: 'Flow correlation id (set by orchestrator; falls back to BUILD_TAG)')
    string(name: 'REGISTRY', defaultValue: 'localhost:5000', description: 'Docker registry URL (override per environment)')
    string(name: 'TARGET_ENV', defaultValue: 'bootstrap', description: 'bootstrap|dev|staging|prod')
    string(name: 'IMAGE_VERSION', defaultValue: '1.0.0', description: 'VERSION passed to versions.yml tooling')
  }

  environment {
    REGISTRY = "${params.REGISTRY ?: 'localhost:5000'}"
    COSIGN_KEY = "${env.COSIGN_KEY ?: 'cosign.key'}"
    CORRELATION_ID = "${params.CORRELATION_ID ?: env.BUILD_TAG}"
    // Trivy gate: fail the build on findings (override existing default of 0).
    TRIVY_EXIT_CODE = "${env.TRIVY_EXIT_CODE ?: '1'}"
  }

  options {
    buildDiscarder(logRotator(numToKeepStr: '30'))
    timeout(time: 2, unit: 'HOURS')
    timestamps()
  }

  stages {
    stage('Checkout') {
      steps {
        echo "Checkout docker-images (correlation_id=${env.CORRELATION_ID}, target=${params.TARGET_ENV})"
        checkout scm
      }
    }

    stage('Build Images') {
      // Delegate to versions.yml tooling: build-base -> build-tools -> build-agents.
      steps {
        sh 'make build-all VERSION=${IMAGE_VERSION}'
      }
    }

    stage('Scan Images') {
      // Trivy gate over the freshly built images (fails per TRIVY_EXIT_CODE).
      steps {
        sh 'make trivy-images VERSION=${IMAGE_VERSION} TRIVY_EXIT_CODE=${TRIVY_EXIT_CODE}'
      }
    }

    stage('Publish + Sign') {
      // Enumerate the authoritative tag set from versions.yml, then retag to the
      // target registry, push, and cosign-sign by immutable digest.
      steps {
        script {
          String listing = sh(returnStdout: true, label: 'list-images',
            script: 'make --no-print-directory list-images VERSION=${IMAGE_VERSION}').trim()

          // Each non-empty, non-log line is a local image tag (name:tag).
          def localTags = listing.readLines()
            .collect { it.trim() }
            .findAll { it && it.contains(':') && !it.startsWith('make') && !it.startsWith('=') }

          if (!localTags) {
            error("list-images produced no image tags — check versions.yml tooling output")
          }

          for (localTag in localTags) {
            String name = localTag.tokenize(':')[0].tokenize('/').last()
            String tag = localTag.tokenize(':').last()
            String remote = "${env.REGISTRY}/${name}:${tag}"

            sh(label: "push ${name}", script: """
              set -euo pipefail
              docker tag '${localTag}' '${remote}'
              docker push '${remote}'
            """)

            String digestRef = sh(returnStdout: true, label: "digest ${name}",
              script: "docker inspect --format '{{index .RepoDigests 0}}' '${remote}'").trim()

            sh(label: "cosign sign ${name}", script: """
              set -euo pipefail
              COSIGN_PASSWORD="\${COSIGN_PASSWORD:-}" cosign sign --yes --key '${env.COSIGN_KEY}' '${digestRef}'
            """)

            signedImages << [ref: remote, digest: digestRef, signature: "${digestRef}.sig"]
            echo "signed ${digestRef}"
          }
        }
      }
    }

    stage('Emit Completion Event') {
      steps {
        script {
          emitPlatformEvent(EventType.IMAGES_BUILD_COMPLETED, [
            repo    : 'infra/docker-images',
            build_id: env.BUILD_ID,
            images  : signedImages
          ])
        }
      }
    }
  }

  post {
    success {
      echo "✓ Built, scanned, signed, pushed ${signedImages.size()} image(s); images.build.completed emitted"
    }
    failure {
      script {
        reportStatus('failure', [stage: env.STAGE_NAME ?: 'unknown', reason: 'docker-images build/scan/sign/push failed'])
      }
    }
    always {
      cleanWs()
    }
  }
}
