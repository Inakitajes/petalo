# Security Policy

## Supported versions

Petalo is pre-1.0. Security fixes are applied to the latest release and the default branch.

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** flow under the repository Security tab. Do not open a public issue for suspected vulnerabilities or include secrets, private paths, or proof-of-concept payloads in public discussions.

Include the affected version, macOS version, impact, reproduction steps, and suggested mitigation. You should receive an acknowledgement within seven days.

## Security model

- Petalo runs as the current macOS user and has no privileged helper.
- It has no network client, server, analytics, account system, or cloud storage.
- The display-selection fallback reads only local geometry and does not request Accessibility or Screen Recording permissions.
- The app lock is user-owned and uses no-follow file creation plus an advisory kernel lock.

Only source builds are provided until a Developer ID-signed and notarized release pipeline is available. Never install an unsigned binary from an untrusted third party.
