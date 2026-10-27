# Plan: Complete PostgreSQL Backups

## Current state (read this first when resuming)

Setup
* PostgreSQL 18 (image ghcr.io/immich-app/postgres:18-vectorchord0.5.3) runs in Docker on ig11 (192.168.179.98, Beelink ME mini: 12 GB RAM, about 10.9 GiB usable, root filesystem on eMMC, data on ZFS dataset /tank/postgres). From monmothma it is reachable only as ig11.home; ig11 works only through the SSH config of the workstation.
* Barman 3.18 runs on monmothma (192.168.179.96, also Vault, Consul and Nomad server). Backups go to the ext4 USB disk at /mnt/backup (UUID in roles/barman/defaults/main.yml), repository /mnt/backup/barman.
* Everything is Ansible, run from the ansible/ directory with `../.venv/bin/ansible-playbook`. Order: postgresql-1-install.yaml (PostgreSQL, TLS from Vault Agent, config), postgresql-2-prepare-barman.yaml (Barman accounts, access rules, replication settings), postgresql-3-install-barman.yaml (Barman on monmothma). nomad-client.yaml (general, hashicorp_repo, docker for monmothma) has been run.
* Secret variable names in group_vars/all/vault.yaml (never print the file): postgresql_admin_password, postgresql_vault_agent_role_id, postgresql_vault_agent_secret_id, barman_postgresql_password, barman_streaming_password. `barman_enabled: true` for monmothma is in hosts.yml.
* The Vault side (PKI role postgresql_server_cert_request, AppRole and policy `postgresql`, intermediate mount max TTL 90 days, restored PKI rules in nomad-workloads-policy) is Terraform in the separate repository /home/jan/git/vaultpkihomelab and has been applied.
* More detail: ansible/README.md (operating notes and the tested restore procedure) and ansible/roles/barman/README.md.

Decisions
* TLS is required for all TCP connections. The two Barman accounts may connect only from 192.168.179.0/24. Other accounts may connect from anywhere over TLS with SCRAM.
* Daily full backup at 02:00 UTC, 7-day recovery window, at least 2 backups, no incremental backups, replication slot capped at 50GB, WAL age check 26 hours.
* Container limited to 6G and ZFS ARC capped at 3 GiB; Docker logs rotated at 10 MB x 5 files.

Changed in the repository but not confirmed as deployed (rerun the playbooks, then check)
* Container memory limit 6G: `sudo docker inspect postgresql --format '{{.HostConfig.Memory}}'` should print 6442450944.
* ZFS ARC cap: `cat /sys/module/zfs/parameters/zfs_arc_max` on ig11 should print 3221225472, also after a reboot.
* WAL age 26 hours: `sudo grep last_wal_maximum_age /etc/barman.d/ig11.conf` on monmothma.
* Docker log rotation: /etc/docker/daemon.json on ig11 and `sudo docker inspect postgresql --format '{{json .HostConfig.LogConfig}}'`; the container must be recreated to pick it up.

Known issues
* Barman 3.18 restores fail on Python 3.14 (upstream issue 1181). Workaround is in ansible/README.md.
* The docker commands on ig11 need sudo (user jan is not in the docker group).

Uncommitted work
* This project's changes in the homelab repository (PLAN.md, ansible/README.md, the three postgresql-*.yaml playbooks, nomad-client.yaml, roles/barman, roles/docker, templates/, tests/, group_vars/postgresql_servers/, changes to hosts.yml, hashicorp_repo and vault_agent) are being committed and pushed. Check `git status` if anything looks missing.

## Remaining work

1. Prepare PostgreSQL (completed)
* Create dedicated Barman monitoring and replication accounts, with passwords stored in Ansible Vault.
* Add TLS-only access rules restricted to the 192.168.179.0/24 subnet, before broader application rules.
* Configure replication slots, WAL senders, and a finite WAL retention limit sized for available storage and outage tolerance.
* Verify permissions, authentication rules, and effective settings.

2. Prepare the Backup Host (completed)
* Verify compatible Barman and PostgreSQL 18 client packages.
* Configure CA trust and hostname resolution for certificate verification.
* Deploy Barman inactive on monmothma, with separate approval.
* Verify USB disk identity, repository permissions, mount protection, and disabled schedules.

3. Activate Backups (completed; first scheduled run on 28 Oct still to be seen)
* Enable WAL streaming and verify the replication slot.
* Take the initial full backup and confirm it reaches DONE.
* Verify daily backups at 02:00, seven-day recovery retention, and subsequent automated runs.

4. Prove Recovery (completed)
* Restore into an isolated PostgreSQL 18 instance with matching extensions.
* Test point-in-time recovery using known test data.
* Document the recovery procedure and measured recovery time. The procedure is in ansible/README.md. The test database is tiny: PostgreSQL finished recovery and accepted connections about 5 seconds after the container started. The duration of `barman restore` itself was not recorded.
* Findings: Barman 3.18 restores fail on Python 3.14 until a fixed release reaches Ubuntu (workaround in the README), and a restored directory must be reachable inside the container at the path Barman wrote.

5. Add Operational Protection (open; continue once Prometheus is running)

5a. Notifications
* Alert on: backup older than 2 days or failing, WAL receiver stopped or slot invalid, /mnt/backup missing or above 90%, ig11 ZFS dataset filling up, PostgreSQL certificate not renewed (current one expires 24 Nov 2026), and monmothma itself going silent.
* A dead backup host cannot report its own failure, so use a check or heartbeat that runs outside monmothma.
* Simple first step without Prometheus: `barman-check.service` already exits non-zero when a check fails, so an `OnFailure=` notifier (email, ntfy or webhook) would work.
* With Prometheus: node exporter textfile collector on monmothma for latest backup age, check results and failed units; `postgres_exporter` on ig11 for slot state and retained WAL; Alertmanager rules. Run Prometheus and Alertmanager somewhere that survives monmothma failing.
* Open questions: where Prometheus runs, and where notifications go.
* Test that alerts are actually delivered.

5b. Runbook for an extended backup-host outage (add to ansible/README.md)
* Check the slot on ig11 (`wal_status` in `pg_replication_slots`) and disk growth; `max_slot_wal_keep_size` (50GB) decides when retained WAL is discarded.
* Short outage: restore the mount, restart `barman-maintenance`, confirm streaming catches up.
* Long outage with a lost slot: recreate the slot, take a new full backup; restores cannot cross the WAL gap.
* Barman retired for good: drop the slot on ig11 so it does not keep WAL forever.

5c. Second copy of the backups
* The repository is unencrypted and on one USB disk. Options: a rotated offline disk, or an encrypted copy (restic or borg) to another host or cloud storage; `zfs send` of the dataset to another machine is an independent alternative.
* Copy only after a backup has completed, so the copy is consistent.
* Test a restore from the copy at least once.

5d. Smaller items
* Check on or before 24 Nov 2026 that Vault Agent has replaced the PostgreSQL certificate.
* Record the duration of `barman restore` from the next restore test.
* Revisit incremental backups when the database passes roughly 50 GB (needs `summarize_wal = on` before the full backup that serves as parent).

6. Maintenance Procedures (open)
* Write down how to update the PostgreSQL image on ig11. Minor update: take a Barman backup, pull the new tag of ghcr.io/immich-app/postgres, rerun postgresql-1-install.yaml, check the logs, run `ALTER EXTENSION ... UPDATE` for vchord and vector if the image ships newer versions, then take another backup. Major upgrade (for example PostgreSQL 19): plan it separately, because it starts a new data directory and a new Barman backup chain.
* Add a wrapper for the Python 3.14 restore workaround to the barman role, and watch for an Ubuntu barman package that contains the upstream fix (issue 1181), then remove the wrapper.
* Schedule a restore drill, for example every quarter: a point-in-time restore into a throwaway container as in ansible/README.md. Record how long `barman restore` takes each time.
* Optionally run `barman verify-backup` after each backup to check the base backup against its manifest.

7. Log Collection (open)
* Docker keeps only about 50 MB of logs per container (`json-file`, 10 MB x 5 files, from roles/docker/defaults/main.yml), so older output is lost. Install a log collector to keep a longer history.
* Decide where logs go and how long they are kept, and keep them off the eMMC root filesystem of ig11 to limit wear and avoid filling it.
* Cover at least the PostgreSQL container on ig11, the Barman units on monmothma (`barman-maintenance`, `barman-backup`, `barman-check`, journald), and Vault Agent. Check that failed backups and checks are visible there.
* Check the PostgreSQL log settings once logs are collected: `log_min_duration_statement` is -1 and `log_statement` is none today, and `log_connections` is empty (off). Decide whether slow-query logging, for example at 1 second, is wanted.
* Consider combining it with the Prometheus work in 5a, so alerts can point to the matching log lines.

