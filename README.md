# ansible-observability

Bộ Ansible tự động triển khai và vận hành hệ thống giám sát HA.

## Stack
- VictoriaMetrics Cluster
- Grafana HA
- HAProxy + Keepalived
- Alertmanager
- Loki + Promtail
- Random Ping Monitoring (Blackbox Exporter)

## Yêu cầu
- Ansible 2.12+
- Ubuntu 22.04 LTS
- Tối thiểu 3 nodes (4 vCPU, 8GB RAM, 200GB SSD)

## Deploy
```bash
./run.sh deploy
```

## Tài liệu
Xem [README chi tiết](docs/README.md)
