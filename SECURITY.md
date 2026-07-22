# Security

multi-cli profiles isolate account authentication while sharing only adapter-declared normal state. Treat every credential path, OS keychain entry, OAuth database, session database, extension global-storage database, log, screenshot, and evidence file as sensitive until classified.

## Guarantees

- Adapter paths are validated before profile creation or launch.
- Schema-v2 file overlays keep credentials under the profile and link declared normal state to the native tool home.
- Required links fail closed; production code never copies as a fallback.
- Unsupported or inseparable account boundaries fail closed rather than claiming isolation.
- Session continuation excludes adapter-declared credentials and rejects unsafe paths, links, and hardlinks.

## Non-guarantees

A `supported` level applies only to the mode named in the row's reason; other auth modes of the same product may share state. Offline binary detection does not prove separate identities or quotas. OS-user adapters isolate through a multi-cli-owned OS user and require an elevated terminal for provisioning on Windows.

## Secret handling

Never pass credentials as command-line arguments. Do not commit local E2E manifests, profiles, evidence containing raw output, credential databases, token claims, emails, screenshots, or account identifiers. Revoke disposable test credentials after authenticated runs.

Report security issues privately to the repository owner rather than opening a public issue containing reproduction secrets.
