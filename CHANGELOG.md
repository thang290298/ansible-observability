# CHANGELOG.md

## [6.1.0] — 2026-03-30

### Fixed — s3_enabled Feature Flag + vmsingle Cold Tier

#### s3_enabled là feature flag duy nhất kiểm soát toàn bộ S3
- `inventory/group_vars/all/main.yml`: Đổi `s3_enabled: true` → `s3_enabled: false` (default OFF)
- Mọi role đều tôn trọng flag này — không hardcode S3 path

#### roles/vmbackup — Fix s3_enabled conditional
- `templates/docker-compose.yml.j2`:
  - `{% if s3_enabled %}` → dùng S3 dst
  - `{% else %}` → dùng `fs:///backup/latest/`
- `templates/vmbackup-run.sh.j2`:
  - Render `S3_ENABLED="{{ s3_enabled | default(false) | lower }}"` tại deploy time
  - Không còn runtime curl check — flag được quyết định bởi Ansible
  - `s3_enabled=false` → backup local với retention 7 ngày
  - `s3_enabled=true` → backup lên S3 bucket

#### roles/loki — Đã đúng (verify)
- `templates/loki-config.yml.j2`: Đã có `{% if s3_enabled %}` đúng chuẩn

#### roles/vmsingle — NEW: Cold tier cho historical data
- `tasks/main.yml`: Skip toàn bộ khi `s3_enabled=false`
- `templates/docker-compose.yml.j2`: Deploy VictoriaMetrics single-node
- `templates/vmrestore.sh.j2`: Script restore từ S3 → vmsingle
- `defaults/main.yml`: `vmsingle_port=8428`, `vmsingle_data_path=/data/vmsingle`

#### playbooks/site.yml
- Thêm play [17] vmsingle cold tier sau vmbackup

#### inventory/group_vars/all/main.yml
- Thêm `vmsingle_port: 8428` và `vmsingle_data_path: "/data/vmsingle"`

### Behavior Matrix

| Variable | Loki | vmbackup | vmsingle |
|---|---|---|---|
| `s3_enabled: false` | filesystem | local /backup | SKIP |
| `s3_enabled: true` | S3 bucket | S3 bucket | Deploy + vmrestore.sh |

## [6.0.0] — 2026-03-29

### Added — Stack-based Deployment Architecture

#### Playbooks tách theo stack (`playbooks/stacks/`)
- `infra.yml` — Deploy infra: common → docker → keepalived → haproxy
- `monitoring.yml` — Deploy monitoring: vmstorage → vminsert → vmselect → vmagent → alertmanager
- `grafana.yml` — Deploy visualization: postgresql → grafana
- `logging.yml` — Deploy logging: minio → loki → promtail
- `gitops.yml` — Deploy GitOps: gitea

#### Exporter playbooks riêng (`playbooks/exporters/`)
- `node-exporter.yml` — node_exporter only
- `blackbox.yml` — blackbox/random_ping
- `ceph-exporter.yml` — Ceph exporter (placeholder)
- `openstack-exporter.yml` — OpenStack exporter (placeholder)
- `all.yml` — Import tất cả exporters

#### Reconfig tách theo stack (`playbooks/reconfig/`)
- `monitoring.yml` — Reload vmagent config + alert rules
- `grafana.yml` — Reload Grafana datasources
- `logging.yml` — Reload Loki + Promtail config
- `alertmanager.yml` — Reload Alertmanager config (POST /-/reload)
- `haproxy.yml` — Reload HAProxy backends (graceful)
- `exporters.yml` — Reload scrape targets (SIGHUP)
- `all.yml` — Reconfig toàn bộ

#### run.sh v6.0
- Thêm stack commands: `infra`, `monitoring`, `grafana`, `logging`, `gitops`
- Thêm exporter commands: `exporters`, `node-exporter`, `blackbox`, `ceph-exporter`, `openstack-exporter`
- Thêm reconfig commands: `reconfig`, `reconfig-monitoring`, `reconfig-grafana`, `reconfig-logging`, `reconfig-alertmanager`, `reconfig-haproxy`, `reconfig-exporters`
- `site` command (alias: `deploy`) cho full deploy

#### Makefile v6.0
- Targets: `deploy-infra`, `deploy-monitoring`, `deploy-grafana`, `deploy-logging`, `deploy-gitops`
- Targets: `deploy-exporters`, `deploy-node-exporter`, `deploy-blackbox`, `deploy-ceph-exporter`, `deploy-openstack-exporter`
- Targets: `reconfig-monitoring`, `reconfig-grafana`, `reconfig-logging`, `reconfig-alertmanager`, `reconfig-haproxy`, `reconfig-exporters`

### Added — gen_config_vmagent role (v6.0)
- `roles/gen_config_vmagent/` — Generate vmagent scrape configs từ inventory
  - Pattern `meta.ip` + `meta.host` + `meta.site` + `meta.role` trong host_vars
  - Templates: `scrape_node.yml.j2`, `scrape_ceph.yml.j2`, `scrape_openstack.yml.j2`, `scrape_libvirt.yml.j2`, `scrape_blackbox.yml.j2`
  - Output: `/opt/monitoring/vmagent/scrape_configs/scrape_<type>_<site>.yml`
  - Tại sao tránh conflict: mỗi site → file riêng, `meta.ip` không nhầm IP
  - Auto reload vmagent (SIGHUP) sau khi gen
- `inventory/host_vars/*.yml` — Example files với meta pattern
- `inventory/group_vars/site_*.yml` — Site-specific vars (dbp3, dbp4, ntl4)
- `playbooks/exporters/gen-config.yml` — Playbook chạy gen_config_vmagent
- `./run.sh gen-config` — New command
- `make gen-config` — New Makefile target

### Fixed — Bug fixes
- `ansible.cfg` — Fix header: `defaults]` → `[defaults]`
- `run.sh` — Fix shebang: `!/usr/bin/env bash` → `#!/usr/bin/env bash`
- `roles/common/templates/chrony.conf.j2` — Template bị thiếu, đã tạo mới
- `roles/loki/handlers/main.yml` — Handlers bị thiếu, đã tạo mới
- `roles/promtail/tasks/main.yml` — URL thiếu prefix `v` cho loki_version
- `roles/minio/templates/docker-compose.yml.j2` — Fix distributed mode yêu cầu >= 4 nodes

### Added — README
- Section "Stack Commands" với đầy đủ hướng dẫn v6.0

---

## [3.0.0] — 2026-03-29

### Added — Random Ping Monitoring
- `roles/random_ping/` — Role mới hoàn chỉnh
  - Blackbox Exporter (Docker) với ICMP module
  - Python script tự động rotate cặp ping ngẫu nhiên mỗi 2 phút
  - Systemd service tự khởi động lại khi crash
  - Auto-generate danh sách nodes từ inventory
- `files/alert-rules/random-ping.yml` — Alert rules:
  - `PingPacketLoss` — rớt gói hoàn toàn → cảnh báo Telegram ngay
  - `PingHighLatency` — latency > 50ms trong 3 phút
  - `BlackboxExporterDown` — monitor down
- `playbooks/random-ping.yml` — Deploy riêng lẻ hoặc qua site.yml
- vmagent scrape config tự động lấy targets từ `/etc/blackbox/random-ping-targets.yml`
- `make random-ping` — deploy nhanh từ Makefile

### Updated — Versions
- node_exporter: `1.7.0` → `1.8.2`
- alertmanager: `v0.27.0` → `v0.28.0`
- minio: `RELEASE.2024-01-16` → `RELEASE.2024-11-07`
- blackbox_exporter: `v0.25.0` (mới)

### Improved
- `all.yml`: Thêm `random_ping_*` config vars
- `vmagent-scrape.yml.j2`: Thêm random-ping + blackbox jobs
- `Makefile`: Thêm `random-ping` và `random-ping-check` targets
- README: Cập nhật hướng dẫn random ping

# CHANGELOG.md

## [2.2.0] — 2026-03-28

### Fixed — Critical
- Loki: `chunk_store_config` sai level (con của `storage_config` → top-level)
- Loki: S3 credentials tách khỏi URL — không còn lộ password trong log
- `grafana_db_host`: Jinja2 expression đơn giản, không crash khi `pg_role` thiếu
- `promote-replica.yml`: Bỏ `vars_prompt`, dùng `--extra-vars target_node=<node>` — hoạt động đúng với non-TTY

### Fixed — High
- MinIO `docker-compose.yml.j2`: Sửa `command` format từ multi-line string → YAML list
- `site.yml`: vminsert chờ vmstorage cluster healthy trước khi start
- `upgrade.yml`: Thêm node_exporter vào rolling upgrade
- HAProxy: Thêm `tune.bufsize 32768` và `tune.maxrewrite 8192` cho vminsert batch; tăng timeout lên 60s
- vmstorage: Thêm `--dedup.minScrapeInterval` — dedup data từ 2 vmagent active-active

### Fixed — Medium
- `roles/vmagent/templates/vmagent-scrape.yml.j2`: Tạo file bị thiếu — vmagent role không còn crash
- `roles/vmagent/tasks/main.yml`: Tạo file bị thiếu
- `roles/vmagent/templates/docker-compose.yml.j2`: Tạo file bị thiếu
- `ansible.cfg`: Thêm config đầy đủ — không cần nhớ flags khi chạy tay
- Grafana datasources: Thêm `uid` cố định — dashboard không bị broken sau redeploy
- `monitoring_db/group_vars`: Default `pg_role: replica`, thêm `pg_primary`/`pg_replicas` helper vars
- `node_exporter` role: Tạo `textfile_collector` directory + full systemd service

### Fixed — Low
- Alert `NodeDiskWillFillIn24h`: Tăng window `6h → 24h`, thêm `for: 1h` — giảm false positive
- `manage-targets.sh`: Gọi `scripts/targets_manager.py` thay vì inline Python
- `.gitignore`: Thêm — vault.yml, .vault_pass, *.retry sẽ không bị commit
- `GROUPS.md`: Cập nhật MinIO trong monitoring_loki



### Fixed — Critical
- `all.yml`: Sửa group names sai (`monitoring` → đúng group theo service)
- `haproxy.cfg.j2`: Dùng đúng group (`monitoring_grafana`, `monitoring_query`, `monitoring_alertmanager`, `monitoring_loki`)
- VictoriaMetrics: Tách thành 3 roles riêng biệt (`vmstorage`, `vminsert`, `vmselect`)
- Vault: Chuyển tất cả secrets vào `vault.yml` — không còn plain text trong `all.yml`
- Promtail: Gửi log về VIP thay vì trực tiếp từng node (tránh duplicate)

### Fixed — High
- Keepalived: `nopreempt` chỉ áp dụng cho BACKUP nodes
- `site.yml`: Thêm `serial: 1` cho vmstorage, vmquery, grafana, alertmanager, loki
- `upgrade.yml`: Health check cluster trước mỗi rolling node
- PostgreSQL: Thêm `promote-replica.yml` cho manual failover
- `run.sh`: Deploy dùng `site.yml` duy nhất thay vì nhiều playbook riêng lẻ

### Fixed — Medium/Low
- Loki: Đổi storage từ `filesystem` sang MinIO (S3-compatible, cluster-safe)
- Alert rules: Thêm `files/alert-rules/node.yml` và `infrastructure.yml` mặc định
- Grafana: Thêm datasource provisioning tự động (VictoriaMetrics + Loki + Alertmanager)
- Python: Tách inline script ra `scripts/targets_manager.py`
- Thêm `CHANGELOG.md`
- Thêm resource limits cho tất cả Docker containers
- Thêm log rotation cho Docker containers

## [2.0.0] — 2026-03-28

### Added
- Tách groups theo service: `monitoring_storage`, `monitoring_query`, `monitoring_grafana`, `monitoring_vmagent`, `monitoring_alertmanager`, `monitoring_db`, `monitoring_loki`
- Loki + Promtail log monitoring
- `manage-targets.sh` + `scripts/targets_manager.py`
- GitOps: Gitea + Ansible Runner webhook
- `run.sh` menu-driven deployment tool
- `GROUPS.md` documentation

## [1.0.0] — Initial

### Added
- VictoriaMetrics cluster
- Grafana HA
- HAProxy + Keepalived VIP
- Alertmanager gossip cluster
- vmagent active-active
- PostgreSQL primary + replica
