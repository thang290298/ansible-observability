# GROUPS.md — Quy hoạch groups & hướng dẫn scale
# =============================================================================

## Bản đồ groups — service và node count

```
GROUP                    SERVICE                          KHI NÀO SCALE
─────────────────────────────────────────────────────────────────────────────
monitoring_lb        →   Keepalived + HAProxy             Hiếm khi — 3 nodes đủ HA
monitoring_storage   →   vmstorage                        Disk đầy / I/O cao
monitoring_query     →   vminsert + vmselect              Ingestion cao / query chậm
monitoring_grafana   →   Grafana                          Nhiều user / dashboard nặng
monitoring_vmagent   →   vmagent (active-active)          Nhiều targets / scrape miss
monitoring_alertmanager → Alertmanager (gossip)           Thêm redundancy (max 3)
monitoring_db        →   PostgreSQL primary+replica       Read nhiều / cần replica
monitoring_loki      →   Loki + MinIO (S3 backend)        Log volume lớn / disk đầy
                         ├─ Loki cluster (memberlist HA)
                         └─ MinIO distributed (erasure coding)
monitoring_gitea     →   Gitea + Ansible Runner           Không cần scale
─────────────────────────────────────────────────────────────────────────────
ceph_<name>          →   node_exporter + ceph_exporter    Thêm node ceph mới
compute_<site>       →   node_exporter                    Thêm compute mới
controller_<site>    →   node_exporter + openstack_exp    Thêm controller mới
─────────────────────────────────────────────────────────────────────────────
promtail_nodes       →   Promtail (log agent)             Tự động — mọi server
```

---

## Khi nào scale service nào?

### vmstorage (monitoring_storage)
- Disk usage > 70%
- I/O wait cao liên tục
- Ingestion rate tăng dài hạn
- **Thêm node → data tự phân phối, không cần migrate**

### vminsert / vmselect (monitoring_query)
- vminsert: ingestion latency tăng, queue đầy
- vmselect: query dashboard chậm, timeout
- Có thể thêm node query mà KHÔNG cần thêm storage
- **HAProxy tự thêm backend, không downtime**

### Grafana (monitoring_grafana)
- Dashboard load chậm khi nhiều user đồng thời
- CPU/RAM Grafana cao
- **Cookie-based session — user không bị logout**

### vmagent (monitoring_vmagent)
- Scrape interval bị miss (target.scrape_pool_targets > 500/instance)
- CPU vmagent > 70%
- **Thêm vmagent = thêm 1 bản scrape đầy đủ, vmselect dedup**

### Alertmanager (monitoring_alertmanager)
- Thêm redundancy (2 → 3 nodes)
- **Gossip tự đồng bộ, không gửi alert 2 lần**

### PostgreSQL (monitoring_db)
- Read nhiều (Grafana annotations, user queries)
- Thêm replica để offload read
- **Primary vẫn là node01, replica đọc được**

---

## Cách scale từng service

### Bước 1: Thêm node vào đúng group

```yaml
# inventory/hosts.yml

# Ví dụ: chỉ scale vmagent (scrape nhiều targets)
monitoring_vmagent:
  hosts:
    node01: { ansible_host: 10.x.x.1 }
    node02: { ansible_host: 10.x.x.2 }
    node03: { ansible_host: 10.x.x.3 }  # ← THÊM VÀO ĐÂY

# Ví dụ: chỉ scale vmstorage (disk đầy)
monitoring_storage:
  hosts:
    node01: { ansible_host: 10.x.x.1 }
    node02: { ansible_host: 10.x.x.2 }
    node03: { ansible_host: 10.x.x.3 }
    node04: { ansible_host: 10.x.x.4 }  # ← THÊM VÀO ĐÂY
```

### Bước 2: Chạy scale

```bash
./run.sh scale
# Menu hiện ra:
# [1] vmstorage
# [2] vminsert/vmselect
# [3] Grafana
# [4] vmagent
# [5] Alertmanager
# [6] Tất cả
```

### Hoặc chỉ định thẳng bằng tag

```bash
# Scale chỉ vmagent
./run.sh scale --tags scale-vmagent

# Scale chỉ storage
./run.sh scale --tags scale-storage

# Dry-run trước khi scale thật
./run.sh scale --check
```

---

## Quy tắc đặt tên group

- `monitoring_*`      → monitoring service nodes
- `ceph_<cluster>`    → ceph cluster theo tên (ceph_dbp3, ceph_hn4...)
- `compute_<site>`    → compute nodes theo site (compute_hn4, compute_dbp...)
- `controller_<site>` → controller nodes theo site
