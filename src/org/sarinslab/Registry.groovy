package org.sarinslab

// Single source of truth for all registry coordinates used across pipelines.
// Any Jenkinsfile that loads the sarins-lab-pipeline library can reference this.
//
// Credential IDs are Jenkins credential store IDs (Manage Jenkins → Credentials).
// Add the credential once; every pipeline inherits it from here.

class Registry implements Serializable {

    static final Map<String, Map<String, String>> ALL = [
        'ghcr'      : [host: 'ghcr.io',               org: 'sarins-lab', credId: 'registry-ghcr'],
        'nexus'     : [host: 'nexus.mgt.sarins.info',  org: 'docker',     credId: 'registry-nexus'],
        'docker.io' : [host: 'registry-1.docker.io',   org: 'sarinlab',   credId: 'registry-dockerhub'],
        'quay.io'   : [host: 'quay.io',                org: 'sarinlab',   credId: 'registry-quay'],
    ]

    // Packer artifacts are stored under a separate org path in Nexus.
    static final Map<String, Map<String, String>> PACKER = ALL + [
        'nexus' : [host: 'nexus.mgt.sarins.info', org: 'packer', credId: 'registry-nexus'],
    ]

    static Map<String, String> get(String name, Map<String, Map<String, String>> map = ALL) {
        def entry = map[name]
        if (!entry) throw new IllegalArgumentException("Unknown registry: '${name}'. Valid: ${map.keySet()}")
        return entry
    }

    static String host(String name)   { return get(name).host }
    static String org(String name)    { return get(name).org }
    static String credId(String name) { return get(name).credId }

    // Returns the fully qualified image ref: host/org/imageName:tag
    static String ref(String registry, String imageName, String tag,
                      Map<String, Map<String, String>> map = ALL) {
        def r = get(registry, map)
        return "${r.host}/${r.org}/${imageName}:${tag}"
    }
}
