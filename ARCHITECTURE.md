# Architecture Guide

## Overview

This project deploys a production-ready LiteLLM proxy on AWS, orchestrated through Azure DevOps Pipelines. The infrastructure is defined as 5 modular CloudFormation stacks with explicit dependency ordering.

```
┌────────────────────────────────────────────────────────────────────────┐
│                        Azure DevOps Pipelines                         │
│   (CI/CD orchestration, Docker builds, CloudFormation deployments)    │
└────────────────────────┬───────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────────────────────┐
│                          AWS Account                                   │
│                                                                        │
│  ┌──────────────┐  ┌─────────────────────────────────────────────┐    │
│  │  KMS + IAM   │  │              VPC (10.0.0.0/16)              │    │
│  │  + Secrets   │  │                                             │    │
│  │  Manager     │  │  ┌─────────────┐    ┌─────────────┐        │    │
│  │              │  │  │ Public Sub1 │    │ Public Sub2 │        │    │
│  │ 4 Secrets:   │  │  │  ALB Node   │    │  ALB Node   │        │    │
│  │ - master-key │  │  └──────┬──────┘    └──────┬──────┘        │    │
│  │ - ui-password│  │         │    ┌─────────────┘               │    │
│  │ - api-keys   │  │         ▼    ▼                              │    │
│  │ - database   │  │  ┌─────────────────┐                        │    │
│  └──────────────┘  │  │  ALB (:80/443)  │                        │    │
│                     │  └────────┬────────┘                        │    │
│                     │           │ :4000                            │    │
│                     │  ┌────────┴──────────────────────────┐      │    │
│                     │  │        Private Subnets             │      │    │
│                     │  │  ┌──────────┐   ┌──────────────┐  │      │    │
│                     │  │  │ ECS Task │   │ RDS Postgres  │  │      │    │
│                     │  │  │ (Fargate)│──▶│   :5432       │  │      │    │
│                     │  │  │  :4000   │   │  Encrypted    │  │      │    │
│                     │  │  └──────────┘   └──────────────┘  │      │    │
│                     │  └───────────────────────────────────┘      │    │
│                     │                                             │    │
│                     │  VPC Endpoints: ECR, S3, Secrets, Logs      │    │
│                     └─────────────────────────────────────────────┘    │
│                                                                        │
│  ┌──────────┐  ┌──────────────┐  ┌──────────────┐                    │
│  │   ECR    │  │  CloudWatch  │  │   Lambda     │                    │
│  │ Registry │  │    Logs      │  │ (Rotation)   │                    │
│  └──────────┘  └──────────────┘  └──────────────┘                    │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Stack Dependency Chain

```
1. security-stack ──────────────────────────────────────────────┐
   │ (KMS, Secrets, IAM Roles)                                  │
   ▼                                                             │
2. network-stack ──────────────────────────────────────┐        │
   │ (VPC, Subnets, Security Groups, VPC Endpoints)    │        │
   ▼                                                    │        │
3. alb-stack ────────────────────────────────┐         │        │
   │ (ALB, Listeners, Target Groups)         │         │        │
   ▼                                          │         │        │
4. database-stack                             │         │        │
   │ (RDS PostgreSQL, Alarms, Rotation)       │         │        │
   ▼                                          ▼         ▼        ▼
5. litellm-stack ◄─────────── imports from all stacks above
   (ECR, ECS Cluster, Service, Auto-scaling, Alarms)
```

| Stack | Deploy Time | Key Exports |
|-------|-------------|-------------|
| security-stack | ~5 min | KMS key, 4 secret ARNs, 2 IAM role ARNs |
| network-stack | ~3 min | VPC ID, 4 subnet IDs, 5 security group IDs |
| alb-stack | ~5 min | ALB ARN/DNS, listener ARNs, target group ARN |
| database-stack | ~10-15 min | DB endpoint, port, connection string |
| litellm-stack | ~10 min | ECS cluster/service, ECR URI, log group |
| **Total** | **~35-45 min** | |

---

## Network Architecture

### VPC Layout

```
VPC: 10.0.0.0/16
├── Public Subnet 1  (AZ-a)  ── ALB, NAT Gateway
├── Public Subnet 2  (AZ-b)  ── ALB
├── Private Subnet 1 (AZ-a)  ── ECS Tasks, RDS (primary), VPC Endpoints
└── Private Subnet 2 (AZ-b)  ── ECS Tasks, RDS (standby), VPC Endpoints
```

### Routing

| Route Table | Destination | Target |
|-------------|-------------|--------|
| Public | 0.0.0.0/0 | Internet Gateway |
| Private | 0.0.0.0/0 | NAT Gateway (if enabled) |
| Private | S3 prefix list | S3 VPC Endpoint (Gateway) |

### Security Groups

```
Internet ──[:80/:443]──▶ ALB SG ──[:4000]──▶ ECS SG ──[:5432]──▶ RDS SG
                                                │
                                                └──[:443]──▶ VPC Endpoint SG
                                                              (ECR, Secrets, Logs)

Lambda Rotation SG ──[:5432]──▶ RDS SG
                   ──[:443]──▶ Internet (for AWS APIs)
```

| Security Group | Inbound | Outbound |
|---------------|---------|----------|
| **ALB** | TCP 80, 443 from 0.0.0.0/0 | TCP 4000 to ECS SG |
| **ECS** | TCP 4000 from ALB SG | TCP 443 to 0.0.0.0/0; TCP 5432 to RDS SG |
| **RDS** | TCP 5432 from ECS SG, Lambda SG | — |
| **Lambda Rotation** | — | TCP 5432 to RDS SG; TCP 443 to 0.0.0.0/0 |
| **VPC Endpoints** | TCP 443 from VPC CIDR | — |

### VPC Endpoints (Private Subnet Access to AWS Services)

| Endpoint | Type | Purpose |
|----------|------|---------|
| com.amazonaws.{region}.s3 | Gateway | ECR image layers |
| com.amazonaws.{region}.ecr.api | Interface | ECR API calls |
| com.amazonaws.{region}.ecr.dkr | Interface | Docker image pulls |
| com.amazonaws.{region}.secretsmanager | Interface | Secret retrieval |
| com.amazonaws.{region}.logs | Interface | CloudWatch log shipping |

---

## Secrets Architecture

All secrets are encrypted with a customer-managed KMS key and stored in AWS Secrets Manager.

```
┌─────────────────────┐     ┌─────────────────────┐
│  master-key         │     │  ui-password         │
│  ─────────────────  │     │  ─────────────────   │
│  LITELLM_MASTER_KEY │     │  UI_USERNAME: admin  │
│  (48 chars, rotated)│     │  UI_PASSWORD (24ch)  │
│  Auto: 30 days      │     │  Manual rotation     │
└─────────┬───────────┘     └──────────┬───────────┘
          │                            │
          ▼                            ▼
   API Authentication            Admin UI Login
   (Bearer token)                (Web interface)

┌─────────────────────┐     ┌─────────────────────┐
│  api-keys           │     │  database            │
│  ─────────────────  │     │  ─────────────────   │
│  OPENAI_API_KEY     │     │  username, password  │
│  ANTHROPIC_API_KEY  │     │  host, port, dbname  │
│  AWS_BEDROCK_REGION │     │  DATABASE_URL        │
│  Manual rotation    │     │  Auto: 30 days       │
└─────────┬───────────┘     └──────────┬───────────┘
          │                            │
          ▼                            ▼
   LLM Provider Access          PostgreSQL Connection
```

### Secret Rotation

| Secret | Rotation | Method |
|--------|----------|--------|
| master-key | Auto (30 days) | Lambda: generates new key, keeps previous valid 7 days |
| ui-password | Manual | Update via Secrets Manager console or CLI |
| api-keys | Manual | Update when provider keys change |
| database | Auto (30 days) | Lambda: ALTER USER password, psycopg2 via VPC |

---

## Compute Architecture

### ECS Fargate Task Definition

```
┌─────────────────────────────────────────────────┐
│  Task Definition: {env}-litellm-proxy           │
│  CPU: 512 (0.5 vCPU)  Memory: 1024 MB          │
│  Network: awsvpc       Platform: FARGATE        │
│                                                  │
│  ┌─────────────────────────────────────────────┐ │
│  │  Container: litellm-proxy                   │ │
│  │  Image: {account}.dkr.ecr.{region}.amazonaws│ │
│  │         .com/litellm-proxy:latest           │ │
│  │  Port: 4000                                 │ │
│  │                                              │ │
│  │  Environment:                                │ │
│  │    LITELLM_LOG=DEBUG                         │ │
│  │    STORE_MODEL_IN_DB=true                    │ │
│  │    LITELLM_MODE=PRODUCTION                   │ │
│  │    UI_ACCESS_MODE=admin_ui                   │ │
│  │                                              │ │
│  │  Secrets (from Secrets Manager):             │ │
│  │    LITELLM_MASTER_KEY  ← master-key          │ │
│  │    UI_USERNAME         ← ui-password          │ │
│  │    UI_PASSWORD         ← ui-password          │ │
│  │    OPENAI_API_KEY      ← api-keys             │ │
│  │    ANTHROPIC_API_KEY   ← api-keys             │ │
│  │    DATABASE_URL        ← database             │ │
│  │                                              │ │
│  │  Health Check:                               │ │
│  │    GET /health/liveliness (180s start period)│ │
│  └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

### Auto-Scaling

| Policy | Metric | Target | Cooldown |
|--------|--------|--------|----------|
| CPU Tracking | CPUUtilization | 70% | In: 300s / Out: 60s |
| Memory Tracking | MemoryUtilization | 80% | In: 300s / Out: 60s |

- **Min Capacity:** 1 task (configurable)
- **Max Capacity:** 4 tasks (configurable)
- **Capacity Provider:** FARGATE_SPOT (dev), FARGATE (prod)

### Deployment Strategy

- **Minimum Healthy:** 100%
- **Maximum:** 200% (rolling deployment)
- **Circuit Breaker:** Enabled with automatic rollback
- **Health Check Grace Period:** 600 seconds (10 minutes)

---

## Load Balancer Architecture

### Request Routing

```
Client Request
     │
     ▼
┌──────────────────┐
│  ALB (:80/:443)  │
│  Internet-facing  │
└────────┬─────────┘
         │
    ┌────┴────────────────────────────────┐
    │         Listener Rules              │
    │                                     │
    │  Priority 10:  /v1/*    → ECS TG    │
    │  Priority 20:  /health  → ECS TG    │
    │  Priority 30:  /ui/*    → ECS TG    │
    │  Priority 100: /*       → ECS TG    │
    └─────────────────────────────────────┘
                    │
                    ▼
         ┌────────────────┐
         │  Target Group  │
         │  HTTP:4000     │
         │  IP targets    │
         └────────────────┘
```

### Health Checks

| Level | Path | Interval | Timeout | Thresholds |
|-------|------|----------|---------|------------|
| ALB Target Group | /health/liveliness | 30s | 15s | Healthy: 2 / Unhealthy: 5 |
| ECS Container | /health/liveliness | 30s | 10s | Retries: 5, Start: 180s |

### Optional Features

| Feature | Dev | Production |
|---------|-----|------------|
| HTTPS (ACM Certificate) | No | Yes (auto-validated via DNS) |
| WAF | No | Yes (rate limiting, OWASP rules) |
| Route53 DNS Record | No | Yes (A record alias) |
| Deletion Protection | No | Yes |

---

## Database Architecture

### RDS PostgreSQL

```
┌────────────────────────────────────────────┐
│  RDS: {env}-litellm-db                     │
│  Engine: PostgreSQL 15.10                  │
│  Instance: db.t3.micro (dev)               │
│  Storage: 20-100 GB gp3 (auto-scaling)     │
│  Encryption: KMS (customer-managed key)    │
│  Subnet Group: Private Subnets (1 & 2)    │
│  Multi-AZ: Enabled in prod                 │
│  Backup: 7-day retention, 03:00-04:00 UTC  │
│  Maintenance: Sun 04:00-05:00 UTC          │
└────────────────────────────────────────────┘
```

### CloudWatch Alarms

| Alarm | Metric | Threshold |
|-------|--------|-----------|
| CPU Utilization | CPUUtilization | > 80% (3 x 5min) |
| Free Storage | FreeStorageSpace | < 5 GB (3 x 5min) |
| Connection Count | DatabaseConnections | > 80 (3 x 5min) |

---

## Monitoring & Alarms

### ECS Alarms

| Alarm | Metric | Threshold |
|-------|--------|-----------|
| High CPU | CPUUtilization | > 85% (3 x 5min) |
| High Memory | MemoryUtilization | > 90% (3 x 5min) |
| Unhealthy Hosts | UnHealthyHostCount | >= 1 (3 x 1min) |
| 5xx Errors | HTTPCode_Target_5XX_Count | > 10 (2 x 5min) |

### Log Groups

| Log Group | Source | Retention |
|-----------|--------|-----------|
| /ecs/{env}-litellm-proxy | ECS Tasks | 14 days (configurable) |
| /aws/lambda/{env}-litellm-* | Rotation Lambdas | 90 days (prod) / 14 days (dev) |

---

## CI/CD Pipeline Architecture

### Pipeline Files

```
azure-devops/
├── Deployment Pipelines
│   ├── azure-pipelines-security.yml      # Stack 1: KMS, Secrets, IAM
│   ├── azure-pipelines-network.yml       # Stack 2: VPC, Subnets, SGs
│   ├── azure-pipelines-alb.yml           # Stack 3: ALB, Listeners
│   ├── azure-pipelines-database.yml      # Stack 4: RDS PostgreSQL
│   └── azure-pipelines-litellm.yml       # Stack 5: Docker build + ECS
│
├── Update Pipelines
│   ├── azure-pipelines-litellm-config.yml  # Update LiteLLM config
│   └── azure-pipelines-litellm-update.yml  # Force ECS redeployment
│
├── Teardown Pipelines
│   ├── azure-pipelines-teardown.yml        # Full teardown orchestration
│   ├── azure-pipelines-teardown-litellm.yml
│   ├── azure-pipelines-teardown-database.yml
│   ├── azure-pipelines-teardown-alb.yml
│   ├── azure-pipelines-teardown-network.yml
│   └── azure-pipelines-teardown-security.yml
│
├── Validation
│   └── azure-pipelines-validate.yml      # Health checks and validation
│
└── Templates (Reusable)
    ├── aws-cfn-deploy.yml                # CloudFormation deploy template
    ├── aws-ecr-build.yml                 # Docker build and ECR push
    └── check-prerequisites.yml           # Stack dependency checks
```

### Pipeline Flow

```
Developer triggers pipeline
         │
         ▼
┌──────────────────┐
│ Pre-flight Checks│ ── Validate template, check prerequisites
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Docker Build    │ ── Build image, push to ECR (litellm stack only)
└────────┬─────────┘
         │
         ▼
┌──────────────────────┐
│ CloudFormation Deploy│ ── Create/Update stack, wait for completion
└────────┬─────────────┘
         │
         ▼
┌──────────────────┐
│   Verification   │ ── Health check, output endpoint info
└──────────────────┘
```

---

## Cost Estimates

### Dev Environment (us-east-1, defaults)

| Resource | Configuration | Monthly Cost |
|----------|---------------|--------------|
| NAT Gateway | 1 AZ (optional) | ~$32 |
| RDS PostgreSQL | db.t3.micro, 20GB gp3 | ~$13 |
| ECS Fargate | 1 task, 0.5 vCPU, 1GB (Spot) | ~$15 |
| ALB | Internet-facing | ~$16 |
| KMS | 1 customer key | ~$1 |
| Secrets Manager | 4 secrets | ~$2 |
| CloudWatch Logs | ~5GB/month | ~$3 |
| VPC Endpoints | 4 interface endpoints | ~$29 |
| **Total** | | **~$111/month** |

### Production Additions

| Resource | Change | Additional Cost |
|----------|--------|-----------------|
| RDS | db.t3.small + Multi-AZ | +$25 |
| ECS | 2+ tasks, on-demand Fargate | +$15 |
| ACM Certificate | Free | $0 |
| WAF | Rate limiting + OWASP rules | ~$10 |
| NAT Gateway | Required | ~$32 |

---

## Environment Differences

| Feature | Dev | Production |
|---------|-----|------------|
| Multi-AZ | Optional (default: off) | Enforced |
| ECS Capacity | Fargate Spot | Fargate On-Demand |
| RDS Instance | db.t3.micro | db.t3.small+ |
| RDS Deletion Protection | Off | On |
| ALB Deletion Protection | Off | On |
| WAF | Off | On |
| Container Insights | Off | On |
| Performance Insights | Off | On |
| Log Retention | 14 days | 90+ days |
| Secret Rotation | 30 days | 30 days |
