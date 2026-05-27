// Resolve build version from a parameter or the latest git tag.
// Strips a leading 'v' so the result is always a bare semver string.
//
// Usage:
//   env.BUILD_VERSION = resolveVersion(params.VERSION)
def call(String versionParam = '') {
    if (versionParam?.trim()) {
        return versionParam.trim().replaceAll(/^v/, '')
    }
    return sh(
        script: 'git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0-dev"',
        returnStdout: true
    ).trim().replaceAll(/^v/, '')
}
