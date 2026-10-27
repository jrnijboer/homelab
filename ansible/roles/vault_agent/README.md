# Vault Agent Certificate Delivery

Existing callers retain the separate certificate/key templates, 24-hour requests,
destination paths, and reload commands. New paired issuance is opt-in through
`paired: true` on a certificate entry; do not switch existing callers implicitly.

Paired entries use Vault Agent's `pkiCert` template function to obtain a matching
certificate and key in one issuance. They accept `ttl` (default `24h`) and optional
`ip_sans` and `alt_names`. They write the key with root ownership and mode 0640,
and certificate plus issuing CA with mode 0644, before executing the configured
command. The command must prepare application-specific ownership and reload the
service. A root-only rendered cache contains the certificate and private key for
`pkiCert` reuse across Agent restarts. Use a Vault version supporting `pkiCert`
and `writeToFile`; this integration has not yet been runtime-tested.

The role still manages one shared Agent service, base configuration, and AppRole
credential pair per host. Marker blocks permit multiple certificate entries, not
independent AppRole identities. Avoid configuring different identities on the
same host through multiple playbooks.