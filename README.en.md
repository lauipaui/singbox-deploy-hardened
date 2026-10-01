# singbox-deploy-hardened

[中文](README.md) | **English**

An interactive sing-box deployment script for Linux VPS hosts. It detects the OS, installs dependencies, generates credentials/configuration, creates a service and installs the `sb` management command. **It runs as root and changes a host; it is not a read-only audit tool.**

## Supported targets and protocols

- Debian / Ubuntu with systemd.
- Alpine Linux with OpenRC.
- CentOS / RHEL / Fedora using the script's yum-based path and systemd.
- Protocol choices: Shadowsocks (2022 or AES-128-GCM), Hysteria2, TUIC, VLESS Reality and AnyTLS Reality; multiple choices are supported.

This is the code's intended platform range, not a claim that this documentation update tested every release. You need root, working package repositories and access to the upstream sing-box installer. Verify the chosen core supports the generated fields; distributions/package availability differ.

## Review and install a local snapshot

```sh
git clone https://github.com/lauipaui/singbox-deploy-hardened.git
cd singbox-deploy-hardened
less install-singbox-yyds.sh
sudo bash install-singbox-yyds.sh
```

The installer prompts for node name, protocols, ports and Reality connection address/SNI. Unspecified ports, passwords and UUIDs are randomly generated. It prints client URIs on completion; those URIs contain credentials and must remain private.

Back up an existing installation and keep a tested SSH session or provider console available before applying changes. Open only the intended TCP/UDP ports in both host and provider firewalls.

## Downloading bootstrap

```sh
# Run the reviewed entry file locally
sudo bash install.sh
# Or fetch the public bootstrap; review remote code before executing as root
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/lauipaui/singbox-deploy-hardened/main/install.sh)"
```

If already root, omit sudo. Bootstrap version 1.2.0 downloads the main installer from this repository's `main` into a private temporary directory, checks the **SHA-256 embedded in the bootstrap**, checks Bash syntax, then executes it. It does **not** run the adjacent local main script. To use a reviewed local revision, run `install-singbox-yyds.sh` directly.

```sh
bash install.sh --version
# Downloads/verifies the main script without installing it
bash install.sh --check
```

`--check` still makes a network request. A hash mismatch may indicate cache/version skew or unexpected content. Retrieve matching trusted versions; **do not remove hash verification to bypass the error**. The embedded hash guards matching content, not an untrusted bootstrap itself.

## Management and installed paths

```sh
sudo sb
```

The menu supports displaying URIs/configuration, editing config, start/stop/restart/status, updating the core, resetting protocol ports, generating relay configuration and uninstalling.

| Path | Purpose |
| --- | --- |
| `/etc/sing-box/config.json` | Active configuration and protocol credentials |
| `/etc/sing-box/.config_cache` | JSON metadata, not executable shell code |
| `/etc/sing-box/.protocols` | Protocol-selection state |
| `/etc/sing-box/.reality_pub`, `.reality_sid` | Reality metadata |
| `/etc/sing-box/certs/` | Certificates when Hysteria2/TUIC is enabled |
| `/etc/sing-box/reality-guard.cfg` | HAProxy allowlist configuration when enabled |
| `/usr/local/bin/sb` | Generated manager |

systemd hosts use the journal; the OpenRC setup writes `/var/log/sing-box.log` and `/var/log/sing-box.err`. Verify the actual installed units and core version before diagnosing a host.

## Hardening in the current code

- `umask 077` and restricted permissions for sensitive configuration/state, manager and relay scripts.
- `mktemp` for candidate configurations and generated relay scripts.
- Validated address/SNI/port input; JSON metadata and non-executing legacy-cache handling.
- HTTPS Alpine repositories, release-community preference with documented fallback paths, and OpenRC `supervise-daemon` supervision.
- Optional Reality SNI allowlist, enabled by default at the prompt: HAProxy forwards unauthenticated TLS camouflage traffic only for the selected SNI, rather than turning a shared CDN into an unrestricted TCP relay.
- Reality `max_time_difference: 1m`.
- Candidate checks and guarded configuration replacement for applicable manager operations.
- Uninstall package-manager selection uses available apt-get, dnf or yum commands.

The Reality guard is a separate `sing-box-reality-guard` service listening on loopback, not an extra public port. If you change Reality SNI, update `/etc/sing-box/reality-guard.cfg` consistently or camouflage handshakes may be denied.

## Security limitations

Core installation/update obtains an installer from `https://sing-box.app/install.sh`. Review downloaded upstream code and record/pin the tested core version for production changes. Repository hashing does not make all upstream dependencies permanently immutable.

Hysteria2/TUIC URIs currently include `insecure=1` because the server uses self-signed certificates. Where supported, deploy a trusted certificate and remove that option. Do not publish access tokens, UUIDs, passwords, Reality private keys or generated relay/client files.

## Checks and regression tests

| File | Purpose |
| --- | --- |
| [`install.sh`](install.sh) | Download, fixed-hash verification and bootstrap |
| [`install-singbox-yyds.sh`](install-singbox-yyds.sh) | Installer plus generated manager/relay scripts |
| [`test-regression.cjs`](test-regression.cjs) | Configuration/URI checks, injection rejection and real loopback protocol traffic |

```sh
bash -n install.sh
bash -n install-singbox-yyds.sh
```

The full regression test requires Node.js, Bash, jq, OpenSSL, curl and a compatible sing-box binary. Default paths refer to the original Windows workspace. Override `TEST_BASH`, `TEST_JQ_DIR` and `TEST_SINGBOX` elsewhere; for example on Linux:

```sh
TEST_BASH=/bin/bash TEST_JQ_DIR=/usr/bin TEST_SINGBOX=/usr/bin/sing-box \
  node test-regression.cjs
```

It uses a temporary directory and loopback listeners but launches real core processes; it is not just a static check. This README update did not reinstall/upgrade a core or rerun full protocol acceptance tests.

## Backup, rollback and uninstall

- Before reinstalling over existing files, the script saves existing `config.json`, `.config_cache`, `.protocols`, `.reality_pub` and `.reality_sid` under `/etc/sing-box/backup.*` with restricted permissions. This is **not** a full-system backup: separately protect certificates, units, binary version and HAProxy configuration where needed.
- Applicable configuration-replacement operations validate candidates and create `rollback.*.json`; a failed new startup attempts to restore the old config. This local guard does not cover arbitrary edits, external updates or complete uninstall.
- For a manual rollback, retain SSH/out-of-band access, restore the protected known-good files and compatible core, run `sing-box check -c /etc/sing-box/config.json`, restart the original service, then check logs and a real client.
- Use the `sb` uninstall menu only after saving what you need. It removes `/etc/sing-box`, service/guard files, logs, manager and `/usr/bin/sing-box`; backups stored under that directory may be deleted too.

## Sources and licensing

This repository preserves reviewed/hardened deployment scripts and source attribution in the code. No standalone `LICENSE` is provided here; do not infer unrestricted relicensing permission. Verify sing-box, package, protocol and third-party component terms before use or redistribution.
