# Tài Liệu Vận Hành — Monitoring Stack v5

> **Phiên bản:** 5.0 | **Cập nhật:** 2026-03-30  
> **Dành cho:** Ops / SRE team vận hành hàng ngày

---

## Mục Lục

1. [Thông tin nhanh (Quick Reference)](#1-thông-tin-nhanh)
2. [Kiểm tra sức khỏe hệ thống](#2-kiểm-tra-sức-khỏe-hệ-thống)
3. [Các thao tác thường ngày](#3-các-thao-tác-thường-ngày)
4. [Quản lý Backup](#4-quản-lý-backup)
5. [Quản lý Grafana](#5-quản-lý-grafana)
6. [Quản lý Alertmanager](#6-quản-lý-alertmanager)
7. [Quản lý Loki logs](#7-quản-lý-loki-logs)
8. [Quản lý VictoriaMetrics](#8-quản-lý-victoriametrics)
9. [Xử lý sự cố (Troubleshooting)](#9-xử-lý-sự-cố)
10. [Runbook — các tình huống khẩn cấp](#10-runbook)

---

## 1. Thông Tin Nhanh

### URLs & Tài khoản

| Service | URL | User | Pass |
|---|---|---|---|
| **Grafana** | http://10.171.131.30:13000 | admin | Admin@2024! |
| **HAProxy Stats** | http://10.171.131.30:8404/stats | admin | HAProxy@2024! |
| **Alertmanager** | http://10.171.131.30:9093 | — | — |
| **Loki** | http://10.171.131.30:3100 | — | — |
| **Gitea** | http://10.171.131.31:3001 | incosys | Gitea@2024! |
| **VMSelect** | http://10.171.131.30:8481 | — | — |
| **VMInsert** | http://10.171.131.30:8480 | — | — |

### Nodes

| | obs01 | obs02 | obs03 |
|---|---|---|---|
| IP | 10.171.131.31 | 10.171.131.32 | 10.171.131.33 |
| Role | MASTER | BACKUP | BACKUP |
| SSH | `ssh root@10.171.131.31` | `ssh root@10.171.131.32` | `ssh root@10.171.131.33` |

### VIP: `10.171.131.30` (luôn trỏ vào node MASTER)

### S3 Backup
- Endpoint: `https://s3hn.smartcloud.vn`
- Bucket metrics: `metrics` (vmbackup)
- Bucket logs: `logs` (Loki — tương lai)
- Schedule: **hàng ngày 02:00 AM** (systemd timer)

---

## 2. Kiểm Tra Sức Khỏe Hệ Thống

### 2.1 Kiểm tra nhanh tất cả containers

```bash
for node in 10.171.131.31 10.171.131.32 10.171.131.33; do
  echo "=== $node ==="
  ssh root@$node "docker ps --format '{{.Names}}: {{.Status}}'"
  echo ""
done
```

### 2.2 Kiểm tra VIP (Keepalived)

```bash
# Node nào đang giữ VIP?
ip addr show | grep 10.171.131.30

# Hoặc từ xa
for node in 10.171.131.31 10.171.131.32 10.171.131.33; do
  result=$(ssh root@$node "ip addr show | grep -c 10.171.131.30" 2>/dev/null)
  if [ "$result" -gt "0" ]; then
    echo "VIP MASTER: $node"
  fi
done
```

### 2.3 Kiểm tra HAProxy

```bash
# Stats page
curl -s -u admin:HAProxy@2024! http://10.171.131.30:8404/stats | grep -E "UP|DOWN|MAINT"

# Backends UP
curl -s -u admin:HAProxy@2024! http://10.171.131.30:8404/stats?csv | awk -F, '$18=="UP" {print $1,$2}'
```

### 2.4 Kiểm tra VictoriaMetrics cluster

```bash
# vmselect health
curl -s http://10.171.131.30:8481/health

# vminsert health
curl -s http://10.171.131.30:8480/health

# vmstorage trên từng node
for node in 10.171.131.31 10.171.131.32 10.171.131.33; do
  status=$(curl -sf http://$node:8482/health && echo "OK" || echo "FAIL")
  echo "vmstorage $node: $status"
done

# Số metrics đang lưu
curl -s http://10.171.131.31:8482/metrics | grep vm_rows_added_to_storage_total
```

### 2.5 Kiểm tra Loki

```bash
# Chờ ~60s sau khi khởi động
curl -s http://10.171.131.30:3100/ready
# Expected: "ready"

# Ring members
curl -s http://10.171.131.31:3100/ring | python3 -c "import sys,json; d=json.load(sys.stdin); [print(m['addr'], m['state']) for m in d.get('shards',[])]"
```

### 2.6 Dashboard tổng quan

Truy cập Grafana: http://10.171.131.30:13000
- **Node Overview**: CPU, RAM, Disk từng node
- **VictoriaMetrics**: throughput, storage size
- **HAProxy**: requests/s, errors

---

## 3. Các Thao Tác Thường Ngày

### 3.1 Restart 1 service

```bash
# Restart vmstorage trên obs01
ssh root@10.171.131.31 "cd /opt/monitoring/vmstorage && docker compose restart"

# Restart Grafana trên tất cả nodes
for node in 10.171.131.31 10.171.131.32 10.171.131.33; do
  ssh root@$node "cd /opt/monitoring/grafana && docker compose restart"
done

# Restart Loki
for node in 10.171.131.31 10.171.131.33; do
  ssh root@$node "cd /opt/monitoring/loki && docker compose restart"
done
```

### 3.2 Xem logs container

```bash
# Logs real-time
ssh root@10.171.131.31 "docker logs -f vmstorage --tail 50"

# Logs có filter
ssh root@10.171.131.31 "docker logs loki 2>&1 | grep -i error | tail -20"

# Logs alertmanager
ssh root@10.171.131.31 "docker logs alertmanager 2>&1 | tail -30"
```

### 3.3 Kiểm tra disk usage

```bash
for node in 10.171.131.31 10.171.131.32 10.171.131.33; do
  echo "=== $node ==="
  ssh root@$node "df -h / && du -sh /data/*"
done
```

### 3.4 Reload config không restart

```bash
# Reload HAProxy
ssh root@10.171.131.31 "systemctl reload haproxy"

# Reload Alertmanager (không restart)
curl -X POST http://10.171.131.30:9093/-/reload

# Reload Keepalived
ssh root@10.171.131.31 "systemctl reload keepalived"
```

### 3.5 Deploy thay đổi cấu hình mới

```bash
# Chỉnh sửa config trong Ansible project
# Commit vào Git
# Deploy chỉ role thay đổi

cd /opt/monitoring-ansible
git pull origin main

# Ví dụ: chỉ update alertmanager config
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --tags alertmanager
```

---

## 4. Quản Lý Backup

### 4.1 Trạng thái backup timer

```bash
for node in 10.171.131.31 10.171.131.32 10.171.131.33; do
  echo "=== $node ==="
  ssh root@$node "systemctl status vmbackup.timer --no-pager"
done
```

### 4.2 Chạy backup thủ công ngay

```bash
# Backup obs01
ssh root@10.171.131.31 "systemctl start vmbackup.service"

# Xem logs backup
ssh root@10.171.131.31 "journalctl -u vmbackup.service -n 50"

# Hoặc chạy script trực tiếp
ssh root@10.171.131.31 "bash /opt/monitoring/vmbackup/backup.sh"
```

### 4.3 Kiểm tra backup trên S3

```bash
# Từ node obs01
ssh root@10.171.131.31 "
  docker run --rm \
    -e AWS_ACCESS_KEY_ID=GMSVFIKPIKJA7AUT27NW \
    -e AWS_SECRET_ACCESS_KEY=Ihwe8UJSD7dNgtYx93ra8QbVJn6kOCiknG5XrOQ4 \
    amazon/aws-cli:latest \
    s3 ls s3://metrics/ --endpoint-url https://s3hn.smartcloud.vn --recursive --human-readable
"
```

### 4.4 Restore từ S3 (khi cần)

```bash
# CẢNH BÁO: Dừng vmstorage trước khi restore
ssh root@10.171.131.31 "cd /opt/monitoring/vmstorage && docker compose stop"

# Restore về thư mục tạm
ssh root@10.171.131.31 "
  docker run --rm \
    -v /data/vmstorage-restored:/vmstorage-data \
    victoriametrics/vmrestore:v1.102.0-cluster \
    -src=s3://metrics/obs01/YYYY-MM-DD/ \
    -storageDataPath=/vmstorage-data \
    -customS3Endpoint=https://s3hn.smartcloud.vn \
    -s3.accessKeyID=GMSVFIKPIKJA7AUT27NW \
    -s3.secretAccessKey=Ihwe8UJSD7dNgtYx93ra8QbVJn6kOCiknG5XrOQ4
"

# Sau khi restore xong
ssh root@10.171.131.31 "cd /opt/monitoring/vmstorage && docker compose start"
```

### 4.5 Backup schedule

| Node | Time | Destination |
|---|---|---|
| obs01 | 02:00 AM + random ≤5min | s3://metrics/obs01/ |
| obs02 | 02:00 AM + random ≤5min | s3://metrics/obs02/ |
| obs03 | 02:00 AM + random ≤5min | s3://metrics/obs03/ |

---

## 5. Quản Lý Grafana

### 5.1 Thêm datasource mới

Grafana UI → Connections → Data sources → Add

**VictoriaMetrics (đã có):**
```
URL: http://10.171.131.30:8481/select/0/prometheus
Type: Prometheus
```

**Loki (đã có):**
```
URL: http://10.171.131.30:3100
Type: Loki
```

### 5.2 Import dashboard

```bash
# Qua API
curl -s -u admin:Admin@2024! \
  -H "Content-Type: application/json" \
  -d @dashboards/node-exporter.json \
  http://10.171.131.30:13000/api/dashboards/import
```

### 5.3 Export dashboard để lưu vào Git

```bash
# Lấy UID từ URL của dashboard
curl -s -u admin:Admin@2024! \
  http://10.171.131.31:13000/api/dashboards/uid/YOUR_DASHBOARD_UID \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d['dashboard'],indent=2))" \
  > dashboards/my-dashboard.json
```

### 5.4 Grafana bị lỗi không vào được

```bash
# Kiểm tra logs
ssh root@10.171.131.31 "docker logs grafana --tail 50 2>&1"

# Kiểm tra DB connection
ssh root@10.171.131.31 "docker exec postgresql psql -U grafana -d grafana -c '\l'"

# Restart Grafana
ssh root@10.171.131.31 "cd /opt/monitoring/grafana && docker compose restart"
```

---

## 6. Quản Lý Alertmanager

### 6.1 Xem alerts đang active

```bash
# Qua API
curl -s http://10.171.131.30:9093/api/v2/alerts | python3 -c "
import sys, json
alerts = json.load(sys.stdin)
for a in alerts:
    print(a['labels'].get('alertname'), '-', a['status']['state'])
"
```

### 6.2 Silence alert

```bash
# Silence 1h
curl -s -X POST http://10.171.131.30:9093/api/v2/silences \
  -H "Content-Type: application/json" \
  -d '{
    "matchers": [{"name": "alertname", "value": "HighCPUUsage", "isRegex": false}],
    "startsAt": "'$(date -u +%FT%TZ)'",
    "endsAt": "'$(date -u -d '+1 hour' +%FT%TZ)'",
    "createdBy": "ops",
    "comment": "Maintenance window"
  }'
```

### 6.3 Reload alertmanager config

```bash
# Sau khi sửa config (qua Ansible deploy)
curl -X POST http://10.171.131.30:9093/-/reload
```

### 6.4 Test gửi alert Telegram

```bash
curl -s -X POST http://10.171.131.30:9093/api/v2/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {"alertname": "TestAlert", "severity": "warning", "instance": "test"},
    "annotations": {"summary": "Test alert từ ops team"}
  }]'
```

---

## 7. Quản Lý Loki Logs

### 7.1 Query logs qua API

```bash
# Xem logs từ obs01 trong 5 phút qua
curl -s "http://10.171.131.30:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="varlogs", host="obs01"}' \
  --data-urlencode "start=$(date -u -d '5 minutes ago' +%s)000000000" \
  --data-urlencode "end=$(date -u +%s)000000000" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(v[1]) for r in d['data']['result'] for v in r['values']]"
```

### 7.2 Kiểm tra Loki ring (cluster health)

```bash
curl -s http://10.171.131.31:3100/ring
# Phải thấy 2 members: obs01 và obs03 với state ACTIVE
```

### 7.3 Kiểm tra ingester

```bash
curl -s http://10.171.131.31:3100/ingester/ring
```

### 7.4 Loki không ready sau khởi động

Loki cần 30-60s để join ring. Nếu sau 2 phút vẫn 503:

```bash
ssh root@10.171.131.31 "docker logs loki --tail 50 2>&1"

# Lỗi thường gặp:
# 1. permission denied /loki/rules → mkdir -p /data/loki/rules && chmod 777 /data/loki
# 2. S3 connection failed → kiểm tra network
# 3. Ring timeout → restart cả 2 nodes Loki cùng lúc
```

---

## 8. Quản Lý VictoriaMetrics

### 8.1 Kiểm tra cluster status

```bash
# Storage nodes healthy
for node in 10.171.131.31 10.171.131.32 10.171.131.33; do
  status=$(curl -sf http://$node:8482/health && echo "OK" || echo "FAIL")
  echo "vmstorage $node: $status"
done

# Data size
for node in 10.171.131.31 10.171.131.32 10.171.131.33; do
  size=$(ssh root@$node "du -sh /data/vmstorage 2>/dev/null | cut -f1")
  echo "vmstorage $node data: $size"
done
```

### 8.2 Query test

```bash
# Query số metrics
curl -s "http://10.171.131.30:8481/select/0/prometheus/api/v1/query?query=up" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('Total metrics:', len(d['data']['result']))"
```

### 8.3 Snapshot (trước khi backup thủ công)

```bash
# Tạo snapshot trên obs01
curl -s http://10.171.131.31:8482/snapshot/create
# Returns: {"status":"ok","snapshotName":"SNAPSHOT_NAME"}

# List snapshots
curl -s http://10.171.131.31:8482/snapshot/list

# Xóa snapshot cũ
curl -s "http://10.171.131.31:8482/snapshot/delete?snapshot=SNAPSHOT_NAME"
```

### 8.4 Điều chỉnh retention

```bash
# Sửa trong Ansible
vim /opt/monitoring-ansible/inventory/group_vars/all/main.yml
# vm_retention_period: "24"  # 24 tháng

# Redeploy
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --tags vmstorage
```

---

## 9. Xử Lý Sự Cố

### 9.1 VIP không hoạt động (không ping được 10.171.131.30)

```bash
# Kiểm tra keepalived
for node in 10.171.131.31 10.171.131.32 10.171.131.33; do
  echo "=== $node ==="
  ssh root@$node "systemctl status keepalived --no-pager | head -10"
  ssh root@$node "ip addr show ens3 | grep 10.171.131.30 && echo 'HAS VIP' || echo 'no VIP'"
done

# Restart keepalived
ssh root@10.171.131.31 "systemctl restart keepalived"

# Xem logs keepalived
ssh root@10.171.131.31 "journalctl -u keepalived -n 30"
```

### 9.2 Container bị crash loop (Restarting)

```bash
# 1. Xem logs để tìm nguyên nhân
ssh root@NODE "docker logs CONTAINER_NAME --tail 50 2>&1"

# 2. Kiểm tra disk
ssh root@NODE "df -h"

# 3. Kiểm tra permission
ssh root@NODE "ls -la /data/CONTAINER_DIR"

# 4. Fix permission nếu cần
ssh root@NODE "chmod -R 777 /data/CONTAINER_DIR"

# 5. Restart
ssh root@NODE "cd /opt/monitoring/CONTAINER && docker compose restart"
```

### 9.3 HAProxy backend DOWN

```bash
# Xem backend nào down
curl -s -u admin:HAProxy@2024! "http://10.171.131.30:8404/stats?csv" \
  | awk -F, '$18=="DOWN" {print $1,$2,$18}'

# Kiểm tra service trên node đó
ssh root@NODE_IP "docker ps | grep SERVICE_NAME"

# Restart service
ssh root@NODE_IP "cd /opt/monitoring/SERVICE_NAME && docker compose restart"

# HAProxy tự động detect UP sau khi service recover
```

### 9.4 vmstorage không nhận data

```bash
# Kiểm tra vminsert có connect được vmstorage không
ssh root@10.171.131.31 "docker logs vminsert --tail 30 2>&1 | grep -i error"

# Kiểm tra ports
for port in 8400 8401 8482; do
  for node in 10.171.131.31 10.171.131.32 10.171.131.33; do
    nc -zv $node $port 2>&1 | grep -E "succeeded|failed"
  done
done
```

### 9.5 Disk đầy

```bash
# Kiểm tra
df -h
du -sh /data/* | sort -rh | head -10

# Xóa Docker images không dùng
docker image prune -af

# Xóa Docker logs cũ
find /var/lib/docker/containers -name "*.log" -size +100M -exec truncate -s 0 {} \;

# Giảm retention VictoriaMetrics (nếu cần)
# Sửa vm_retention_period trong main.yml rồi deploy
```

### 9.6 PostgreSQL không kết nối được

```bash
# Kiểm tra container
ssh root@10.171.131.31 "docker logs postgresql --tail 30 2>&1"

# Test connection
ssh root@10.171.131.31 "docker exec postgresql psql -U postgres -c '\l'"

# Nếu permission denied trên /data/postgres
ssh root@10.171.131.31 "chown -R 999:999 /data/postgres && docker compose restart postgresql"
```

---

## 10. Runbook

### 10.1 Node fail hoàn toàn (1 trong 3 nodes down)

```
1. VIP tự động chuyển sang node BACKUP (Keepalived ~3s)
2. HAProxy tự động route ra khỏi node down
3. vmstorage cluster vẫn hoạt động (replication factor 2)
4. Không cần can thiệp ngay

Khi recover node:
1. Khởi động lại node
2. SSH vào kiểm tra services: docker ps
3. Nếu containers không tự start: cd /opt/monitoring/SERVICE && docker compose up -d
4. Hoặc redeploy bằng Ansible: ansible-playbook ... --limit obsXX
```

### 10.2 Mất dữ liệu vmstorage (1 node)

```
1. Dừng vmstorage trên node bị mất data
2. Restore từ S3 backup gần nhất:
   - Backup hàng ngày lúc 02:00
   - Tối đa mất ~24h data

Lệnh restore:
ssh root@NODE "
  cd /opt/monitoring/vmstorage && docker compose stop
  docker run --rm \
    -v /data/vmstorage:/vmstorage-data \
    victoriametrics/vmrestore:v1.102.0-cluster \
    -src=s3://metrics/NODE_NAME/LATEST_BACKUP/ \
    -storageDataPath=/vmstorage-data \
    -customS3Endpoint=https://s3hn.smartcloud.vn \
    -s3.accessKeyID=GMSVFIKPIKJA7AUT27NW \
    -s3.secretAccessKey=Ihwe8UJSD7dNgtYx93ra8QbVJn6kOCiknG5XrOQ4
  docker compose up -d
"
```

### 10.3 Maintenance window (update OS)

```
1. Đảm bảo VIP đang ở obs02 hoặc obs03 trước
2. Dừng Keepalived trên node cần maintenance:
   systemctl stop keepalived
3. Thực hiện maintenance
4. Start lại: systemctl start keepalived
5. Verify VIP về đúng node
```

### 10.4 Redeploy toàn bộ từ đầu

```bash
# Bước 1: Cleanup
for node in 10.171.131.31 10.171.131.32 10.171.131.33; do
  ssh root@$node "docker ps -aq | xargs -r docker rm -f; rm -rf /data/*; docker system prune -f"
done

# Bước 2: Deploy
cd /opt/monitoring-ansible
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml

# Bước 3: Verify
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --tags verify
```

---

## Phụ Lục: Lệnh Hàng Ngày

```bash
# === QUICK HEALTH CHECK ===
# 1. VIP
ping -c 1 10.171.131.30

# 2. All containers
for n in 31 32 33; do
  echo "=== obs0${n##*3} ==="
  ssh root@10.171.131.$n "docker ps --format '{{.Names}}: {{.Status}}'"
done

# 3. Endpoints
curl -s http://10.171.131.30:8481/health && echo " VM OK" || echo " VM FAIL"
curl -s http://10.171.131.30:13000/api/health | python3 -c "import sys,json; d=json.load(sys.stdin); print(' Grafana', d.get('database'))"
curl -s http://10.171.131.30:9093/-/healthy && echo " AM OK" || echo " AM FAIL"
curl -s http://10.171.131.30:3100/ready && echo " Loki OK" || echo " Loki FAIL"

# 4. S3 backup timer
ssh root@10.171.131.31 "systemctl list-timers | grep vmbackup"

# 5. Disk
for n in 10.171.131.31 10.171.131.32 10.171.131.33; do
  echo "$n:"; ssh root@$n "df -h / | tail -1"
done
```

---

*Tài liệu vận hành v5 — 2026-03-30*
