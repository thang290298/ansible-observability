# 🚀 Monitoring Stack — Ansible Deployment Guide

> **Version:** 6.0.0 | **OS:** Ubuntu 24.04 | **Cập nhật:** 2026-03-29

---

## 📋 Mục lục

1. [Thông tin hệ thống](#thông-tin-hệ-thống)
2. [Stack Components](#stack-components)
3. [Yêu cầu hệ thống](#yêu-cầu-hệ-thống)
4. [Cấu trúc thư mục](#cấu-trúc-thư-mục)
5. [Cách dùng cơ bản](#cách-dùng-cơ-bản)
6. [Stack Commands](#stack-commands)
7. [Thêm server mới](#thêm-server-mới)
8. [Đổi IP / Inventory](#đổi-ip--inventory)
9. [Đổi cấu hình](#đổi-cấu-hình)
10. [Quản lý Scrape Targets](#quản-lý-scrape-targets)
11. [Reconfig](#reconfig)
12. [Upgrade Version](#upgrade-version)
13. [GitOps Workflow](#gitops-workflow)
14. [Truy cập dịch vụ sau deploy](#truy-cập-dịch-vụ-sau-deploy)
15. [Lưu ý quan trọng](#lưu-ý-quan-trọng)
16. [Xử lý lỗi thường gặp](#xử-lý-lỗi-thường-gặp)
17. [Tham chiếu nhanh](#tham-chiếu-nhanh)

---

## Thông tin hệ thống

| Thành phần       | IP / Ghi chú                              |
|------------------|-------------------------------------------|
| **Jump Server**  | `10.171.131.59`                           |
| **obs01**        | `10.171.131.31` — MASTER (priority 101)   |
| **obs02**        | `10.171.131.32` — BACKUP (priority 100)   |
| **obs03**        | `10.171.131.33` — BACKUP (priority 99)    |
| **VIP**          | `10.171.131.30` (xem `all.yml`)           |
| **VIP Interface**| `ens3` (subnet /24)                       |
| **OS**           | Ubuntu 24.04 LTS                          |
| **Ansible Dir**  | `/opt/monitoring-ansible/`               |
| **Data Dir**     | `/data/`                                  |
| **S3 Endpoint**  | `s3hn.smartcloud.vn`                      |

### Keepalived VRRP

| Node  | State  | Priority | VRRP Router ID |
|-------|--------|----------|----------------|
| obs01 | MASTER | 101      | 51             |
| obs02 | BACKUP | 100      | 51             |
| obs03 | BACKUP | 99       | 51             |

> VIP failover < 3 giây khi MASTER down.

---

## Stack Components

| Service               | Nodes        | External Port | Ghi chú                              |
|-----------------------|--------------|---------------|--------------------------------------|
| HAProxy               | obs01,02,03  | 80, 443       | Load balancer toàn bộ traffic        |
| HAProxy Stats         | obs01,02,03  | 8404          | `/stats` dashboard                   |
| Keepalived            | obs01,02,03  | —             | VRRP giữ VIP                         |
| VictoriaMetrics insert| obs01,02,03  | 18480         | vminsert — ghi metrics               |
| VictoriaMetrics select| obs01,02,03  | 18481         | vmselect — đọc/query metrics         |
| VictoriaMetrics storage| obs01,02,03 | 8482          | vmstorage — lưu trữ                  |
| vmagent               | obs01,02,03  | 18429         | Scrape agent (active-active)         |
| Grafana               | obs01,02,03  | 13000         | Dashboard (dùng PostgreSQL chung)    |
| Loki                  | obs01, obs03 | 13100         | Log aggregation cluster              |
| Alertmanager          | obs01, obs02 | 19093         | Alert gossip cluster                 |
| Gitea                 | obs01        | 3000 (3001)   | Git + GitOps server                  |
| PostgreSQL            | obs01        | 5432          | Grafana backend DB                   |
| Node Exporter         | all          | 9100          | OS metrics                           |
| Blackbox Exporter     | all (lb)     | 9115          | ICMP/HTTP probe                      |
| Promtail              | all servers  | 9080          | Log shipper → Loki                   |

### Versions hiện tại

| Component           | Version         |
|---------------------|-----------------|
| VictoriaMetrics     | v1.102.9        |
| Grafana             | 11.4.0          |
| Alertmanager        | v0.28.0         |
| Loki                | 3.3.2           |
| Node Exporter       | 1.8.2           |
| Blackbox Exporter   | v0.25.0         |
| HAProxy             | 2.8             |
| PostgreSQL          | 15              |
| Gitea               | 1.22.3          |

---

## Yêu cầu hệ thống

### Ansible Controller (máy chạy playbook)

```bash
# Cài Ansible
pip3 install ansible
ansible --version

# Cài collections
ansible-galaxy collection install community.docker
ansible-galaxy collection install community.general
```

### Mỗi node server

- Ubuntu 22.04+ / Ubuntu 24.04 LTS
- Tối thiểu: 4 vCPU, 8GB RAM, 200GB SSD
- SSH access từ controller
- Python 3.x đã cài sẵn

---

## Cấu trúc thư mục

```
/opt/monitoring-ansible/
├── run.sh                              ← Entrypoint chính (wrapper cho ansible-playbook)
├── Makefile                            ← Shortcuts cho các lệnh phổ biến
├── ansible.cfg                         ← Ansible config (timeout, forks, retry...)
├── requirements.yml                    ← Ansible Galaxy collections
├── manage-targets.sh                   ← Quản lý scrape targets
│
├── inventory/
│   ├── monitoring.yml                  ← Inventory chính (obs01,02,03)
│   ├── groups.yml                      ← Group definitions
│   ├── site-dbp3.yml                   ← Inventory site DBP3
│   ├── site-dbp4.yml                   ← Inventory site DBP4
│   ├── site-ntl4.yml                   ← Inventory site NTL4
│   ├── host_vars/                      ← Per-host variables
│   │   ├── cephssd01-dbp4.yml
│   │   ├── compute01-dbp4.yml
│   │   ├── compute01-ntl4.yml
│   │   └── controller01-dbp4.yml
│   └── group_vars/
│       ├── all.yml                     ← Config toàn cục (VIP, versions, ports...)
│       ├── vault.yml                   ← Secrets (PHẢI encrypt trước commit)
│       ├── vault.yml.example           ← Template cho vault.yml
│       ├── exporters.yml               ← Config cho exporter nodes
│       ├── monitoring_alertmanager.yml
│       ├── monitoring_db.yml
│       ├── monitoring_loki.yml
│       ├── monitoring_vmagent.yml
│       ├── site_dbp3.yml               ← Site-specific vars
│       ├── site_dbp4.yml
│       └── site_ntl4.yml
│
├── playbooks/
│   ├── site.yml                        ← Full deploy (tất cả roles)
│   ├── stacks/                         ← Deploy theo stack riêng lẻ
│   │   ├── infra.yml                   ← common + docker + keepalived + haproxy
│   │   ├── monitoring.yml              ← vmstorage + vminsert + vmselect + vmagent + alertmanager
│   │   ├── grafana.yml                 ← postgresql + grafana
│   │   ├── logging.yml                 ← loki + promtail
│   │   └── gitops.yml                  ← gitea
│   ├── exporters/                      ← Deploy exporters
│   │   ├── all.yml                     ← Tất cả exporters
│   │   ├── node-exporter.yml
│   │   ├── blackbox.yml
│   │   ├── ceph-exporter.yml
│   │   ├── openstack-exporter.yml
│   │   └── gen-config.yml              ← Generate vmagent scrape configs
│   ├── reconfig/                       ← Reload config không restart
│   │   ├── all.yml
│   │   ├── monitoring.yml
│   │   ├── grafana.yml
│   │   ├── logging.yml
│   │   ├── alertmanager.yml
│   │   ├── haproxy.yml
│   │   └── exporters.yml
│   └── ops/                            ← Operations playbooks
│       ├── add-node.yml                ← Thêm server mới
│       ├── upgrade.yml                 ← Rolling upgrade
│       ├── scale.yml                   ← Scale service
│       ├── verify.yml                  ← Health check
│       ├── backup.yml                  ← Backup data
│       ├── destroy.yml                 ← Gỡ bỏ hoàn toàn
│       ├── promote-replica.yml         ← PostgreSQL failover
│       ├── prepare-disk.yml            ← Format và mount disk
│       └── random-ping.yml             ← Random ping monitoring
│
├── roles/
│   ├── common/                         ← OS config, chrony, logrotate
│   ├── docker/                         ← Cài Docker CE
│   ├── keepalived/                     ← VRRP, VIP config
│   ├── haproxy/                        ← Load balancer config
│   ├── node_exporter/                  ← Node metrics exporter
│   ├── vmstorage/                      ← VM storage node
│   ├── vminsert/                       ← VM insert endpoint
│   ├── vmselect/                       ← VM query endpoint
│   ├── vmagent/                        ← Scrape agent
│   ├── grafana/                        ← Dashboard
│   ├── alertmanager/                   ← Alert routing
│   ├── loki/                           ← Log storage
│   ├── promtail/                       ← Log shipper
│   ├── postgresql/                     ← DB backend
│   ├── gitea/                          ← Git server
│   ├── random_ping/                    ← Random ICMP ping monitor
│   ├── gen_config_vmagent/             ← Generate scrape configs từ inventory
│   └── minio/                          ← S3-compatible object storage
│
├── alert-rules/
│   ├── infrastructure.yml              ← Alert cho HAProxy, Keepalived, vmstorage
│   ├── node.yml                        ← Alert CPU, RAM, disk, network
│   └── random-ping.yml                 ← Alert rớt gói, latency cao
│
└── targets/                            ← Scrape targets (nếu dùng file-based SD)
```

---

## Cách dùng cơ bản

```bash
cd /opt/monitoring-ansible

# ─── FULL DEPLOY ──────────────────────────────────────────────────────
# Deploy toàn bộ tất cả roles (dùng lần đầu hoặc rebuild)
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml

# Dry run trước khi deploy thật
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --check

# ─── DEPLOY THEO ROLE ─────────────────────────────────────────────────
# Chỉ deploy Grafana
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --tags grafana

# Chỉ deploy VictoriaMetrics (storage + insert + select)
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --tags vm

# Chỉ deploy Loki + Promtail
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --tags logs

# Chỉ deploy infra (keepalived + haproxy)
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --tags lb

# ─── DEPLOY THEO NODE ─────────────────────────────────────────────────
# Chỉ chạy trên obs01
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --limit obs01

# Chỉ chạy trên obs01 và obs02
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --limit obs01,obs02

# ─── KẾT HỢP ─────────────────────────────────────────────────────────
# Deploy Grafana chỉ trên obs01
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --tags grafana --limit obs01

# ─── DEBUG ────────────────────────────────────────────────────────────
# Verbose output (tăng -v tới -vvvv để debug sâu hơn)
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml -v

# Test kết nối tất cả nodes
ansible -i inventory/monitoring.yml all -m ping
```

---

## Stack Commands

Deploy từng stack độc lập (nhanh hơn full deploy):

```bash
cd /opt/monitoring-ansible

# ─── INFRA STACK (common + docker + keepalived + haproxy) ─────────────
ansible-playbook -i inventory/monitoring.yml playbooks/stacks/infra.yml

# ─── MONITORING STACK (vmstorage + vminsert + vmselect + vmagent + alertmanager)
ansible-playbook -i inventory/monitoring.yml playbooks/stacks/monitoring.yml

# ─── GRAFANA STACK (postgresql + grafana) ─────────────────────────────
ansible-playbook -i inventory/monitoring.yml playbooks/stacks/grafana.yml

# ─── LOGGING STACK (loki + promtail) ──────────────────────────────────
ansible-playbook -i inventory/monitoring.yml playbooks/stacks/logging.yml

# ─── GITOPS STACK (gitea) ─────────────────────────────────────────────
ansible-playbook -i inventory/monitoring.yml playbooks/stacks/gitops.yml

# ─── EXPORTERS ────────────────────────────────────────────────────────
# Tất cả exporters
ansible-playbook -i inventory/monitoring.yml playbooks/exporters/all.yml

# Chỉ node_exporter
ansible-playbook -i inventory/monitoring.yml playbooks/exporters/node-exporter.yml

# Chỉ blackbox + random ping
ansible-playbook -i inventory/monitoring.yml playbooks/exporters/blackbox.yml

# Generate vmagent scrape configs từ inventory
ansible-playbook -i inventory/monitoring.yml playbooks/exporters/gen-config.yml
```

### Dùng run.sh (wrapper tiện lợi)

```bash
./run.sh deploy          # = site.yml (full deploy)
./run.sh infra           # stack infra
./run.sh monitoring      # stack monitoring
./run.sh grafana         # stack grafana
./run.sh logging         # stack logging
./run.sh gitops          # stack gitops
./run.sh exporters       # tất cả exporters
./run.sh node-exporter   # chỉ node_exporter
./run.sh blackbox        # chỉ blackbox
./run.sh gen-config      # generate scrape configs
./run.sh verify          # health check
./run.sh upgrade         # rolling upgrade
```

### Dùng Makefile

```bash
make deploy              # full deploy
make deploy-infra
make deploy-monitoring
make deploy-grafana
make deploy-logging
make deploy-gitops
make deploy-exporters
make gen-config
make verify
```

---

## Thêm server mới

### Thêm node vào monitoring cluster

**Bước 1: Cập nhật `inventory/monitoring.yml`**

```yaml
# inventory/monitoring.yml
all:
  children:
    monitoring_all:
      hosts:
        obs01:
          ansible_host: 10.171.131.31
          keepalived_priority: 101
          keepalived_state: MASTER
        obs02:
          ansible_host: 10.171.131.32
          keepalived_priority: 100
          keepalived_state: BACKUP
        obs03:
          ansible_host: 10.171.131.33
          keepalived_priority: 99
          keepalived_state: BACKUP
        obs04:                          # ← THÊM NODE MỚI
          ansible_host: 10.171.131.34
          keepalived_priority: 98
          keepalived_state: BACKUP

    monitoring_lb:
      hosts:
        obs01:
        obs02:
        obs03:
        obs04:     # ← thêm vào các group cần thiết
```

**Bước 2: Kiểm tra SSH kết nối được**

```bash
ansible -i inventory/monitoring.yml obs04 -m ping
```

**Bước 3: Deploy lên node mới**

```bash
# Chỉ deploy lên node mới
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --limit obs04

# Sau đó reconfig HAProxy trên tất cả nodes (để nhận backend mới)
ansible-playbook -i inventory/monitoring.yml playbooks/reconfig/haproxy.yml
```

**Bước 4: Verify**

```bash
ansible-playbook -i inventory/monitoring.yml playbooks/ops/verify.yml
```

### Thêm server client (chỉ cài exporter)

Dùng cho các server OpenStack, Ceph, Compute... cần được monitor nhưng không chạy stack monitoring.

**Bước 1: Thêm vào inventory**

```yaml
# Ví dụ thêm compute node vào site-dbp4.yml
compute_dbp4:
  vars:
    site: DBP4
    cluster: smartcloud2023
    role: compute
  hosts:
    compute05-dbp4:
      ansible_host: 10.x.x.205
```

**Bước 2: Tạo host_vars nếu cần**

```yaml
# inventory/host_vars/compute05-dbp4.yml
meta:
  ip: "10.x.x.205"
  host: "compute05-dbp4"
  site: "DBP4"
  role: "compute"
```

**Bước 3: Deploy exporter lên server mới**

```bash
ansible-playbook -i inventory/site-dbp4.yml playbooks/exporters/node-exporter.yml --limit compute05-dbp4
```

**Bước 4: Regenerate scrape config và reload vmagent**

```bash
ansible-playbook -i inventory/site-dbp4.yml playbooks/exporters/gen-config.yml
# vmagent tự reload qua SIGHUP — không cần restart
```

---

## Đổi IP / Inventory

### Trường hợp 1: Đổi IP một node

```yaml
# inventory/monitoring.yml — chỉ sửa ansible_host
obs01:
  ansible_host: 10.171.131.31    # ← đổi IP tại đây
  keepalived_priority: 101
  keepalived_state: MASTER
```

Sau khi sửa, chạy lại:

```bash
# Reconfig keepalived + haproxy để pick up IP mới
ansible-playbook -i inventory/monitoring.yml playbooks/stacks/infra.yml --limit obs01
```

### Trường hợp 2: Đổi VIP

```yaml
# inventory/group_vars/all.yml
vip_address: "10.171.131.30"    # ← đổi VIP
vip_interface: "ens3"            # ← đổi interface nếu cần
vip_prefix_len: 24               # ← đổi prefix nếu subnet khác
```

Sau đó deploy lại keepalived + haproxy:

```bash
ansible-playbook -i inventory/monitoring.yml playbooks/stacks/infra.yml
```

### Trường hợp 3: Scale từ 3 nodes lên 5 nodes

```yaml
# inventory/monitoring.yml
monitoring_all:
  hosts:
    obs01:
      ansible_host: 10.171.131.31
      keepalived_priority: 101
      keepalived_state: MASTER
    obs02:
      ansible_host: 10.171.131.32
      keepalived_priority: 100
      keepalived_state: BACKUP
    obs03:
      ansible_host: 10.171.131.33
      keepalived_priority: 99
      keepalived_state: BACKUP
    obs04:                          # NODE MỚI
      ansible_host: 10.171.131.34
      keepalived_priority: 98
      keepalived_state: BACKUP
    obs05:                          # NODE MỚI
      ansible_host: 10.171.131.35
      keepalived_priority: 97
      keepalived_state: BACKUP

monitoring_lb:
  hosts:
    obs01:
    obs02:
    obs03:
    obs04:
    obs05:

monitoring_victoria:
  hosts:
    obs01:
    obs02:
    obs03:
    obs04:    # vmstorage tự phân phối data — không cần migrate
    obs05:

monitoring_grafana:
  hosts:
    obs01:
    obs02:
    obs03:
    obs04:
    obs05:
```

### Trường hợp 4: Scale về 1 node (test/dev)

```yaml
# inventory/monitoring.yml — tối giản
monitoring_all:
  hosts:
    obs01:
      ansible_host: 10.171.131.31
      keepalived_priority: 101
      keepalived_state: MASTER

monitoring_lb:
  hosts:
    obs01:

monitoring_victoria:
  hosts:
    obs01:

monitoring_grafana:
  hosts:
    obs01:

monitoring_loki:
  hosts:
    obs01:

monitoring_alertmanager:
  hosts:
    obs01:

monitoring_gitea:
  hosts:
    obs01:

exporters:
  hosts:
    obs01:
```

> ⚠️ **Lưu ý inventory format:** File `monitoring.yml` KHÔNG dùng inline hosts format `{obs01:, obs02:}`.  
> Phải dùng **block format** (mỗi host xuống dòng riêng). Xem ví dụ trên.

---

## Đổi cấu hình

### all.yml — Config toàn cục

File: `/opt/monitoring-ansible/inventory/group_vars/all.yml`

```yaml
# ─── NETWORK ────────────────────────────────────────────────────────
vip_address: "10.171.131.30"      # ← VIP address
vip_interface: "ens3"              # ← Network interface
vip_prefix_len: 24                 # ← /24 subnet

# ─── VERSIONS ────────────────────────────────────────────────────────
# Chỉ thay đổi ở đây — Ansible tự apply lên tất cả nodes khi chạy upgrade
victoriametrics_version: "v1.102.9"
node_exporter_version: "1.8.2"
grafana_version: "11.4.0"
alertmanager_version: "v0.28.0"
loki_version: "3.3.2"
haproxy_version: "2.8"

# ─── PORTS ────────────────────────────────────────────────────────────
vminsert_port: 18480               # VictoriaMetrics insert
vmselect_port: 18481               # VictoriaMetrics select/query
vmstorage_port: 8482               # VictoriaMetrics storage
vmagent_port: 18429                # vmagent scrape agent
grafana_port: 13000                # Grafana (host:container = 13000:3000)
loki_port: 13100                   # Loki HTTP
alertmanager_port: 19093           # Alertmanager
node_exporter_port: 9100           # Node Exporter
blackbox_exporter_port: 9115       # Blackbox Exporter

# ─── RESOURCES ────────────────────────────────────────────────────────
vmstorage_mem_limit: "4g"
vmstorage_cpu_limit: "2.0"
vminsert_mem_limit: "1g"
vmselect_mem_limit: "2g"
loki_mem_limit: "2g"
vmagent_mem_limit: "1g"

# ─── S3 STORAGE (Loki + VictoriaMetrics backup) ───────────────────────
s3_enabled: true
s3_endpoint: "s3hn.smartcloud.vn"
s3_loki_bucket: "logs"
s3_metrics_bucket: "metrics"
```

### vault.yml — Secrets

File: `/opt/monitoring-ansible/inventory/group_vars/vault.yml`

> ⚠️ **KHÔNG bao giờ commit file này chưa encrypt!**

```bash
# Xem/sửa vault (cần vault password)
ansible-vault edit inventory/group_vars/vault.yml

# Encrypt lần đầu
ansible-vault encrypt inventory/group_vars/vault.yml

# Decrypt để sửa trực tiếp
ansible-vault decrypt inventory/group_vars/vault.yml
# ... sửa file ...
ansible-vault encrypt inventory/group_vars/vault.yml
```

Nội dung vault.yml (template từ `vault.yml.example`):

```yaml
vault_telegram_bot_token: ""          # Bot token Telegram
vault_telegram_chat_id: ""            # Chat ID nhận alert
vault_telegram_critical_chat_id: ""   # Chat ID cho critical alert

vault_grafana_admin_password: ""      # Grafana admin password
vault_grafana_db_password: ""         # Grafana PostgreSQL password
vault_postgres_password: ""           # PostgreSQL root password

vault_vrrp_auth_pass: ""              # Keepalived VRRP auth
vault_haproxy_stats_password: ""      # HAProxy stats page password

vault_gitea_db_password: ""           # Gitea DB password
vault_ansible_webhook_secret: ""      # Gitea webhook secret
vault_gitea_secret_key: ""            # Gitea SECRET_KEY (riêng biệt)

vault_minio_root_user: ""             # MinIO/S3 access key
vault_minio_root_password: ""         # MinIO/S3 secret key

vault_ssh_password: ""                # SSH password cho root (dùng trong monitoring.yml)
```

### Đổi scrape interval

```yaml
# inventory/group_vars/all.yml
vmagent_scrape_interval: "15s"   # ← đổi tại đây (default 15s)
```

Sau khi sửa, reload vmagent:

```bash
ansible-playbook -i inventory/monitoring.yml playbooks/reconfig/monitoring.yml
```

---

## Quản lý Scrape Targets

### Thêm target bằng manage-targets.sh

```bash
# Thêm 1 server vào node_exporter scraping
./manage-targets.sh add node_exporter 10.x.x.50 \
  --group compute-dbp4 \
  --labels "site=DBP4,cluster=smartcloud2023"

# Xóa target
./manage-targets.sh remove node_exporter 10.x.x.50

# Xem danh sách
./manage-targets.sh list
./manage-targets.sh list node_exporter

# Đếm tổng số targets
./manage-targets.sh count

# Apply thay đổi (reload vmagent)
./manage-targets.sh apply
```

### Generate scrape config tự động từ inventory

```bash
# Scan toàn bộ inventory → tạo scrape config file → reload vmagent
ansible-playbook -i inventory/monitoring.yml playbooks/exporters/gen-config.yml

# Gen cho site cụ thể
ansible-playbook -i inventory/site-dbp4.yml playbooks/exporters/gen-config.yml
```

Output files: `/opt/monitoring/vmagent/scrape_configs/scrape_<type>_<site>.yml`

### Kiểm tra targets đang active

```bash
# Xem tất cả targets (từ vmagent API)
curl http://10.171.131.31:18429/api/v1/targets | python3 -m json.tool

# Xem targets bị down
curl http://10.171.131.31:18429/api/v1/targets | python3 -m json.tool | grep -A5 '"health": "down"'
```

---

## Reconfig

Reload config mà **không restart** containers:

```bash
cd /opt/monitoring-ansible

# ─── RELOAD TẤT CẢ ────────────────────────────────────────────────────
ansible-playbook -i inventory/monitoring.yml playbooks/reconfig/all.yml

# ─── RELOAD THEO STACK ────────────────────────────────────────────────
# Reload vmagent scrape config + alert rules
ansible-playbook -i inventory/monitoring.yml playbooks/reconfig/monitoring.yml

# Reload Grafana datasource provisioning
ansible-playbook -i inventory/monitoring.yml playbooks/reconfig/grafana.yml

# Reload Loki + Promtail config
ansible-playbook -i inventory/monitoring.yml playbooks/reconfig/logging.yml

# Reload Alertmanager (POST /-/reload)
ansible-playbook -i inventory/monitoring.yml playbooks/reconfig/alertmanager.yml

# Reload HAProxy backends (graceful, không drop connections)
ansible-playbook -i inventory/monitoring.yml playbooks/reconfig/haproxy.yml

# Reload exporter scrape targets (SIGHUP → không restart)
ansible-playbook -i inventory/monitoring.yml playbooks/reconfig/exporters.yml
```

---

## Upgrade Version

```bash
# Bước 1: Cập nhật version trong all.yml
vim inventory/group_vars/all.yml
# victoriametrics_version: "v1.103.0"

# Bước 2: Rolling upgrade (1 node tại 1 thời điểm, không downtime)
ansible-playbook -i inventory/monitoring.yml playbooks/ops/upgrade.yml

# Chỉ upgrade một service
ansible-playbook -i inventory/monitoring.yml playbooks/ops/upgrade.yml --tags grafana

# Verify sau khi upgrade
ansible-playbook -i inventory/monitoring.yml playbooks/ops/verify.yml
```

---

## GitOps Workflow

```
Dev sửa config → git commit → git push → Gitea webhook → Ansible Runner → Deploy tự động → Telegram ✅
```

```bash
# Ví dụ workflow
cd /opt/monitoring-ansible
git add inventory/monitoring.yml
git commit -m "add: compute05-dbp4 to monitoring"
git push origin main
# → Gitea webhook trigger Ansible Runner
# → Tự động chạy gen-config + reconfig-exporters
# → Thông báo Telegram khi xong
```

---

## Truy cập dịch vụ sau deploy

| Service          | URL                                         | Credentials           |
|------------------|---------------------------------------------|-----------------------|
| Grafana          | http://10.171.131.30:80                     | admin / `<vault>`     |
| HAProxy Stats    | http://10.171.131.30:8404/stats             | admin / `<vault>`     |
| Alertmanager     | http://10.171.131.30:19093                  | —                     |
| vmselect API     | http://10.171.131.30:18481/select/0/prometheus | —                  |
| Gitea            | http://10.171.131.31:3000                   | —                     |
| vmagent UI       | http://10.171.131.31:18429                  | —                     |
| Loki             | http://10.171.131.30:13100                  | —                     |

> Password lấy từ `ansible-vault view inventory/group_vars/vault.yml`

---

## Lưu ý quan trọng

### ⚠️ Không có healthcheck trong docker-compose

VictoriaMetrics dùng **distroless image** — không có shell, không có `wget`/`curl` bên trong container.

```yaml
# ❌ SAI — sẽ crash vì không có shell/wget
healthcheck:
  test: ["CMD", "wget", "-qO-", "http://localhost:8482/health"]

# ✅ ĐÚNG — không dùng healthcheck trong compose
# Dùng Ansible uri module để check từ bên ngoài:
- name: Check vmstorage health
  ansible.builtin.uri:
    url: "http://{{ ansible_host }}:8482/health"
    status_code: 200
```

### ⚠️ Grafana port mapping

```yaml
# ❌ SAI
ports:
  - "3000:3000"

# ✅ ĐÚNG — external port 13000, container internal 3000
ports:
  - "13000:3000"
```

### ⚠️ Inventory format — dùng block format

```yaml
# ❌ SAI — inline format gây lỗi parse YAML
monitoring_lb:
  hosts:
    obs01: {ansible_host: 10.171.131.31}

# ✅ ĐÚNG — block format
monitoring_lb:
  hosts:
    obs01:
      ansible_host: 10.171.131.31
```

Hoặc dùng shorthand (tham chiếu host đã khai báo ở group khác):

```yaml
monitoring_lb:
  hosts:
    obs01:     # ← dòng trống — tham chiếu host đã có vars từ monitoring_all
    obs02:
    obs03:
```

### ⚠️ S3 endpoint không có https

```yaml
# S3 endpoint dùng domain, không phải IP
s3_endpoint: "s3hn.smartcloud.vn"   # ← ĐÚNG
# Không phải: "https://s3hn.smartcloud.vn" (tùy config role)
```

### ⚠️ VictoriaMetrics internal ports khác external ports

| Component  | External (host) | Internal (container) |
|------------|-----------------|----------------------|
| vminsert   | 18480           | 8480                 |
| vmselect   | 18481           | 8481                 |
| vmstorage  | 8482            | 8482                 |
| vmagent    | 18429           | 8429                 |

### ⚠️ ansible_user là root

Trong `inventory/monitoring.yml`, hệ thống này dùng `ansible_user: root` (không phải user ansible riêng):

```yaml
all:
  vars:
    ansible_user: root
    ansible_ssh_pass: "{{ vault_ssh_password }}"
```

### ⚠️ Alertmanager gossip cluster

- 2 nodes: obs01 + obs02 (obs03 không chạy Alertmanager)
- Nodes gossip với nhau qua port 9094
- Silences và inhibitions tự đồng bộ giữa 2 nodes

### ⚠️ Loki chỉ trên obs01 và obs03

- obs02 KHÔNG chạy Loki
- Loki replication_factor=2 → mỗi log chunk được lưu trên 2 nodes
- Memberlist tự discover nhau qua port 7946

---

## Xử lý lỗi thường gặp

### Ansible không kết nối được node

```bash
# Test SSH trực tiếp
ssh -o StrictHostKeyChecking=no root@10.171.131.31

# Kiểm tra ansible ping verbose
ansible -i inventory/monitoring.yml obs01 -m ping -vvv

# Kiểm tra vault password (nếu dùng encrypted vault)
ansible -i inventory/monitoring.yml all -m ping --ask-vault-pass
```

### VIP không failover khi MASTER down

```bash
# Xem keepalived log trên tất cả nodes
ansible -i inventory/monitoring.yml monitoring_lb -m shell \
  -a "journalctl -u keepalived -n 30 --no-pager"

# Xem VRRP state hiện tại
ansible -i inventory/monitoring.yml monitoring_lb -m shell \
  -a "ip addr show ens3 | grep 10.171.131.30"

# Kiểm tra port multicast
ansible -i inventory/monitoring.yml monitoring_lb -m shell \
  -a "ip maddr show ens3"
```

### HAProxy backend down

```bash
# Xem HAProxy stats page
curl -u admin:<password> http://10.171.131.30:8404/stats

# Xem log HAProxy
ansible -i inventory/monitoring.yml monitoring_lb -m shell \
  -a "journalctl -u haproxy -n 50 --no-pager"

# Restart HAProxy (nếu cần)
ansible -i inventory/monitoring.yml monitoring_lb -m shell \
  -a "systemctl restart haproxy"
```

### vmagent không scrape được target

```bash
# Xem targets list qua API
curl http://10.171.131.31:18429/api/v1/targets | python3 -m json.tool

# Xem vmagent container log
ansible -i inventory/monitoring.yml monitoring_victoria -m shell \
  -a "docker logs vmagent --tail 50"

# Reload vmagent config (SIGHUP, không restart)
ansible -i inventory/monitoring.yml monitoring_victoria -m shell \
  -a "docker kill --signal HUP vmagent"
```

### VictoriaMetrics không nhận data

```bash
# Check vmstorage health trên từng node
for node in 10.171.131.31 10.171.131.32 10.171.131.33; do
  echo "--- $node ---"
  curl -s http://$node:8482/health
  echo ""
done

# Check vminsert log
ansible -i inventory/monitoring.yml monitoring_victoria -m shell \
  -a "docker logs vminsert --tail 30"

# Kiểm tra disk
ansible -i inventory/monitoring.yml monitoring_victoria -m shell \
  -a "df -h /data/vmstorage"
```

### Loki không nhận logs

```bash
# Xem Loki status
curl http://10.171.131.31:13100/ready
curl http://10.171.131.31:13100/ring

# Xem Loki log
ansible -i inventory/monitoring.yml monitoring_loki -m shell \
  -a "docker logs loki --tail 50"

# Kiểm tra S3 bucket
ansible -i inventory/monitoring.yml monitoring_loki -m shell \
  -a "docker exec loki curl -s http://s3hn.smartcloud.vn"
```

### Grafana không hiển thị data

```bash
# Kiểm tra datasource
curl -u admin:<password> http://10.171.131.31:13000/api/datasources

# Check PostgreSQL connection
ansible -i inventory/monitoring.yml monitoring_db -m shell \
  -a "docker exec postgres pg_isready -U grafana"

# Xem Grafana log
ansible -i inventory/monitoring.yml monitoring_grafana -m shell \
  -a "docker logs grafana --tail 50"
```

### Alertmanager không gửi Telegram

```bash
# Xem Alertmanager config hiện tại
curl http://10.171.131.31:19093/api/v1/status

# Test gửi alert thủ công
curl -XPOST http://10.171.131.31:19093/api/v1/alerts \
  -H "Content-Type: application/json" \
  -d '[{"labels":{"alertname":"TestAlert","severity":"warning"}}]'

# Xem Alertmanager log
ansible -i inventory/monitoring.yml monitoring_alertmanager -m shell \
  -a "docker logs alertmanager --tail 50"
```

### Docker container bị unhealthy / restart loop

```bash
# Xem tất cả containers và status
ansible -i inventory/monitoring.yml monitoring_all -m shell \
  -a "docker ps -a --format 'table {{.Names}}\t{{.Status}}'"

# Xem log container cụ thể
ansible -i inventory/monitoring.yml obs01 -m shell \
  -a "docker logs <container_name> --tail 100"

# Restart container
ansible -i inventory/monitoring.yml obs01 -m shell \
  -a "docker restart <container_name>"
```

---

## Tham chiếu nhanh

### Ports cheat sheet

```
10.171.131.30 (VIP)
  :80     → Grafana (qua HAProxy)
  :443    → HTTPS (nếu cấu hình)
  :8404   → HAProxy stats
  :13100  → Loki API
  :18480  → vminsert (write metrics)
  :18481  → vmselect (query metrics)
  :19093  → Alertmanager

Mỗi node (obs01/02/03):
  :9100   → Node Exporter
  :9115   → Blackbox Exporter
  :18429  → vmagent UI
  :13000  → Grafana trực tiếp (không qua LB)
  :8482   → vmstorage health

obs01 only:
  :5432   → PostgreSQL
  :3000   → Gitea
```

### Tags tóm tắt

| Tag               | Mô tả                                |
|-------------------|--------------------------------------|
| `common`          | OS config, timezone, packages        |
| `docker`          | Cài Docker CE                        |
| `lb`              | Keepalived + HAProxy                 |
| `keepalived`      | Chỉ Keepalived                       |
| `haproxy`         | Chỉ HAProxy                          |
| `vm`              | Tất cả VictoriaMetrics               |
| `vmstorage`       | vmstorage only                       |
| `vmquery`         | vminsert + vmselect                  |
| `vmagent`         | vmagent only                         |
| `grafana`         | Grafana only                         |
| `db`, `postgresql`| PostgreSQL                           |
| `alertmanager`    | Alertmanager                         |
| `logs`            | Loki + Promtail                      |
| `loki`            | Loki only                            |
| `promtail`        | Promtail only                        |
| `gitea`           | Gitea only                           |
| `node_exporter`   | Node Exporter                        |
| `random-ping`     | Random ping monitoring               |
| `verify`          | Health check                         |

### Lệnh debug nhanh

```bash
# Xem tất cả containers trên tất cả nodes
ansible -i inventory/monitoring.yml monitoring_all -m shell \
  -a "docker ps --format '{{.Names}}: {{.Status}}'" 2>/dev/null

# Xem disk usage data dir
ansible -i inventory/monitoring.yml monitoring_all -m shell \
  -a "du -sh /data/* 2>/dev/null || echo 'no /data'"

# Xem service logs nhanh
ansible -i inventory/monitoring.yml obs01 -m shell \
  -a "docker logs grafana --tail 20 2>&1"
```

---

*Tài liệu này được duy trì cùng codebase tại `/opt/monitoring-ansible/README.md`.  
Mọi thay đổi kiến trúc cần cập nhật tài liệu này.*

*Version: 6.0.0 | Cập nhật: 2026-03-29*

---

## Changelog - v4-final (2026-03-30)

### Fixes từ kiểm nghiệm thực tế (cleanup + full redeploy)

| # | Vấn đề | Fix |
|---|--------|-----|
| 1 | `vault_ssh_password` thiếu trong vault.yml | Thêm `vault_ssh_password: "1"` |
| 2 | 5 inventory groups thiếu gây lỗi `dict object has no attribute` | Thêm: `monitoring_query`, `monitoring_storage`, `monitoring_vmagent`, `monitoring_db`, `monitoring_promtail` |
| 3 | `groups['monitoring']` sai tên trong alertmanager template | Fix → `groups['monitoring_alertmanager']` |
| 4 | `groups['monitoring_alertmanager']` sai trong victoriametrics template | Fix → `groups['monitoring_storage']` |
| 5 | Healthcheck trong 8 docker-compose templates | Xóa toàn bộ (distroless images không có shell) |
| 6 | `grafana_port: 3000` conflict giữa 2 group_vars file | Fix → `13000` trong cả hai |
| 7 | `blackbox-random-ping` port `9115` conflict với `blackbox-exporter` | Đổi sang `9116:9115` |
| 8 | `blackbox-random-ping` YAML template lỗi indent | Viết lại hoàn chỉnh |

### Kết quả redeploy
```
obs01: ok=42  changed=6   failed=0  exit=0 ✅
obs02: ok=24  changed=8   failed=0  exit=0 ✅
obs03: ok=27  changed=12  failed=0  exit=0 ✅
```
