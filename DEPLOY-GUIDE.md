# 📚 Hướng dẫn triển khai Monitoring Stack

> **Phiên bản:** 1.0  
> **Cập nhật:** 2026-03-30  
> **Stack:** VictoriaMetrics · Grafana · Loki · Promtail · vmagent · Alertmanager · HAProxy · Keepalived · Thanos (tuỳ chọn)

---

## 📋 Mục lục

1. [Yêu cầu hệ thống](#1-yêu-cầu-hệ-thống)
2. [Kiến trúc hệ thống](#2-kiến-trúc-hệ-thống)
3. [Cấu hình trước khi deploy](#3-cấu-hình-trước-khi-deploy)
4. [Giai đoạn triển khai](#4-giai-đoạn-triển-khai)
5. [Kiểm tra sau deploy](#5-kiểm-tra-sau-deploy)
6. [Truy cập hệ thống](#6-truy-cập-hệ-thống)
7. [Xử lý sự cố phổ biến](#7-xử-lý-sự-cố-phổ-biến)
8. [Gỡ cài đặt](#8-gỡ-cài-đặt)

---

## 1. Yêu cầu hệ thống

### 1.1 Cơ sở hạ tầng

| Node | IP | Hostname | RAM | CPU | Disk |
|------|----|----------|-----|-----|------|
| Ansible Controller | 10.171.131.59 | ansible | 2GB+ | 2 core | 20GB |
| Monitoring Node 1 | 10.171.131.31 | obs01 | 8GB+ | 4 core | 100GB |
| Monitoring Node 2 | 10.171.131.32 | obs02 | 8GB+ | 4 core | 100GB |
| Monitoring Node 3 | 10.171.131.33 | obs03 | 8GB+ | 4 core | 100GB |
| **VIP (HAProxy)** | **10.171.131.30** | — | — | — | — |

### 1.2 Phần mềm yêu cầu trên Ansible Controller

```bash
# Kiểm tra phiên bản
ansible --version        # >= 2.13
python3 --version        # >= 3.8

# Cài đặt collections cần thiết
ansible-galaxy collection install community.docker community.general
```

### 1.3 Yêu cầu network

- Ansible Controller → 3 nodes: SSH port 22
- 3 nodes → internet: HTTPS port 443 (pull Docker images)
- 3 nodes → nhau: các port cluster (xem danh sách port bên dưới)
- Người dùng → VIP 10.171.131.30: các port truy cập

---

## 2. Kiến trúc hệ thống

```
                     ┌─────────────────────────────────────┐
                     │         VIP: 10.171.131.30           │
                     │     HAProxy + Keepalived (LB)         │
                     └──────┬──────────┬──────────┬─────────┘
                            │          │          │
                   ┌────────▼──┐  ┌────▼──────┐  ┌▼──────────┐
                   │   obs01   │  │   obs02   │  │   obs03   │
                   │.131.31    │  │.131.32    │  │.131.33    │
                   ├───────────┤  ├───────────┤  ├───────────┤
                   │vmstorage  │  │vmstorage  │  │vmstorage  │
                   │vminsert   │  │vminsert   │  │vminsert   │
                   │vmselect   │  │vmselect   │  │vmselect   │
                   │grafana    │  │grafana    │  │grafana    │
                   │postgresql │  │postgresql │  │postgresql │
                   │alertmgr   │  │alertmgr   │  │           │
                   │vmagent    │  │vmagent    │  │vmagent    │
                   │loki       │  │           │  │loki       │
                   │promtail   │  │promtail   │  │promtail   │
                   │gitea      │  │           │  │           │
                   │blackbox   │  │blackbox   │  │blackbox   │
                   │[thanos*]  │  │[thanos*]  │  │[thanos*]  │
                   └───────────┘  └───────────┘  └───────────┘

* Thanos chỉ khi s3_enabled: true
```

### 2.1 Danh sách port

#### Truy cập qua VIP (10.171.131.30)

| Port | Service | Mục đích |
|------|---------|----------|
| 80 | Grafana | Web UI giám sát |
| 8404 | HAProxy Stats | Theo dõi backend |
| 8429 | vmagent | Remote write / UI |
| 8480 | vminsert | Prometheus remote write |
| 8481 | vmselect | PromQL query |
| 9093 | Alertmanager | Alert management |
| 9115 | Blackbox Exporter | Probe HTTP/ICMP |
| 3100 | Loki | Log push / query |
| 10902 | Thanos Query | Long-term query (s3_enabled=true) |

#### Internal cluster (không mở ra ngoài)

| Port | Service |
|------|---------|
| 9100 | node_exporter |
| 9080 | Promtail |
| 8482 | vmstorage |
| 3001 | Gitea HTTP |
| 2222 | Gitea SSH |
| 5432 | PostgreSQL |
| 7946 | Loki memberlist |
| 9094 | Alertmanager cluster |
| 19291 | Thanos remote-write |
| 10907 | Thanos receive gRPC |

---

## 3. Cấu hình trước khi deploy

### 3.1 Kiểm tra inventory

```bash
cat /opt/monitoring-ansible/inventory/monitoring.yml
```

Đảm bảo IP và hostname đúng với thực tế:

```yaml
# inventory/monitoring.yml
monitoring_lb:
  hosts:
    obs01:
      ansible_host: 10.171.131.31
    obs02:
      ansible_host: 10.171.131.32
    obs03:
      ansible_host: 10.171.131.33
```

### 3.2 Kiểm tra group_vars

File cấu hình chính: `inventory/group_vars/all/main.yml`

Các tham số quan trọng cần kiểm tra:

```yaml
# VIP address
vip_address: "10.171.131.30"
vip_interface: "ens3"          # ← Đổi theo NIC thực tế

# S3/Thanos (tuỳ chọn)
s3_enabled: false              # true nếu muốn dùng Thanos + S3

# Grafana
grafana_admin_password: "admin123"   # ← Đổi mật khẩu mặc định
```

### 3.3 Kiểm tra vault (credentials)

```bash
cat /opt/monitoring-ansible/inventory/group_vars/all/vault.yml
```

Cần có:
```yaml
vault_grafana_admin_password: "your_password"
vault_s3_access_key: "your_key"        # nếu s3_enabled: true
vault_s3_secret_key: "your_secret"     # nếu s3_enabled: true
vault_s3_bucket: "your_bucket"
vault_s3_endpoint: "https://s3.example.com"
```

### 3.4 Kiểm tra SSH connectivity

```bash
cd /opt/monitoring-ansible
ansible all -i inventory/ -m ping
```

Kết quả mong đợi:
```
obs01 | SUCCESS => {"ping": "pong"}
obs02 | SUCCESS => {"ping": "pong"}
obs03 | SUCCESS => {"ping": "pong"}
```

### 3.5 Kiểm tra NIC interface name

```bash
ansible all -i inventory/ -m shell -a "ip link show | grep -E '^[0-9]+:' | grep -v lo"
```

> ⚠️ Nếu NIC không phải `ens3`, sửa lại `vip_interface` trong `main.yml`

---

## 4. Giai đoạn triển khai

> **Khuyến nghị:** Deploy từng giai đoạn để dễ debug nếu có lỗi.

---

### 🟦 Giai đoạn 1 — Nền tảng hệ thống

**Bao gồm:** OS cơ bản · node_exporter · Docker · Keepalived · HAProxy

```bash
cd /opt/monitoring-ansible
ansible-playbook playbooks/site.yml -i inventory/ \
  --tags common,node_exporter,docker,keepalived,haproxy
```

**Thời gian ước tính:** 5–10 phút

**Kiểm tra:**
```bash
# VIP đang active trên obs01
ssh root@10.171.131.31 "ip addr show | grep 10.171.131.30"

# HAProxy stats
curl -s http://10.171.131.30:8404/stats | grep -c "UP"

# Docker đang chạy
ansible monitoring_lb -i inventory/ -m shell -a "docker ps"
```

✅ **Đạt khi:** VIP xuất hiện trên obs01, HAProxy stats accessible

---

### 🟦 Giai đoạn 2 — VictoriaMetrics Cluster

**Bao gồm:** vmstorage · vminsert · vmselect

```bash
ansible-playbook playbooks/site.yml -i inventory/ \
  --tags vmstorage,vminsert,vmselect
```

**Thời gian ước tính:** 3–5 phút

**Kiểm tra:**
```bash
# Query test
curl "http://10.171.131.30:8481/select/0/prometheus/api/v1/query?query=1"
# Kết quả mong đợi: {"status":"success",...}

# Storage health
curl http://10.171.131.31:8482/health
curl http://10.171.131.32:8482/health
curl http://10.171.131.33:8482/health
```

✅ **Đạt khi:** Query trả về `{"status":"success"}`

---

### 🟦 Giai đoạn 3 — PostgreSQL + Grafana

**Bao gồm:** PostgreSQL · Grafana (với datasource tự động)

```bash
ansible-playbook playbooks/site.yml -i inventory/ \
  --tags postgresql,grafana
```

**Thời gian ước tính:** 5–8 phút

**Kiểm tra:**
```bash
# Grafana health
curl http://10.171.131.30/api/health
# Kết quả: {"commit":"...","database":"ok","version":"..."}
```

✅ **Đạt khi:** Truy cập http://10.171.131.30 thấy Grafana login

---

### 🟦 Giai đoạn 4 — Alertmanager + vmagent

**Bao gồm:** Alertmanager cluster · vmagent (scrape + remote write)

```bash
ansible-playbook playbooks/site.yml -i inventory/ \
  --tags alertmanager,vmagent
```

**Thời gian ước tính:** 3–5 phút

**Kiểm tra:**
```bash
# Alertmanager
curl http://10.171.131.30:9093/-/healthy

# vmagent targets
curl http://10.171.131.30:8429/targets | grep '"health":"up"' | wc -l
```

✅ **Đạt khi:** vmagent có targets UP, metrics bắt đầu vào VictoriaMetrics

---

### 🟦 Giai đoạn 5 — Logging (Loki + Promtail)

**Bao gồm:** Loki cluster · Promtail (systemd binary)

```bash
ansible-playbook playbooks/site.yml -i inventory/ \
  --tags loki,promtail
```

**Thời gian ước tính:** 5–8 phút

> ⚠️ Loki memberlist cluster cần 1–2 phút để ổn định sau khi start.

**Kiểm tra:**
```bash
# Loki ready (chờ ~60s sau deploy)
curl http://10.171.131.30:3100/ready
# Kết quả: "ready"

# Promtail trên từng node
ssh root@10.171.131.31 "systemctl status promtail"
```

✅ **Đạt khi:** Loki trả về `ready`, Grafana Explore → Loki có logs

---

### 🟦 Giai đoạn 6 — Gitea + Blackbox

**Bao gồm:** Gitea · Blackbox random ping

```bash
ansible-playbook playbooks/site.yml -i inventory/ \
  --tags gitea,random_ping
```

**Thời gian ước tính:** 3–5 phút

---

### 🟨 Giai đoạn 7 — Thanos S3 (Tuỳ chọn)

> Chỉ thực hiện khi cần long-term storage với S3.

**Bước 1:** Cấu hình S3 credentials trong vault.yml

**Bước 2:** Bật flag trong main.yml
```bash
ssh root@10.171.131.59
sed -i 's/^s3_enabled:.*/s3_enabled: true/' \
  /opt/monitoring-ansible/inventory/group_vars/all/main.yml
```

**Bước 3:** Deploy
```bash
ansible-playbook playbooks/site.yml -i inventory/ --tags thanos,haproxy
```

**Kiểm tra:**
```bash
# Thanos receive
curl http://10.171.131.31:19290/-/ready

# Thanos query (qua HAProxy)
curl http://10.171.131.30:10902/-/ready
```

---

### 🚀 Deploy tất cả 1 lần (s3_enabled: false)

```bash
cd /opt/monitoring-ansible
ansible-playbook playbooks/site.yml -i inventory/
```

**Thời gian ước tính toàn bộ:** 20–30 phút

---

## 5. Kiểm tra sau deploy

### 5.1 Chạy playbook verify

```bash
ansible-playbook playbooks/ops/verify.yml -i inventory/
```

### 5.2 Checklist thủ công

```bash
# 1. VIP active
ssh root@10.171.131.31 "ip addr show | grep 10.171.131.30"

# 2. Tất cả containers đang Up
ansible monitoring_lb -i inventory/ -m shell \
  -a "docker ps --format 'table {{.Names}}\t{{.Status}}'"

# 3. HAProxy backends
curl -s -u admin:admin http://10.171.131.30:8404/stats;csv \
  | awk -F',' '$18=="UP"{print $2,$18}' | sort

# 4. VictoriaMetrics query
curl -s "http://10.171.131.30:8481/select/0/prometheus/api/v1/query?query=up" \
  | python3 -m json.tool | grep '"__name__"'

# 5. Loki
curl http://10.171.131.30:3100/ready

# 6. Grafana
curl -s http://10.171.131.30/api/health | python3 -m json.tool
```

### 5.3 Kiểm tra trên Grafana UI

1. Mở http://10.171.131.30
2. Đăng nhập: `admin` / `<grafana_admin_password>`
3. **Explore → VictoriaMetrics** → chạy query `up` → thấy metrics
4. **Explore → Loki** → chọn label `job` → thấy logs
5. **Dashboards** → Import dashboard ID `1860` (Node Exporter Full)

---

## 6. Truy cập hệ thống

| Service | URL | Credentials |
|---------|-----|-------------|
| **Grafana** | http://10.171.131.30 | admin / (xem vault.yml) |
| **HAProxy Stats** | http://10.171.131.30:8404/stats | admin / admin |
| **vmagent UI** | http://10.171.131.30:8429 | — |
| **vmselect API** | http://10.171.131.30:8481 | — |
| **Alertmanager** | http://10.171.131.30:9093 | — |
| **Loki** | http://10.171.131.30:3100 | — |
| **Gitea** | http://10.171.131.31:3001 | (setup lần đầu) |
| **Thanos Query** | http://10.171.131.30:10902 | — (chỉ khi s3=true) |

---

## 7. Xử lý sự cố phổ biến

### ❌ VIP không lên

```bash
# Kiểm tra keepalived
ssh root@10.171.131.31 "systemctl status keepalived"
ssh root@10.171.131.31 "journalctl -u keepalived -n 20"

# Kiểm tra NIC đúng chưa
ssh root@10.171.131.31 "ip link show"
# Sửa vip_interface trong main.yml nếu sai
```

### ❌ Container restart liên tục

```bash
# Xem log container
ssh root@10.171.131.31 "docker logs <container_name> 2>&1 | tail -20"

# Kiểm tra permission data dir
ssh root@10.171.131.31 "ls -la /data/"
```

### ❌ Thanos-receive permission denied

```bash
# Fix ownership (user 1001)
ssh root@10.171.131.31 "chown -R 1001:1001 /data/thanos"

# Fix objstore.yml permission
ssh root@10.171.131.31 "chmod 644 /opt/monitoring/thanos-receive/objstore.yml"
```

### ❌ Loki 503 sau deploy

Loki memberlist cần thời gian hội tụ cluster. Chờ 60–90 giây rồi thử lại:
```bash
watch -n5 'curl -s http://10.171.131.30:3100/ready'
```

### ❌ HAProxy port conflict với container

Xảy ra khi HAProxy và container cùng dùng 1 port (ví dụ thanos-query).
Giải pháp đã áp dụng:
- thanos-query bind `127.0.0.1:10912` (internal)
- HAProxy listen `*:10902` → forward tới `10912`

### ❌ vmagent scrape lỗi group không tồn tại

```
undefined error: groups['monitoring_promtail']
```

Đã fix trong template: dùng `groups.get('promtail_nodes', [])` thay vì `groups['monitoring_promtail']`.

---

## 8. Gỡ cài đặt

### 8.1 Xóa containers + volumes + data

```bash
ansible monitoring_lb -i inventory/ -m shell -a "
  docker ps -aq | xargs -r docker rm -f
  docker volume ls -q | xargs -r docker volume rm -f
  rm -rf /opt/monitoring /data/vmstorage /data/grafana /data/postgres \
         /data/alertmanager /data/vmagent /data/loki /data/thanos /data/gitea
"
```

### 8.2 Gỡ system services

```bash
ansible monitoring_lb -i inventory/ -m shell -a "
  systemctl stop node_exporter promtail haproxy keepalived
  systemctl disable node_exporter promtail haproxy keepalived
  apt-get remove --purge -y haproxy keepalived
  rm -f /usr/local/bin/node_exporter /usr/local/bin/promtail
  rm -f /etc/systemd/system/node_exporter.service
  rm -f /etc/systemd/system/promtail.service
  systemctl daemon-reload
"
```

### 8.3 Gỡ Docker

```bash
ansible monitoring_lb -i inventory/ -m shell -a "
  systemctl stop docker
  apt-get remove --purge -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  rm -rf /var/lib/docker /etc/docker /opt/containerd
"
```

---

## 📝 Ghi chú quan trọng

> **objstore.yml:** Deploy với `mode: 0644` (không phải 0600) để container user 1001 đọc được.

> **thanos-receive ports:** `--http-address=0.0.0.0:19290` và `--remote-write.address=0.0.0.0:19291` — **phải khác nhau**, không dùng chung 1 port.

> **thanos-query health check:** Check qua `127.0.0.1:10912` (delegate_to node), không check qua external IP vì bind là localhost-only.

> **Loki memberlist:** Sau khi deploy, chờ ít nhất 60 giây trước khi kiểm tra `/ready`.
