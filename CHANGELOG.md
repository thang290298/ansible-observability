# CHANGELOG.md

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
