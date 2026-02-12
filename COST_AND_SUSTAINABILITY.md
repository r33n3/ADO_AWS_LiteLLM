# Cost Analysis & Environmental Impact

## Cost Summary

Estimated monthly operating costs for the LiteLLM proxy deployment in **us-east-1**.

| Category | Dev | Staging | Production |
|----------|-----|---------|------------|
| Compute (ECS Fargate) | $15 | $30 | $60 |
| Networking (ALB, NAT, Endpoints) | $77 | $77 | $80 |
| Database (RDS PostgreSQL) | $13 | $26 | $52 |
| Security (KMS, Secrets Manager) | $3 | $3 | $3 |
| Monitoring (CloudWatch) | $4 | $6 | $15 |
| WAF | — | — | $10 |
| **Total** | **~$112** | **~$142** | **~$220** |

> Costs assume 24/7 operation. Dev costs can be reduced to **~$80/month** by disabling NAT Gateway.

---

## Detailed Cost Breakdown

### Compute

**ECS Fargate**

| Parameter | Dev | Staging | Production |
|-----------|-----|---------|------------|
| Tasks | 1 | 2 | 2-4 |
| vCPU per task | 0.5 | 0.5 | 1.0 |
| Memory per task | 1 GB | 1 GB | 2 GB |
| Capacity provider | Fargate Spot | Fargate Spot | Fargate On-Demand |
| Price per vCPU/hr | $0.01334 (Spot) | $0.01334 (Spot) | $0.04048 (On-Demand) |
| Price per GB/hr | $0.00146 (Spot) | $0.00146 (Spot) | $0.004445 (On-Demand) |
| **Monthly** | **~$8** | **~$16** | **~$44** |

- Fargate Spot saves ~70% over On-Demand but tasks can be interrupted
- Auto-scaling (CPU 70%, Memory 80%) may temporarily add tasks during load

**Lambda (Secret Rotation)**

| Function | Invocations/month | Duration | Memory | Monthly Cost |
|----------|-------------------|----------|--------|-------------|
| Master Key Rotation | ~1 | <1s | 128 MB | <$0.01 |
| DB Password Rotation | ~1 | <5s | 256 MB | <$0.01 |
| DB Secret Update | ~1 (on deploy) | <5s | 128 MB | <$0.01 |
| **Total** | | | | **<$0.01** |

---

### Networking

**Application Load Balancer**

| Component | Rate | Monthly Cost |
|-----------|------|-------------|
| ALB hours | $0.0225/hr x 730 hrs | $16.43 |
| LCU usage (low traffic) | ~$0.50 | $0.50 |
| **Total** | | **~$17** |

**NAT Gateway (Optional)**

| Component | Rate | Monthly Cost |
|-----------|------|-------------|
| NAT Gateway hours | $0.045/hr x 730 hrs | $32.85 |
| Data processing | $0.045/GB x ~2 GB | $0.09 |
| **Total** | | **~$33** |

> Set `EnableNatGateway: false` to eliminate this cost. ECS tasks use VPC Endpoints for AWS service access instead.

**VPC Endpoints (Interface)**

| Endpoint | Hourly Rate | Monthly Cost |
|----------|-------------|-------------|
| ECR API | $0.01/hr/AZ | ~$7.30 |
| ECR DKR | $0.01/hr/AZ | ~$7.30 |
| Secrets Manager | $0.01/hr/AZ | ~$7.30 |
| CloudWatch Logs | $0.01/hr/AZ | ~$7.30 |
| S3 (Gateway) | Free | $0.00 |
| **Total** | | **~$29** |

> Deployed in 1 AZ by default. Multi-AZ doubles interface endpoint costs.

**Data Transfer**

| Type | Rate | Estimated Monthly |
|------|------|-------------------|
| Internet ingress | Free | $0 |
| Internet egress (first 100 GB) | $0.09/GB | ~$1 |
| Inter-AZ transfer | $0.01/GB | ~$0.50 |
| VPC Endpoint data | $0.01/GB | ~$0.20 |
| **Total** | | **~$2** |

---

### Database

**RDS PostgreSQL**

| Parameter | Dev | Staging | Production |
|-----------|-----|---------|------------|
| Instance class | db.t3.micro | db.t3.small | db.t3.medium |
| vCPU | 2 | 2 | 2 |
| RAM | 1 GB | 2 GB | 4 GB |
| Multi-AZ | No | No | Yes (2x cost) |
| On-Demand price/hr | $0.018 | $0.036 | $0.072 |
| Instance monthly | $13.14 | $26.28 | $52.56 |
| Storage (20 GB gp3) | $2.30 | $2.30 | $2.30 |
| Backup storage | Free (up to DB size) | Free | Free |
| **Total** | **~$15** | **~$29** | **~$55** |

- Storage auto-scales to 100 GB max ($11.50/month at full capacity)
- Automated backups: 7-day retention (included)
- Production Multi-AZ provides automatic failover

---

### Security & Secrets

| Resource | Quantity | Unit Price | Monthly Cost |
|----------|----------|------------|-------------|
| KMS customer key | 1 | $1.00/month | $1.00 |
| KMS API calls | ~1,000 | $0.03/10K requests | $0.01 |
| Secrets Manager secrets | 4 | $0.40/secret/month | $1.60 |
| Secrets Manager API calls | ~5,000 | $0.05/10K requests | $0.03 |
| **Total** | | | **~$3** |

---

### Monitoring

| Resource | Dev | Staging | Production |
|----------|-----|---------|------------|
| CloudWatch Logs ingestion (~5 GB) | $2.50 | $5.00 | $10.00 |
| CloudWatch Logs storage | $0.15 | $0.15 | $0.50 |
| CloudWatch Alarms (7 alarms) | $0.70 | $0.70 | $0.70 |
| Container Insights | — | — | ~$3.50 |
| **Total** | **~$4** | **~$6** | **~$15** |

- Log retention: 14 days (dev), 90 days (prod)
- 7 alarms: RDS CPU, RDS Storage, RDS Connections, ECS CPU, ECS Memory, Unhealthy Hosts, 5xx Errors

---

## Cost Optimization

| Action | Savings | Impact |
|--------|---------|--------|
| Disable NAT Gateway | $33/month | None if VPC endpoints work for all traffic |
| Use Fargate Spot (dev/staging) | ~70% on compute | Tasks may be interrupted (auto-replaced) |
| Scale to 0 tasks off-hours | Up to 50% on compute | Service unavailable during downtime |
| Reduce log retention to 7 days | ~$1-3/month | Less debugging history |
| Use 1 AZ (dev only) | ~$15/month on endpoints | No redundancy |
| Reserved RDS instance (1-year) | ~30% on RDS | Upfront commitment |
| Use `db.t3.micro` for staging | $13/month savings | Less database capacity |
| Disable Container Insights (staging) | $3.50/month | Less observability |

**Minimum viable dev cost:** ~$80/month (NAT disabled, Fargate Spot, 1 AZ, minimal logging)

---

## Environmental Impact

### Energy Consumption

Cloud infrastructure consumes electricity for compute, storage, cooling, and networking. AWS data centers operate at a Power Usage Effectiveness (PUE) of approximately **1.2**, meaning for every 1 kWh of compute, an additional 0.2 kWh is used for cooling, lighting, and facility operations.

**Estimated Power Draw by Resource**

| Resource | Active Power (W) | PUE Overhead (W) | Total (W) | Monthly (kWh) |
|----------|-------------------|-------------------|-----------|----------------|
| ECS Fargate (0.5 vCPU, 1 GB) | 3.5 | 0.7 | 4.2 | 3.1 |
| RDS db.t3.micro | 8.0 | 1.6 | 9.6 | 7.0 |
| ALB (idle + low traffic) | 5.0 | 1.0 | 6.0 | 4.4 |
| NAT Gateway | 3.0 | 0.6 | 3.6 | 2.6 |
| VPC Endpoints (4x interface) | 2.0 | 0.4 | 2.4 | 1.8 |
| Lambda (rotation, negligible) | 0.01 | 0.002 | 0.012 | 0.01 |
| **Dev Total** | **21.5** | **4.3** | **25.8** | **18.9** |

| Environment | Monthly kWh | Annual kWh |
|-------------|-------------|------------|
| Dev (1 task, micro DB) | ~19 kWh | ~227 kWh |
| Production (2 tasks, medium DB, Multi-AZ) | ~45 kWh | ~540 kWh |

> Estimates based on published server power consumption data for comparable instance types. Actual consumption varies with utilization.

---

### Carbon Footprint

AWS us-east-1 (Northern Virginia) draws power from the PJM Interconnection grid. The grid carbon intensity is approximately **0.379 kg CO2e per kWh** (EPA eGRID 2023, RFCE subregion). AWS has committed to 100% renewable energy matching by 2025, which offsets some of this through renewable energy certificates (RECs).

**Monthly CO2 Emissions**

| Environment | Monthly kWh | Grid CO2e (kg) | With AWS Renewable Offset* |
|-------------|-------------|-----------------|---------------------------|
| Dev | 19 | 7.2 | ~3.6 |
| Production | 45 | 17.1 | ~8.5 |

*AWS purchases renewable energy to match 100% of consumption. The "offset" estimate assumes ~50% of power is directly matched to renewable sources during the hours consumed (location-based vs market-based accounting).

**Annualized Carbon Footprint**

| Environment | Annual CO2e (kg) | Equivalent To |
|-------------|------------------|---------------|
| Dev | 86 kg | Driving 215 miles in an average car |
| Production | 205 kg | Driving 512 miles in an average car |
| | | Or ~1 domestic US flight segment |

> For comparison: A single on-premises server running 24/7 typically produces 1,000-2,000 kg CO2e/year. Cloud deployment benefits from higher utilization rates and renewable energy procurement.

---

### Water Usage

Data centers use water for cooling, primarily through evaporative cooling systems. AWS reports working to reduce water consumption, but industry estimates provide useful baselines.

**Water Usage Effectiveness (WUE)**

AWS data centers in us-east-1 have an estimated WUE of approximately **1.8 liters per kWh** (based on industry reporting for Northern Virginia facilities). This accounts for direct evaporative cooling water.

| Environment | Monthly kWh | Water (Liters) | Water (Gallons) |
|-------------|-------------|----------------|-----------------|
| Dev | 19 | 34 L | 9 gal |
| Production | 45 | 81 L | 21 gal |

**Context:**
- Dev deployment: Equivalent to **~4 minutes** of a standard shower per month
- Production deployment: Equivalent to **~10 minutes** of a standard shower per month
- A single load of laundry uses ~50-75 liters of water

---

### LLM Inference Impact

This deployment proxies requests to LLM providers (AWS Bedrock, OpenAI, Anthropic). The inference workload is the largest variable environmental cost and scales directly with usage.

**Per-Request Energy Estimates**

| Model | Energy per 1K tokens (Wh) | CO2e per 1K tokens (g) | Water per 1K tokens (mL) |
|-------|---------------------------|------------------------|--------------------------|
| Claude Haiku 3.5 | ~0.05 | ~0.02 | ~0.09 |
| Claude Sonnet 4 | ~0.15 | ~0.06 | ~0.27 |
| Claude Opus 4 | ~0.40 | ~0.15 | ~0.72 |
| GPT-4 class | ~0.50 | ~0.19 | ~0.90 |

> Estimates derived from published research on LLM inference energy (Luccioni et al., 2023; IEA 2024). Actual values depend on hardware, batch size, and provider infrastructure.

**Scaling Scenarios**

| Monthly Volume | Avg Tokens/Request | Model | Added CO2e (kg) | Added Water (L) | Added Cost* |
|----------------|-------------------|-------|-----------------|-----------------|-------------|
| 10K requests | 2K tokens | Sonnet 4 | 0.12 | 0.54 | ~$30 |
| 100K requests | 2K tokens | Sonnet 4 | 1.2 | 5.4 | ~$300 |
| 1M requests | 2K tokens | Sonnet 4 | 12 | 54 | ~$3,000 |
| 100K requests | 2K tokens | Haiku 3.5 | 0.04 | 0.18 | ~$25 |

*LLM provider costs (Bedrock pricing) are additional to infrastructure costs.

**Key Insight:** At moderate volumes (100K+ requests/month), the LLM inference energy consumption exceeds the infrastructure energy consumption. Choosing smaller models (Haiku vs Opus) for appropriate tasks is the single largest lever for reducing both cost and environmental impact.

---

### Regional Carbon Comparison

Choosing a different AWS region can significantly affect carbon footprint:

| Region | Grid Carbon Intensity (kg CO2e/kWh) | Relative to us-east-1 |
|--------|--------------------------------------|-----------------------|
| us-west-2 (Oregon) | 0.078 | **80% lower** |
| eu-west-1 (Ireland) | 0.296 | 22% lower |
| us-east-1 (Virginia) | 0.379 | Baseline |
| ap-southeast-1 (Singapore) | 0.408 | 8% higher |
| ap-south-1 (Mumbai) | 0.708 | 87% higher |

> Source: Electricity Maps, EPA eGRID 2023. us-west-2 benefits from Pacific Northwest hydroelectric power.

---

## Sustainability Recommendations

### Infrastructure

| Recommendation | Impact | Effort |
|----------------|--------|--------|
| Deploy in us-west-2 (Oregon) | ~80% carbon reduction | Low (region parameter change) |
| Use Graviton (ARM) instances for RDS | ~20% less energy, ~20% cheaper | Low (change instance class to db.t4g.*) |
| Enable auto-scaling with scale-to-zero | Up to 50% energy savings off-peak | Medium (min capacity = 0) |
| Disable NAT Gateway, rely on VPC endpoints | ~14% less infrastructure power | Low (parameter change) |
| Use Fargate Spot for non-production | ~70% less cost, better utilization | Low (already default for dev) |
| Right-size instances quarterly | 10-30% savings | Low (review CloudWatch metrics) |

### LLM Usage

| Recommendation | Impact | Effort |
|----------------|--------|--------|
| Route simple queries to smaller models (Haiku) | 80-90% less energy per request | Medium (LiteLLM router config) |
| Implement response caching | Eliminates redundant inference | Medium (Redis/in-memory cache) |
| Set max token limits per request | Prevents wasteful long responses | Low (LiteLLM config) |
| Monitor usage by team/user via LiteLLM Admin UI | Visibility drives accountability | Low (built-in feature) |
| Batch requests where possible | Better GPU utilization | Medium (client-side changes) |

### Monitoring

- Enable **AWS Customer Carbon Footprint Tool** in the AWS Billing Console for actual emissions data (available with 3-month delay)
- Track cost and usage with **AWS Cost Explorer** tags (already configured via TAGGING_STRATEGY.md)
- Review **LiteLLM Admin UI** for per-model usage breakdowns

---

## Methodology Notes

- **Power estimates** are based on published TDP/power consumption data for comparable EC2 instance types, scaled to Fargate vCPU allocations. Actual consumption varies with workload.
- **PUE of 1.2** is based on AWS published data for modern data centers (2023 Sustainability Report).
- **WUE of 1.8 L/kWh** is an industry estimate for Northern Virginia facilities. AWS does not publish per-region WUE.
- **Carbon intensity** uses EPA eGRID 2023 RFCE subregion data for us-east-1. Market-based accounting (using AWS RECs) would show lower values.
- **LLM inference estimates** are derived from academic research and may differ from actual provider infrastructure.
- All costs are based on AWS us-east-1 On-Demand pricing as of 2025. Actual costs may vary with usage patterns and pricing changes.
