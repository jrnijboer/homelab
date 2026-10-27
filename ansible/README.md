# PostgreSQL on ig11

For the separate backup repository on monmothma, see the
[Barman role documentation](roles/barman/README.md). Backups are set up in order:

1. `postgresql-1-install.yaml` installs and runs PostgreSQL on ig11.
2. `postgresql-2-prepare-barman.yaml` adds the Barman accounts, access rules and
   replication settings on ig11. It needs the container running and the vault
   variables `barman_postgresql_password` and `barman_streaming_password`.
3. `postgresql-3-install-barman.yaml` sets up monmothma. Automation is switched on by
   `barman_enabled: true` for `monmothma` in `hosts.yml`.

Run from this directory:

```sh
../.venv/bin/ansible-playbook postgresql-1-install.yaml
```

Add `--ask-become-pass` if the SSH user requires a password for sudo.
The existing Ansible configuration supplies the inventory and vault password file.
The `ansible` dependency includes the `community.general` and `community.docker`
collections used by this playbook.

The playbook targets the `postgresql_servers` group, currently containing `ig11`.
It runs `general`, then `docker`, then creates the PostgreSQL container.
The Docker role supports Ubuntu and Debian, configures Docker's official APT
repository, and installs Docker CE only when needed. It replaces the standard
legacy `docker.list` repository definition with `docker.sources`. It does not
remove Docker packages, containers, or volumes, or request package upgrades.
It also merges a log rotation setting (`json-file`, 10 MB, 5 files; see
`roles/docker/defaults/main.yml`) into `/etc/docker/daemon.json`, keeping any other
keys, and checks the file with `dockerd --validate` before installing it. Docker is
not restarted unless `docker_restart_on_config_change` is true, because a restart
stops all containers. Until Docker restarts, the setting is not active. Containers
keep the log settings they were created with, so the PostgreSQL container has to be
recreated (`sudo docker rm -f postgresql`, then rerun `postgresql-1-install.yaml`;
the data stays on the ZFS dataset) before it rotates its logs.

## Database

- Image: `ghcr.io/immich-app/postgres:18-vectorchord0.5.3`.
- Container: `postgresql`.
- Administrator: `postgres`; initial database: `postgres`.
- Password: `postgresql_admin_password` from `group_vars/all/vault.yaml`.
- Storage: host ZFS dataset `/tank/postgres`, bind-mounted at `/var/lib/postgresql`
  for the PostgreSQL 18 data layout.
- Static port forwarding: host `0.0.0.0:5432` to container `5432/tcp`.
- Recovery: `unless-stopped` restarts the container after crashes and host reboots,
  unless it was explicitly stopped. Docker itself is enabled at boot.
- Memory: ig11 is a Beelink ME mini with 12 GB (about 10.9 GiB usable). The container
  is limited to `postgresql_container_memory` (6G) and the ZFS ARC to
  `postgresql_zfs_arc_max` (3 GiB), set in `/etc/modprobe.d/zfs-arc.conf` and applied
  immediately. Together with the system that fits the machine.

The dataset must already exist and be mounted; the playbook checks this before
starting PostgreSQL. It also installs a Docker systemd drop-in that requires
`zfs-mount.service`, orders Docker after ZFS mounting, and requires the mounts
needed for `/tank/postgres`. A pre-start check refuses to start Docker unless
that path is mounted as ZFS.

This dependency applies to all Docker containers on the host: if the dataset
cannot mount, Docker will not start. The playbook reloads systemd when the drop-in
changes but does not restart Docker. The guard takes effect on Docker's next
start, including after a reboot.

Switching from the previous named volume does not migrate existing database data;
migrate that data before deploying this change if the database is already in use.
The old named volume is not deleted.

The password is used to initialize an empty data directory. Changing the vault value
does not rotate the password of an existing database; rotate that password in
PostgreSQL as well. This playbook does not install a separate pgAdmin service.
Keep database backups independently of the ZFS dataset.

## Network Access

### Vault-issued PostgreSQL TLS

The PostgreSQL playbook now installs `hashicorp_repo` after Docker and includes
`vault_agent` after pulling the image and preparing its certificate reload helper.
Existing Consul and Nomad callers do not opt into the new paired template mode.

Before deploying, apply the dedicated PostgreSQL PKI/AppRole Terraform resources
and securely populate these variables in Ansible Vault from that AppRole's stored
credentials:

- `postgresql_vault_agent_role_id`
- `postgresql_vault_agent_secret_id`

These are intentionally separate from the existing shared Agent credentials.
The playbook does not fetch them from Vault automatically. The PKI role must allow
`ig11` and `ig11.home`; requests explicitly use `ttl=720h` (30 days).

Vault Agent writes matching certificate/key files to `/etc/postgresql.d/tls`.
The container mounts that directory read-only at `/etc/postgresql/tls` and enables
TLS while preserving the Immich image's PostgreSQL configuration file. The reload
helper checks certificate expiry and key matching, gives the key's root-owned
0640 permissions to the PostgreSQL image's discovered group, and sends SIGHUP to
the running container. Initial issuance tolerates a container that does not yet
exist. PostgreSQL's private Agent cache is mode 0600 at
`/etc/vault-agent.d/postgresql-server-rendered.pem`, outside the container's TLS
mount. The previous cache in the TLS directory is removed during deployment.

Ansible manages `/etc/postgresql.d/config/postgresql.conf` and `pg_hba.conf`,
mounted read-only at `/etc/postgresql/custom`. The managed main configuration
includes the image's `/etc/postgresql/postgresql.conf` before applying our TLS
and authentication overrides, preserving the image's extension settings.
Do not mount over the image's `/etc/postgresql` directory.

The managed HBA file rejects plaintext TCP connections over IPv4 and IPv6 and
requires SCRAM authentication for TLS database connections. Network access remains
allowed from any address; this is TLS enforcement, not a client-network allowlist.
Existing roles need SCRAM password verifiers to connect. Unix-socket connections
inside the container retain trusted access for initialization and administration.
Remote physical replication is denied until `postgresql-2-prepare-barman.yaml` adds
the Barman rules. Configuration file changes trigger a reload; future startup-only
settings require a container restart. Existing plaintext sessions are not
terminated by a reload.

Applying this change can recreate the PostgreSQL container to add its mount and
TLS settings, causing a database interruption. Data remains on the ZFS dataset.
TLS is required for new TCP database connections. The managed files include the
directories `conf.d` and `hba.d`, where `postgresql-2-prepare-barman.yaml` puts its
own settings and rules, so the two playbooks never edit the same file. The Barman
playbook creates the `barman` (monitoring) and `streaming_barman` (replication)
accounts from the vault variables `barman_postgresql_password` and
`barman_streaming_password`. Both are limited by `pg_hba.conf` to TLS connections
from the subnet `192.168.179.0/24` (`postgresql_barman_client_address`), so any host
there can attempt a login with the correct password. Slot WAL retention is capped by
`postgresql_max_slot_wal_keep_size` (50GB). The passwords are re-applied on every
run, and rotating them in Vault takes effect on the next run. Changing `wal_level`,
`max_wal_senders` or `max_replication_slots` needs a container restart; a reload
does not apply them.
Certificate renewal has not been observed yet; the current certificate expires on
24 November 2026, so check that Vault Agent has replaced it before then.

Port 5432 is published on all host interfaces and allowed through UFW.
Docker-published ports can bypass UFW filtering, so do not rely on UFW alone to
restrict database clients. Use an upstream firewall or Docker-aware firewall
rules for access restrictions. To bind only a specific host interface, override
`postgresql_listen_address`, for example:

```sh
../.venv/bin/ansible-playbook postgresql-1-install.yaml \
  -e postgresql_listen_address=192.168.1.11
```

Replace that example address with the actual private address of `ig11`.

## Restoring PostgreSQL from Barman

A point-in-time restore was tested on 27 October 2026 into a throwaway container.
The data, the `vchord` and `vector` extensions and the stop point were all correct.
The commands run on `monmothma` unless stated. Always restore into a scratch
directory first and never over the live data.

1. Pick a target time in UTC, or leave out `--target-time` for the latest state.
   `sudo -u barman /usr/local/bin/barman-guard list-backups ig11` lists the backups.
   Switch the WAL first if the data you need was written recently:
   `sudo -u barman /usr/local/bin/barman-guard switch-wal --archive ig11`. The
   `--force` option needs rights the `barman` account does not have.

2. Restore into an empty directory. Barman 3.18 fails on Python 3.14 with
   `cannot pickle '_thread.lock' object` (upstream issue 1181, fixed after 3.18).
   Until a fixed release reaches Ubuntu, force the old process start method:

   ```sh
   sudo mkdir -p /mnt/backup/restore-test/data && sudo chown -R barman: /mnt/backup/restore-test
   time sudo -u barman python3 -c "
   import multiprocessing, sys
   multiprocessing.set_start_method('fork', force=True)
   sys.argv[0] = 'barman'
   from barman.cli import main
   main()" restore --target-time "<UTC time>" --target-action promote ig11 auto /mnt/backup/restore-test/data
   ```

   Scheduled backups are not affected, because they use `pg_basebackup`. The warning
   about configuration files outside the data directory is expected: those files come
   from this repository and from the image.

3. Give the data to the image's `postgres` user and start the image that matches the
   backup. The directory is mounted twice, because Barman writes the host path into
   `restore_command` and `recovery_end_command`:

   ```sh
   IMG=ghcr.io/immich-app/postgres:18-vectorchord0.5.3
   PGU=$(sudo docker run --rm --network=none --entrypoint id $IMG -u postgres)
   PGG=$(sudo docker run --rm --network=none --entrypoint id $IMG -g postgres)
   sudo chown -R $PGU:$PGG /mnt/backup/restore-test/data && sudo chmod 700 /mnt/backup/restore-test/data
   sudo docker run -d --name restore-test -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=unused \
     -p 127.0.0.1:55432:5432 \
     -v /mnt/backup/restore-test/data:/var/lib/postgresql/18/docker \
     -v /mnt/backup/restore-test/data:/mnt/backup/restore-test/data:ro $IMG
   sudo docker logs -f restore-test
   ```

   The log should show WAL being replayed, recovery stopping before the first commit
   after the target time, a new timeline, and `ready to accept connections`. The
   read-only mount makes the final cleanup of `barman_wal` fail with a harmless
   warning.

4. Check the result with `psql` inside the container, then remove it:
   `sudo docker rm -f restore-test && sudo rm -rf /mnt/backup/restore-test`.

Restoring the live database has not been rehearsed. The plan would be to stop the
container, move the old `/tank/postgres/18/docker` aside, restore on `monmothma` and
copy the directory to `ig11` with the same ownership, because `barman restore` cannot
write to `ig11` directly (no SSH access is set up for it). Change the
`restore_command` and `recovery_end_command` in `postgresql.auto.conf` to the
container path `/var/lib/postgresql/18/docker/barman_wal`, then run
`postgresql-1-install.yaml` to start the container with the managed configuration.
The restored server is on a new timeline and has no replication slot, so check that
the slot `barman_ig11` exists again and take a new full backup soon afterwards.
The backups and WAL stay on the unencrypted USB disk; keep another copy elsewhere.