# Barman Repository on monmothma

This role prepares streaming backups of the entire PostgreSQL instance on ig11.
It does not configure ig11, change fstab, or install a PostgreSQL server locally.
No SMB, NFS, SSH keys, or inbound backup ports are required for streaming mode.

## Repository and Packages

The existing ext4 filesystem at `/mnt/backup` must have UUID
`5451fbc1-1ce0-4f4d-8a21-aa51a129a15e`. The role verifies this before installation
and creates `/mnt/backup/barman` owned by the dedicated `barman` account. It does
not change ownership of the entire USB disk. Configuration, logs, and lock files
remain on the host filesystem; backups, WAL, and restore staging use the USB disk.

Packages come from the host's own distribution repositories; no extra repository is
added. The role installs the `barman_packages` list (Barman, the PostgreSQL 18 client
tools, `gzip` and `ca-certificates`) with apt, which only installs what is missing.
It requires Barman 3.16 or newer.
Live connectivity is checked only during deployment.

## Staged Installation

Run from the Ansible directory when ready to change monmothma:

```sh
../.venv/bin/ansible-playbook postgresql-3-install-barman.yaml
```

By default, `barman_enabled: false` leaves the server inactive and all timers
disabled. It installs the configuration without attempting to create a replication
slot or connect to ig11. The packaged Barman cron file is diverted to
`/etc/cron.d/barman.distrib` (ignored by cron), including across package upgrades.
Do not run a second Barman maintenance scheduler alongside this role's service.

## Prerequisites on ig11 Before Activation

These are not applied by this playbook:

- Create dedicated `barman` monitoring and `streaming_barman` replication logins.
  Grant the monitoring account the permissions required by the installed Barman
  version, including monitoring and WAL-switch permissions. Do not reuse `postgres`.
- Allow those accounts from monmothma in `pg_hba.conf`, including a physical
  `replication` entry for `streaming_barman`, using SCRAM authentication.
- Set `wal_level=replica`, adequate `max_wal_senders` and `max_replication_slots`,
  and a finite `max_slot_wal_keep_size` sized for the available ZFS space.
  Streaming backups need replication connections in addition to the WAL receiver.
- Configure PostgreSQL TLS with a certificate valid for `ig11`. The default
  `sslmode=verify-full` uses monmothma's system CA bundle; import the issuing CA
  there or override `barman_sslrootcert` with a trusted CA file.
- Permit monmothma to reach ig11 on TCP 5432. No `archive_command` is required for
  this streaming-only design.

Add `barman_postgresql_password` and `barman_streaming_password` to Ansible Vault.
Credentials are written to `/var/lib/barman/.pgpass` with mode 0600, not included
in connection strings or task output. Do not use newline-containing passwords.

Once the prerequisites are in place, set `barman_enabled: true` in inventory or
run with `-e barman_enabled=true`. This enables the timers and permits Barman to
create its physical replication slot `barman_ig11` on ig11. Disabling automation
later does not drop that slot: monitor or explicitly retire it on ig11 to avoid
unbounded WAL retention or an invalidated slot.

## Automation and Checks

- Maintenance runs every minute in a supervised service. Barman cron manages WAL
  streaming, WAL archival, and retention. Its child receiver processes remain in
  the same systemd control group and stop with the service.
- Full cluster backups run daily at 02:00, host local time. No incremental backups
  or WAL summarization are assumed. Override `barman_backup_calendar` if needed.
- Retention is a 7-day recovery window with at least two backups. Allow capacity
  for daily full backups plus all WAL needed by that window; this is not a disk
  quota and can require more than 7 days of files.
- Every 15 minutes, checks fail for backups older than two days, archived WAL older
  than 26 hours, filesystem use at or above 90%, and Barman's other health checks.
  An idle database writes no WAL, so a shorter limit gave false alarms; the daily
  backup always writes some, which keeps the 26-hour limit safe. A stopped WAL
  receiver is caught by the `receive-wal running` check instead.
- Each operation checks the mount UUID and filesystem type. Services bind to
  `mnt-backup.mount` and stop if it is unmounted. The maintenance timer retries
  startup when the mount becomes available. The wrapper also checks the disk each
  minute, so an unexpected filesystem cannot silently replace the backup disk.

Use the guarded entry point for manual commands on monmothma:

```sh
sudo -u barman /usr/local/bin/barman-guard check ig11
sudo -u barman /usr/local/bin/barman-guard backup --wait --wait-timeout 3600 ig11
sudo -u barman /usr/local/bin/barman-guard list-backups ig11
systemctl list-timers 'barman-*'
journalctl -u barman-maintenance -u barman-backup -u barman-check
```

After activation, take an initial backup and verify its status becomes DONE.
Initial checks can report missing backups/WAL until the first backup completes.
Checks are recorded in systemd/journald and `/var/log/barman/barman.log`; no email
or external notification destination is configured yet. Connect these checks to
your monitoring before relying on unattended operation, including monitoring ig11
for disk space and slot retention. The package supplies logrotate for Barman logs.

Recovery is not tested by successful backup jobs. Schedule restore drills into an
isolated PostgreSQL 18 instance with the same extension binaries. Protect the
Ansible configuration and exact image reference separately. The USB repository
is not encrypted by this role and should have an additional off-site copy.