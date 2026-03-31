# 🚀 HA Monitoring System — Ansible Deployment

## Tổng quan

Bộ Ansible tự động triển khai và vận hành hệ thống giám sát HA hoàn toàn trên 3 node:

| Thành phần | Role | HA |
|---|---|---|
| VictoriaMetrics Cluster | Thu thập & lưu trữ metrics | ✅ replicationFactor=2 |
| Grafana | Dashboard & visualization | ✅ 3 instance + shared DB |
| HAProxy | Load balancer | ✅ 3 instance |
| Keepalived | VIP failover | ✅ VRRP <3s |
| Alertmanager | Cảnh báo | ✅ 2 instance gossip |
| vmagent | Scrape metrics | ✅ 2 instance active-active |
| PostgreSQL | Grafana backend | ✅ 1 + replica |
| Gitea | Git server | ℹ️ 1 instance |

---

## Yêu cầu

### Trên máy Ansible Controller (chạy playbook)
```bash
# Cài Ansible
pip3 install ansible
ansible --version   # Kiểm tra

# Cài collections cần thiết
ansible-galaxy collection install community.docker
ansible-galaxy collection install community.general
```

### Trên các node server
- Ubuntu 22.04 LTS hoặc RHEL 8+
- Tối thiểu: 4 vCPU, 8GB RAM, 200GB SSD
- SSH access từ controller (key-based)
- Python 3.x đã cài

---

## Cấu trúc thư mục

```
monitoring-ansible/
├── run.sh                          ← ENTRYPOINT (chạy lệnh từ đây)
├── inventory/
│   ├── hosts.yml                   ← Danh sách servers (CHỈNH SỬA Ở ĐÂY)
│   └── group_vars/
│       ├── all.yml                 ← Cấu hình toàn cục (version, ports...)
│       └── vault.yml               ← Secrets (encrypt trước khi commit)
├── playbooks/
│   ├── 01-common.yml               ← Cấu hình OS
│   ├── 02-docker.yml               ← Cài Docker
│   ├── 03-keepalived.yml           ← VIP failover
│   ├── 04-haproxy.yml              ← Load balancer
│   ├── 05-node-exporter.yml        ← Metric exporter
│   ├── 06-victoriametrics.yml      ← VM Cluster
│   ├── 07-postgresql.yml           ← DB backend
│   ├── 08-grafana.yml              ← Dashboard
│   ├── 09-alertmanager.yml         ← Alerting
│   ├── 10-vmagent.yml              ← Scrape agent
│   ├── 11-gitea.yml                ← Git server
│   ├── 12-verify.yml               ← Health check
│   ├── reconfig.yml                ← Cập nhật config
│   ├── upgrade.yml                 ← Nâng cấp version
│   ├── add-node.yml                ← Thêm server mới
│   ├── destroy.yml                 ← Gỡ bỏ hệ thống
│   └── verify.yml                  ← Kiểm tra sức khỏe
├── roles/                          ← Ansible roles
│   ├── common/
│   ├── docker/
│   ├── keepalived/
│   ├── haproxy/
│   ├── node_exporter/
│   ├── victoriametrics/
│   ├── grafana/
│   ├── alertmanager/
│   └── vmagent/
├── templates/                      ← Jinja2 templates dùng chung
│   ├── vmagent-scrape.yml.j2       ← Auto-generate từ inventory
│   └── haproxy.cfg.j2
├── files/
│   └── alert-rules/                ← Alert rules YAML
└── logs/                           ← Log output (auto-created)
```

---

## Hướng dẫn triển khai

### Bước 1: Clone và cấu hình

```bash
git clone http://gitea.vnpt.local/admin/monitoring-ansible.git
cd monitoring-ansible
chmod +x run.sh
```

### Bước 2: Cập nhật inventory

Mở `inventory/hosts.yml` và điền IP thực tế:

```yaml
monitoring:
  hosts:
    node01:
      ansible_host: 192.168.1.101   # ← IP thực
    node02:
      ansible_host: 192.168.1.102
    node03:
      ansible_host: 192.168.1.103
```

Thêm các server cần monitor:
```yaml
compute:
  hosts:
    compute01:
      ansible_host: 192.168.1.201
      site: HN4
      cluster: smartcloud2022
```

### Bước 3: Cấu hình biến

Mở `inventory/group_vars/all.yml` và chỉnh:
```yaml
vip_address: "192.168.1.100"    # VIP thực tế
vip_interface: "ens3"           # Interface thực tế
```

### Bước 4: Cấu hình secrets

```bash
# Chỉnh thông tin Telegram trong vault.yml
vim inventory/group_vars/vault.yml

# Encrypt file secrets
ansible-vault encrypt inventory/group_vars/vault.yml
```

### Bước 5: Cấu hình SSH key

```bash
# Tạo user riêng cho Ansible (KHÔNG dùng root)
# Chạy trên mỗi node:
useradd -m -s /bin/bash ansible
echo "ansible ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ansible
chmod 440 /etc/sudoers.d/ansible

# Tạo SSH key nếu chưa có
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa

# Copy public key lên tất cả nodes (user ansible, không phải root)
ssh-copy-id ansible@192.168.1.101
ssh-copy-id ansible@192.168.1.102
ssh-copy-id ansible@192.168.1.103

# Test kết nối
ansible all -i inventory/hosts.yml -m ping
```

### Bước 6: Deploy!

```bash
# Dry-run trước (không thay đổi thực tế)
./run.sh deploy --check

# Deploy thật
./run.sh deploy
```

---

## Hướng dẫn vận hành

### Thêm server mới vào monitoring

```bash
# 1. Thêm vào inventory/hosts.yml
vim inventory/hosts.yml

# 2. Chạy add-node
./run.sh add-node
# → Nhập hostname khi được hỏi
# → Ansible tự cài node_exporter và update scrape config
```

### Cập nhật cấu hình

```bash
./run.sh reconfig
# → Chọn loại reconfig:
#   [1] Cập nhật targets
#   [2] Cập nhật alert rules
#   [3] Cập nhật HAProxy
#   [4] Cập nhật Grafana
#   [5] Cập nhật Alertmanager
#   [6] Reconfig toàn bộ
```

### Nâng cấp version

```bash
# 1. Cập nhật version trong group_vars/all.yml
vim inventory/group_vars/all.yml
# victoriametrics_version: "v1.100.0"

# 2. Chạy upgrade (rolling, không downtime)
./run.sh upgrade
```

### Kiểm tra sức khỏe

```bash
./run.sh verify
```

### Gỡ bỏ hệ thống

```bash
./run.sh destroy
# → Gõ 'DESTROY' để xác nhận
```

---

---

## Quản lý scrape targets (hàng trăm client)

> **Nguyên tắc:** `inventory/hosts.yml` chỉ dùng cho infrastructure nodes (monitoring, ceph, compute...).  
> Scrape targets (client cần monitor) quản lý riêng trong thư mục `targets/`.

### Cấu trúc thư mục targets/

```
targets/
├── node_exporter.yml   ← Tất cả server cài node_exporter
├── ceph.yml            ← Ceph exporters
├── openstack.yml       ← OpenStack exporters
├── vmware.yml          ← VMware vSphere
└── custom.yml          ← Exporter tùy chỉnh
```

### Cách thêm client mới

**Option A — Sửa file YAML trực tiếp** (thêm hàng loạt):
```yaml
# targets/node_exporter.yml
groups:
  - name: compute-hn4
    labels:
      role: compute
      site: HN4
    hosts:
      - { host: 10.1.2.50, labels: { cluster: smartcloud2022 } }
      - { host: 10.1.2.51, labels: { cluster: smartcloud2022 } }
      # Thêm hàng loạt ở đây...
```

**Option B — Dùng script manage-targets.sh** (thêm từng cái):
```bash
# Thêm 1 client
./manage-targets.sh add node_exporter 10.1.2.50 \
  --group compute-hn4 \
  --labels "site=HN4,cluster=smartcloud2022"

# Xóa 1 client
./manage-targets.sh remove node_exporter 10.1.2.50

# Xem danh sách
./manage-targets.sh list
./manage-targets.sh list node_exporter

# Đếm tổng
./manage-targets.sh count
```

### Apply sau khi sửa targets

```bash
# Chạy reconfig — vmagent tự reload (không restart)
./run.sh reconfig       # Chọn [1] Cập nhật targets
# hoặc
./manage-targets.sh apply
```

> **Lưu ý:** Thay đổi targets file không cần restart vmagent.  
> vmagent nhận SIGHUP → reload config trong vòng vài giây.

---

## Sau khi deploy xong

| Service | URL | Thông tin |
|---|---|---|
| Grafana | http://VIP:80 | admin / &lt;YOUR_STRONG_PASSWORD&gt; |
| HAProxy Stats | http://VIP:8404/stats | admin / &lt;YOUR_STRONG_PASSWORD&gt; |
| Alertmanager | http://VIP:9093 | - |
| Gitea | http://node01:3001 | - |
| vmselect API | http://VIP:8481/select/0/prometheus | - |

---

## Xử lý sự cố thường gặp

### Ansible không kết nối được node
```bash
# Kiểm tra SSH (dùng user ansible, không phải root)
ssh ansible@<node_ip> -i ~/.ssh/id_rsa

# Kiểm tra ping
ansible <node> -i inventory/hosts.yml -m ping -vvv
```

### VIP không chuyển sang BACKUP khi MASTER chết
```bash
# Kiểm tra keepalived log
ansible monitoring -i inventory/hosts.yml -m shell -a "journalctl -u keepalived -n 50"

# Kiểm tra VRRP multicast
ansible monitoring -i inventory/hosts.yml -m shell -a "ip maddr show"
```

### HAProxy backend down
```bash
# Xem HAProxy stats chi tiết
curl -u admin:<YOUR_STRONG_PASSWORD> http://VIP:8404/stats

# Kiểm tra HAProxy log
ansible monitoring -i inventory/hosts.yml -m shell -a "journalctl -u haproxy -n 50"
```

### vmagent không scrape được target
```bash
# Xem targets list
curl http://node01:8429/api/v1/targets | python3 -m json.tool

# Xem vmagent log
ansible monitoring -i inventory/hosts.yml -m shell -a "docker logs vmagent --tail 50"
```

---

## GitOps workflow

```bash
# Thay đổi cấu hình → commit → push → Gitea webhook → Ansible tự chạy
git add inventory/hosts.yml
git commit -m "Add compute05-hn4 to monitoring"
git push origin main
# → Ansible tự động: cài node_exporter, update targets, báo Telegram ✅
```

---

*Tài liệu này được duy trì cùng với codebase. Mọi thay đổi về kiến trúc cần cập nhật README.*
