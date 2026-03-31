# Hướng Dẫn Sử Dụng Gitea - Quản Lý Cấu Hình Giám Sát Tập Trung

> **Phiên bản:** 1.0 | **Cập nhật:** 2026-03-30  
> **Stack:** VictoriaMetrics + Grafana + Loki + Alertmanager + HAProxy/Keepalived  
> **Gitea version:** 1.22.3

---

## Mục Lục

1. [Giới thiệu](#1-giới-thiệu)
2. [Thông tin truy cập](#2-thông-tin-truy-cập)
3. [Cấu trúc Repository đề xuất](#3-cấu-trúc-repository-đề-xuất)
4. [Thiết lập ban đầu](#4-thiết-lập-ban-đầu)
5. [Quy trình làm việc GitOps](#5-quy-trình-làm-việc-gitops)
6. [Tích hợp với Ansible](#6-tích-hợp-với-ansible)
7. [Quản lý Grafana Dashboards qua Git](#7-quản-lý-grafana-dashboards-qua-git)
8. [Quản lý Alert Rules qua Git](#8-quản-lý-alert-rules-qua-git)
9. [Quản lý Secrets an toàn](#9-quản-lý-secrets-an-toàn)
10. [Backup và Recovery](#10-backup-và-recovery)
11. [Best Practices](#11-best-practices)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Giới Thiệu

### Gitea là gì?

Gitea là nền tảng Git tự host (self-hosted), nhẹ và nhanh — tương tự GitHub/GitLab nhưng chạy hoàn toàn trên hạ tầng nội bộ. Trong hệ thống giám sát này, Gitea đóng vai trò **Single Source of Truth** cho toàn bộ cấu hình.

### Tại sao dùng GitOps cho monitoring?

| Vấn đề truyền thống | Giải pháp GitOps |
|---|---|
| Sửa config trực tiếp trên server → không ai biết | Mọi thay đổi qua Git commit → có lịch sử |
| Config giữa 3 nodes không đồng bộ | Ansible deploy từ 1 source → đồng bộ |
| Không rollback được khi lỗi | `git revert` → về version cũ ngay |
| Không biết ai đổi gì lúc nào | Git log → audit trail đầy đủ |

### Kiến trúc GitOps

```
Developer
    │
    ▼
┌─────────────┐    push     ┌──────────────────────┐
│  Local Repo │ ──────────► │  Gitea (obs01:3001)  │
└─────────────┘             │  incosys / main       │
                            └──────────┬───────────┘
                                       │ webhook / manual
                                       ▼
                            ┌──────────────────────┐
                            │   Ansible Playbook   │
                            │   site.yml           │
                            └──────────┬───────────┘
                                       │ deploy
                         ┌─────────────┼─────────────┐
                         ▼             ▼             ▼
                      obs01         obs02         obs03
                  10.171.131.31  10.171.131.32  10.171.131.33
```

### Luồng thay đổi cấu hình

```
1. Tạo branch mới
2. Chỉnh sửa config (inventory, group_vars, templates)
3. Commit + Push lên Gitea
4. Tạo Pull Request → Review
5. Merge vào main
6. Ansible Runner tự động deploy (hoặc chạy thủ công)
7. Verify trên 3 nodes
```

---

## 2. Thông Tin Truy Cập

### URLs

| Dịch vụ | URL | Ghi chú |
|---|---|---|
| Gitea (qua VIP) | http://10.171.131.30:3001 | Khuyến nghị dùng |
| Gitea (obs01) | http://10.171.131.31:3001 | Trực tiếp |
| Gitea SSH (qua VIP) | ssh://10.171.131.30:2222 | Git SSH clone |

### Tài khoản

| | |
|---|---|
| **Username** | `incosys` |
| **Password** | `Gitea@2024!` |
| **Email** | `admin@monitoring.local` |
| **Role** | Administrator |

### Thiết lập SSH Key (khuyến nghị)

Dùng SSH key thay password để clone/push an toàn hơn:

```bash
# Tạo SSH key (nếu chưa có)
ssh-keygen -t ed25519 -C "incosys@monitoring" -f ~/.ssh/gitea_monitoring

# Copy public key
cat ~/.ssh/gitea_monitoring.pub
```

Sau đó vào Gitea → **Settings** → **SSH / GPG Keys** → **Add Key** → paste nội dung public key.

Cấu hình `~/.ssh/config`:

```
Host gitea-monitoring
    HostName 10.171.131.30
    Port 2222
    User git
    IdentityFile ~/.ssh/gitea_monitoring
```

Test kết nối:

```bash
ssh -T gitea-monitoring
# Expected: Hi incosys! You've successfully authenticated...
```

---

## 3. Cấu Trúc Repository Đề Xuất

### Repository chính: `monitoring-ansible`

```
monitoring-ansible/
├── .gitea/
│   └── workflows/
│       ├── deploy.yml          ← CI/CD auto-deploy khi merge
│       └── lint.yml            ← Kiểm tra syntax Ansible
├── .gitignore
├── ansible.cfg
├── README.md
├── GITEA-GUIDE.md
├── CHANGELOG.md
│
├── inventory/
│   ├── monitoring.yml          ← Hosts, groups
│   └── group_vars/
│       ├── all.yml             ← Variables chung
│       └── all/
│           ├── main.yml        ← Ports, versions, paths
│           └── vault.yml       ← Secrets (encrypted)
│
├── playbooks/
│   ├── site.yml                ← Deploy toàn bộ
│   └── stacks/
│       ├── infra.yml           ← HAProxy, Keepalived
│       ├── monitoring.yml      ← VictoriaMetrics
│       ├── logging.yml         ← Loki, Promtail
│       └── grafana.yml         ← Grafana
│
├── roles/
│   ├── common/                 ← OS cơ bản, ufw
│   ├── docker/                 ← Cài Docker
│   ├── haproxy/                ← HAProxy config
│   ├── keepalived/             ← VIP management
│   ├── vmstorage/              ← VictoriaMetrics storage
│   ├── vminsert/               ← VictoriaMetrics insert
│   ├── vmselect/               ← VictoriaMetrics select
│   ├── vmagent/                ← Metrics scraping
│   ├── grafana/                ← Dashboard + datasources
│   │   └── templates/
│   │       └── provisioning/
│   │           └── datasources/
│   │               └── victoriametrics.yml.j2
│   ├── loki/                   ← Log aggregation
│   ├── alertmanager/           ← Alert routing
│   ├── postgresql/             ← Database cho Grafana/Gitea
│   ├── gitea/                  ← Self-hosted Git
│   ├── node_exporter/          ← Host metrics
│   ├── random_ping/            ← Blackbox monitoring
│   └── promtail/               ← Log shipping
│
├── dashboards/                 ← Grafana dashboard JSON
│   ├── node-exporter.json
│   ├── victoriametrics.json
│   ├── loki-logs.json
│   └── haproxy.json
│
└── alert-rules/                ← VictoriaMetrics alert rules
    ├── node.yml
    ├── services.yml
    └── alertmanager-config.yml
```

---

## 4. Thiết Lập Ban Đầu

### 4.1 Đăng nhập Gitea lần đầu

```
URL: http://10.171.131.30:3001
User: incosys
Pass: Gitea@2024!
```

### 4.2 Tạo Organization

1. Click **+** → **New Organization**
2. Organization name: `monitoring`
3. Visibility: **Private**
4. Click **Create Organization**

### 4.3 Tạo Repository

```bash
# Qua Web UI:
# Organization monitoring → Repositories → New Repository
# Name: monitoring-ansible
# Visibility: Private
# Initialize: YES (với README)
```

Hoặc tạo và push từ server hiện tại:

```bash
# Trên jump server 10.171.131.59
cd /opt/monitoring-ansible

# Init git nếu chưa có
git init
git add -A
git commit -m "feat: initial monitoring stack v4-final"

# Add remote Gitea
git remote add origin http://incosys:Gitea@2024!@10.171.131.31:3001/monitoring/monitoring-ansible.git

# Push
git push -u origin main
```

### 4.4 Branch Strategy

```
main          ← Production, chỉ merge qua PR
  │
  ├── develop ← Integration branch
  │     │
  │     ├── feature/add-new-alert-rules
  │     ├── fix/grafana-port-conflict
  │     └── feat/s3-backup-vmstorage
```

Bảo vệ branch `main`:
- Settings → Branches → Protected Branches
- Thêm rule cho `main`: require PR + review trước khi merge

---

## 5. Quy Trình Làm Việc GitOps

### 5.1 Clone repository

```bash
# Dùng HTTPS
git clone http://10.171.131.30:3001/monitoring/monitoring-ansible.git

# Dùng SSH (sau khi setup SSH key)
git clone ssh://git@10.171.131.30:2222/monitoring/monitoring-ansible.git
```

### 5.2 Thay đổi cấu hình (ví dụ: đổi retention period)

```bash
cd monitoring-ansible

# Tạo branch mới
git checkout -b fix/vmstorage-retention

# Chỉnh sửa
vim inventory/group_vars/all/main.yml
# Đổi: vmstorage_retention: 12  →  vmstorage_retention: 24

# Commit
git add inventory/group_vars/all/main.yml
git commit -m "fix: increase vmstorage retention from 12m to 24m"

# Push
git push origin fix/vmstorage-retention
```

### 5.3 Tạo Pull Request

1. Vào Gitea → Repository → **New Pull Request**
2. Base: `main` ← Compare: `fix/vmstorage-retention`
3. Điền mô tả thay đổi
4. Assign reviewer
5. Submit

### 5.4 Review và Merge

Reviewer kiểm tra:
- [ ] Thay đổi có đúng không?
- [ ] Không commit secret/password plain text?
- [ ] Syntax YAML hợp lệ?
- [ ] Đã test trên môi trường dev?

### 5.5 Deploy sau merge

```bash
# Trên jump server hoặc trigger tự động
cd /opt/monitoring-ansible
git pull origin main
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --tags vmstorage
```

---

## 6. Tích Hợp Với Ansible

### 6.1 Workflow CI/CD tự động

Tạo file `.gitea/workflows/deploy.yml`:

```yaml
name: Deploy Monitoring Stack

on:
  push:
    branches:
      - main

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v3

      - name: Install Ansible
        run: |
          pip install ansible ansible-lint

      - name: Lint Ansible
        run: |
          ansible-lint playbooks/site.yml || true

      - name: Deploy to monitoring nodes
        run: |
          # Setup SSH key từ secrets
          mkdir -p ~/.ssh
          echo "${{ secrets.ANSIBLE_SSH_KEY }}" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa

          ansible-playbook \
            -i inventory/monitoring.yml \
            playbooks/site.yml \
            --private-key ~/.ssh/id_rsa \
            -e "ansible_ssh_pass=${{ secrets.SSH_PASSWORD }}"
        env:
          ANSIBLE_HOST_KEY_CHECKING: "false"
```

### 6.2 Workflow lint (kiểm tra syntax)

Tạo file `.gitea/workflows/lint.yml`:

```yaml
name: Lint & Validate

on:
  pull_request:
    branches:
      - main
      - develop

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install tools
        run: pip install ansible ansible-lint yamllint

      - name: YAML lint
        run: yamllint inventory/ roles/ playbooks/

      - name: Ansible lint
        run: ansible-lint playbooks/site.yml

      - name: Syntax check
        run: |
          ansible-playbook \
            -i inventory/monitoring.yml \
            playbooks/site.yml \
            --syntax-check
```

### 6.3 Webhook thủ công

Nếu không dùng Gitea Actions, setup webhook:

```
Gitea → Repository → Settings → Webhooks → Add Webhook
URL: http://10.171.131.31:9091/api/v1/run  (Ansible Runner)
Events: Push, Pull Request merged
Secret: WebhookSecret@2024!
```

---

## 7. Quản Lý Grafana Dashboards Qua Git

### 7.1 Export dashboard từ Grafana

```bash
# Export qua API
curl -s http://admin:Admin@2024!@10.171.131.30:13000/api/dashboards/uid/YOUR_DASHBOARD_UID \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d['dashboard'], indent=2))" \
  > dashboards/node-exporter.json
```

Hoặc qua UI: Dashboard → Share → Export → Save to file

### 7.2 Cấu trúc provisioning trong Ansible

```yaml
# roles/grafana/templates/provisioning/dashboards/default.yml.j2
apiVersion: 1
providers:
  - name: 'Monitoring'
    orgId: 1
    folder: 'Monitoring'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
```

### 7.3 Auto-provision khi deploy

```yaml
# roles/grafana/tasks/main.yml (thêm task)
- name: Copy dashboards JSON
  copy:
    src: "{{ playbook_dir }}/dashboards/{{ item }}"
    dest: "/opt/monitoring/grafana/provisioning/dashboards/{{ item }}"
    mode: '0644'
  with_fileglob:
    - "{{ playbook_dir }}/dashboards/*.json"
  notify: restart grafana
```

### 7.4 Quy trình cập nhật dashboard

```bash
# 1. Sửa dashboard trong Grafana UI
# 2. Export JSON
curl -s http://admin:Admin@2024!@10.171.131.31:13000/api/dashboards/uid/UID \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d['dashboard'],indent=2))" \
  > dashboards/my-dashboard.json

# 3. Commit vào Git
git add dashboards/my-dashboard.json
git commit -m "feat: update node-exporter dashboard - add disk IO panel"
git push origin main

# 4. Deploy
ansible-playbook -i inventory/monitoring.yml playbooks/stacks/grafana.yml
```

---

## 8. Quản Lý Alert Rules Qua Git

### 8.1 Cấu trúc alert rules

```yaml
# alert-rules/node.yml
groups:
  - name: node-alerts
    interval: 1m
    rules:
      # CPU cao
      - alert: HighCPUUsage
        expr: |
          100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "CPU cao trên {{ $labels.instance }}"
          description: "CPU usage: {{ $value | printf \"%.1f\" }}%"

      # RAM thấp
      - alert: LowMemory
        expr: |
          (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < 10
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "RAM thấp trên {{ $labels.instance }}"
          description: "Còn {{ $value | printf \"%.1f\" }}% RAM"

      # Disk đầy
      - alert: DiskAlmostFull
        expr: |
          (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 < 15
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Disk gần đầy trên {{ $labels.instance }}"
          description: "Còn {{ $value | printf \"%.1f\" }}% disk"

      # Node down
      - alert: NodeDown
        expr: up{job="node-exporter"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Node {{ $labels.instance }} down"
```

### 8.2 Alert rules cho VictoriaMetrics cluster

```yaml
# alert-rules/victoriametrics.yml
groups:
  - name: victoriametrics
    rules:
      - alert: VmstorageDown
        expr: up{job="vmstorage"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "vmstorage down trên {{ $labels.instance }}"

      - alert: VmagentDown
        expr: up{job="vmagent"} == 0
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "vmagent không scrape được trên {{ $labels.instance }}"

      - alert: VmstorageHighDiskUsage
        expr: |
          vm_data_size_bytes{type="storage/small"} > 50 * 1024 * 1024 * 1024
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "vmstorage disk cao: {{ $value | humanize }}B"
```

### 8.3 Alertmanager config

```yaml
# alertmanager/config.yml
global:
  resolve_timeout: 5m
  smtp_require_tls: false

route:
  group_by: ['alertname', 'instance']
  group_wait: 10s
  group_interval: 10m
  repeat_interval: 24h
  receiver: 'telegram-alerts'
  routes:
    - match:
        severity: critical
      receiver: 'telegram-critical'
      repeat_interval: 1h

receivers:
  - name: 'telegram-alerts'
    telegram_configs:
      - bot_token: '7805061150:AAHPdlpdw7LOjzCXPXps6OCHC87kbICBrRc'
        chat_id: -1002622356108
        message: |
          🔔 *{{ .GroupLabels.alertname }}*
          {{ range .Alerts }}
          • {{ .Annotations.summary }}
          {{ end }}

  - name: 'telegram-critical'
    telegram_configs:
      - bot_token: '7805061150:AAHPdlpdw7LOjzCXPXps6OCHC87kbICBrRc'
        chat_id: -1002622356108
        message: |
          🚨 *CRITICAL: {{ .GroupLabels.alertname }}*
          {{ range .Alerts }}
          • {{ .Annotations.summary }}
          • {{ .Annotations.description }}
          {{ end }}
```

### 8.4 Auto-reload rules sau khi thay đổi

```bash
# Reload Alertmanager (không cần restart)
curl -X POST http://10.171.131.30:9093/-/reload

# Reload vmalert (nếu dùng)
curl -X POST http://10.171.131.31:8880/-/reload
```

---

## 9. Quản Lý Secrets An Toàn

### 9.1 File .gitignore

```gitignore
# Ansible Vault (nếu dùng file riêng)
*vault-password*
*.vault
.vault_pass

# Logs
*.log

# SSH keys
*.pem
id_rsa
id_ed25519

# Temp files
*.tmp
*.bak
```

### 9.2 Encrypt secrets với Ansible Vault

```bash
# Encrypt toàn bộ vault.yml
ansible-vault encrypt inventory/group_vars/all/vault.yml

# Xem nội dung đã encrypt
ansible-vault view inventory/group_vars/all/vault.yml

# Decrypt để chỉnh sửa
ansible-vault edit inventory/group_vars/all/vault.yml

# Chạy playbook với vault password
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --ask-vault-pass
# Hoặc dùng file password
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --vault-password-file ~/.vault_pass
```

### 9.3 Không bao giờ commit plain text password

```bash
# ❌ SAI - commit password trực tiếp
vault_grafana_admin_password: "Admin@2024!"

# ✅ ĐÚNG - encrypt vault.yml trước khi commit
$ANSIBLE_VAULT;1.1;AES256
66386439653762...
```

---

## 10. Backup Và Recovery

### 10.1 Backup Gitea

```bash
# Backup Gitea data (chạy trên obs01)
docker exec gitea gitea admin user list  # verify
docker stop gitea

# Backup toàn bộ data
tar czf /backup/gitea-backup-$(date +%Y%m%d).tar.gz /data/gitea/

# Hoặc dùng Gitea built-in backup
docker exec gitea gitea dump -c /etc/gitea/app.ini

docker start gitea
```

### 10.2 Rollback config về version cũ

```bash
# Xem lịch sử commit
git log --oneline -20

# Rollback về commit cụ thể
git revert abc1234
git push origin main

# Hoặc reset cứng (cẩn thận!)
git reset --hard abc1234
git push --force origin main  # Chỉ dùng khi thật sự cần

# Deploy version cũ
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml
```

### 10.3 Restore Gitea từ backup

```bash
# Stop Gitea
docker stop gitea

# Restore data
rm -rf /data/gitea
tar xzf /backup/gitea-backup-20260330.tar.gz -C /

# Start lại
docker start gitea
```

---

## 11. Best Practices

### 11.1 Naming conventions

```bash
# Branch names
feature/add-s3-backup-vmstorage
fix/grafana-port-13000
chore/update-victoriametrics-v1.103
hotfix/alert-rule-syntax-error

# Commit messages (Conventional Commits)
feat: add S3 backup for vmstorage
fix: correct grafana_port from 3000 to 13000
chore: update VictoriaMetrics to v1.103.0
docs: add Gitea integration guide
refactor: split site.yml into stacks
```

### 11.2 Commit message format

```
<type>: <mô tả ngắn>

[body - mô tả chi tiết nếu cần]

[footer - breaking changes, issue refs]
```

Types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `hotfix`

### 11.3 Review checklist

Trước khi merge PR:
- [ ] Không có plain text password/secret
- [ ] Syntax YAML hợp lệ (`yamllint`)
- [ ] Ansible syntax check pass (`--syntax-check`)
- [ ] Thay đổi đã được test trên 1 node trước
- [ ] README/CHANGELOG được cập nhật nếu cần
- [ ] Ports mới đã được thêm vào ufw rules

### 11.4 Quy tắc vàng

```
🚫 KHÔNG bao giờ sửa config trực tiếp trên server
✅ Luôn sửa qua Git → deploy bằng Ansible
```

Lý do:
- Config trực tiếp sẽ bị override lần deploy tiếp theo
- Không có audit trail
- Mất đồng bộ giữa Git và server thực tế

---

## 12. Troubleshooting

### 12.1 Không clone được qua SSH

```bash
# Kiểm tra SSH port
nc -zv 10.171.131.30 2222

# Test SSH
ssh -v -p 2222 git@10.171.131.30

# Kiểm tra SSH key đã add chưa
# Gitea → Settings → SSH Keys
```

### 12.2 Push bị từ chối

```bash
# Lỗi: remote rejected (protected branch)
# → Tạo PR thay vì push trực tiếp vào main

# Lỗi: Authentication failed
git remote set-url origin http://incosys:Gitea@2024!@10.171.131.31:3001/monitoring/monitoring-ansible.git
```

### 12.3 Ansible deploy fail sau merge

```bash
# Xem lỗi chi tiết
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml -vvv

# Chỉ check syntax
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --syntax-check

# Dry run
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --check
```

### 12.4 Gitea container không start

```bash
# Xem logs
docker logs gitea --tail 50

# Kiểm tra PostgreSQL connection
docker exec gitea wget -qO- http://10.171.131.31:5432 || echo "DB unreachable"

# Restart
cd /opt/monitoring/gitea && docker compose restart
```

### 12.5 Webhook không trigger

```bash
# Kiểm tra webhook delivery log
# Gitea → Repository → Settings → Webhooks → [webhook] → Recent Deliveries

# Test thủ công
curl -X POST http://10.171.131.31:9091/api/v1/run \
  -H "X-Gitea-Event: push" \
  -H "X-Gitea-Signature: WebhookSecret@2024!" \
  -d '{"ref": "refs/heads/main"}'
```

### 12.6 Git conflict khi pull

```bash
# Stash changes
git stash

# Pull mới nhất
git pull origin main

# Apply lại changes
git stash pop

# Resolve conflicts nếu có
git mergetool
```

---

## Phụ Lục: Quick Reference

### URLs & Credentials

| Service | URL | User | Pass |
|---|---|---|---|
| Gitea | http://10.171.131.30:3001 | incosys | Gitea@2024! |
| Grafana | http://10.171.131.30:13000 | admin | Admin@2024! |
| HAProxy Stats | http://10.171.131.30:8404/stats | admin | HAProxy@2024! |
| Alertmanager | http://10.171.131.30:9093 | — | — |
| VMSelect | http://10.171.131.30:8481 | — | — |

### Ansible Quick Commands

```bash
# Deploy toàn bộ
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml

# Deploy 1 stack
ansible-playbook -i inventory/monitoring.yml playbooks/stacks/monitoring.yml

# Deploy 1 role
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --tags grafana

# Deploy 1 node
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --limit obs01

# Dry run
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --check

# Syntax check
ansible-playbook -i inventory/monitoring.yml playbooks/site.yml --syntax-check
```

### Git Quick Commands

```bash
# Tạo branch mới
git checkout -b feature/my-change

# Commit
git add -A && git commit -m "feat: my change"

# Push
git push origin feature/my-change

# Merge main vào branch hiện tại
git merge origin/main

# Rollback 1 commit
git revert HEAD
```

---

*Tài liệu này được tạo tự động từ cấu hình thực tế của hệ thống monitoring stack ngày 2026-03-30.*
