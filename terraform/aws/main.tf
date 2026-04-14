// inchambers-gateway — AWS Fargate deployment.
//
// Provisions:
//   * VPC (2 AZ, public + private subnets, NAT)
//   * ECR repositories for each service image
//   * RDS Postgres (t4g.micro)
//   (No Redis — relay rate-limits in-memory at default scale)
//   * Secrets Manager for the gateway master key + OpenRouter key
//   * ECS cluster + Fargate services: caddy (public ALB), relay,
//     litellm, admin-ui (internal service discovery)
//   * ALB in front of caddy with ACM-issued cert
//
// Apply:
//   terraform init
//   terraform apply \
//     -var name=acme-firm \
//     -var org_id=<uuid> \
//     -var gateway_master_key=$(openssl rand -base64 32) \
//     -var openrouter_api_key=sk-or-v1-... \
//     -var domain_name=gateway.acme-firm.com

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.70" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region = var.region
}

variable "name" {
  type        = string
  description = "Short name prefix."
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "org_id" {
  type        = string
  description = "inchambers.ai org UUID."
}

variable "gateway_master_key" {
  type      = string
  sensitive = true
}

variable "litellm_master_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "openrouter_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "domain_name" {
  type        = string
  default     = ""
  description = "Custom domain for gateway ingress. Leave empty for ALB default DNS."
}

variable "hosted_zone_id" {
  type        = string
  default     = ""
  description = "Route 53 hosted zone for domain_name. Skipped if empty."
}

variable "allowed_origin" {
  type    = string
  default = "https://app.inchambers.ai"
}

variable "jwks_url" {
  type    = string
  default = "https://app.inchambers.ai/.well-known/jwks.json"
}

variable "pg_admin_user" {
  type    = string
  default = "gateway"
}

variable "pg_admin_password" {
  type      = string
  sensitive = true
}

variable "image_tag" {
  type    = string
  default = "latest"
}

locals {
  tags = {
    Project   = "inchambers-gateway"
    Firm      = var.name
    ManagedBy = "terraform"
  }
  litellm_key = coalesce(var.litellm_master_key, "sk-${random_id.litellm.hex}")
}

resource "random_id" "litellm" {
  byte_length = 24
}

// ────────────────────────────────────────────────────────────────────────────
// Networking
// ────────────────────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name            = "${var.name}-vpc"
  cidr            = "10.40.0.0/16"
  azs             = ["${var.region}a", "${var.region}b"]
  public_subnets  = ["10.40.1.0/24", "10.40.2.0/24"]
  private_subnets = ["10.40.11.0/24", "10.40.12.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}

// ────────────────────────────────────────────────────────────────────────────
// ECR repos
// ────────────────────────────────────────────────────────────────────────────
resource "aws_ecr_repository" "repo" {
  for_each = toset(["relay", "litellm", "admin-ui", "caddy"])
  name     = "ic-gateway-${each.key}"

  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
  tags = local.tags
}

// ────────────────────────────────────────────────────────────────────────────
// Secrets Manager
// ────────────────────────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "gateway_master" {
  name = "${var.name}/gateway-master-key"
  tags = local.tags
}
resource "aws_secretsmanager_secret_version" "gateway_master" {
  secret_id     = aws_secretsmanager_secret.gateway_master.id
  secret_string = var.gateway_master_key
}

resource "aws_secretsmanager_secret" "litellm_master" {
  name = "${var.name}/litellm-master-key"
  tags = local.tags
}
resource "aws_secretsmanager_secret_version" "litellm_master" {
  secret_id     = aws_secretsmanager_secret.litellm_master.id
  secret_string = local.litellm_key
}

resource "aws_secretsmanager_secret" "openrouter" {
  count = var.openrouter_api_key == "" ? 0 : 1
  name  = "${var.name}/openrouter-api-key"
  tags  = local.tags
}
resource "aws_secretsmanager_secret_version" "openrouter" {
  count         = var.openrouter_api_key == "" ? 0 : 1
  secret_id     = aws_secretsmanager_secret.openrouter[0].id
  secret_string = var.openrouter_api_key
}

resource "aws_secretsmanager_secret" "pg_password" {
  name = "${var.name}/postgres-password"
  tags = local.tags
}
resource "aws_secretsmanager_secret_version" "pg_password" {
  secret_id     = aws_secretsmanager_secret.pg_password.id
  secret_string = var.pg_admin_password
}

// ────────────────────────────────────────────────────────────────────────────
// RDS Postgres
// ────────────────────────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "pg" {
  name       = "${var.name}-pg-subnets"
  subnet_ids = module.vpc.private_subnets
  tags       = local.tags
}

resource "aws_security_group" "pg" {
  name   = "${var.name}-pg-sg"
  vpc_id = module.vpc.vpc_id
  tags   = local.tags
}
resource "aws_security_group_rule" "pg_from_apps" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.apps.id
  security_group_id        = aws_security_group.pg.id
}

resource "aws_db_instance" "pg" {
  identifier             = "${var.name}-pg"
  engine                 = "postgres"
  engine_version         = "16.4"
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  storage_type           = "gp3"
  db_name                = "gateway"
  username               = var.pg_admin_user
  password               = var.pg_admin_password
  db_subnet_group_name   = aws_db_subnet_group.pg.name
  vpc_security_group_ids = [aws_security_group.pg.id]
  skip_final_snapshot    = true
  storage_encrypted      = true
  publicly_accessible    = false
  tags                   = local.tags
}

// Redis removed — the relay rate-limits in-memory; LiteLLM runs single-
// instance. If you scale beyond one task per service, add an ElastiCache
// cluster and thread REDIS_URL back through.

// ────────────────────────────────────────────────────────────────────────────
// ECS cluster + apps
// ────────────────────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "main" {
  name = "${var.name}-cluster"
  tags = local.tags
}

resource "aws_security_group" "apps" {
  name   = "${var.name}-apps-sg"
  vpc_id = module.vpc.vpc_id
  tags   = local.tags
}
resource "aws_security_group_rule" "apps_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.apps.id
}
// Allow the ALB to reach Caddy on 80.
resource "aws_security_group_rule" "apps_from_alb" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.apps.id
}
// Apps can reach each other via Service Connect (internal).
resource "aws_security_group_rule" "apps_internal" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  self              = true
  security_group_id = aws_security_group.apps.id
}

// IAM role for ECS tasks (read secrets, pull images, write logs)
data "aws_iam_policy_document" "assume_ecs" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "read_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = concat(
      [aws_secretsmanager_secret.gateway_master.arn,
       aws_secretsmanager_secret.litellm_master.arn,
       aws_secretsmanager_secret.pg_password.arn],
      var.openrouter_api_key == "" ? [] : [aws_secretsmanager_secret.openrouter[0].arn],
    )
  }
}

resource "aws_iam_policy" "read_secrets" {
  name   = "${var.name}-read-secrets"
  policy = data.aws_iam_policy_document.read_secrets.json
}

resource "aws_iam_role_policy_attachment" "task_execution_secrets" {
  role       = aws_iam_role.task_execution.name
  policy_arn = aws_iam_policy.read_secrets.arn
}

// Service Discovery namespace for internal service-to-service DNS.
resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "${var.name}.local"
  description = "inchambers-gateway internal DNS"
  vpc         = module.vpc.vpc_id
}

// ────────────────────────────────────────────────────────────────────────────
// ALB (public ingress → Caddy)
// ────────────────────────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name   = "${var.name}-alb-sg"
  vpc_id = module.vpc.vpc_id
  tags   = local.tags
}
resource "aws_security_group_rule" "alb_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}
resource "aws_security_group_rule" "alb_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}
resource "aws_security_group_rule" "alb_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
}

resource "aws_lb" "main" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb.id]
  # Long-running SSE streams (deep analysis can take minutes). Default 60s
  # breaks mid-stream. 1 hour matches Cloud Run + Container Apps defaults.
  idle_timeout       = 3600
  tags               = local.tags
}

resource "aws_lb_target_group" "caddy" {
  name        = "${var.name}-caddy-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_acm_certificate" "cert" {
  count             = var.domain_name == "" ? 0 : 1
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
  tags = local.tags
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.domain_name == "" ? {} : {
    for dvo in aws_acm_certificate.cert[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  zone_id = var.hosted_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "cert" {
  count                   = var.domain_name == "" ? 0 : 1
  certificate_arn         = aws_acm_certificate.cert[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_lb_listener" "https" {
  count             = var.domain_name == "" ? 0 : 1
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = aws_acm_certificate_validation.cert[0].certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.caddy.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.caddy.arn
  }
}

resource "aws_route53_record" "gateway" {
  count   = var.domain_name == "" || var.hosted_zone_id == "" ? 0 : 1
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

// ────────────────────────────────────────────────────────────────────────────
// ECS services (Fargate)
// ────────────────────────────────────────────────────────────────────────────
locals {
  db_url = "postgres://${var.pg_admin_user}:${urlencode(var.pg_admin_password)}@${aws_db_instance.pg.endpoint}/gateway?sslmode=require"
}

module "relay_service" {
  source = "./modules/ecs-service"

  name               = "${var.name}-relay"
  cluster_arn        = aws_ecs_cluster.main.arn
  subnets            = module.vpc.private_subnets
  security_groups    = [aws_security_group.apps.id]
  task_execution_arn = aws_iam_role.task_execution.arn
  image              = "${aws_ecr_repository.repo["relay"].repository_url}:${var.image_tag}"
  container_port     = 8081
  environment = [
    { name = "RELAY_BIND_ADDR", value = "0.0.0.0:8081" },
    { name = "GATEWAY_ORG_ID", value = var.org_id },
    { name = "JWKS_URL", value = var.jwks_url },
    { name = "DATABASE_URL", value = local.db_url },
    { name = "RUST_LOG", value = "ic_gateway_relay=info,tower_http=info" },
  ]
  secrets = [
    { name = "GATEWAY_MASTER_KEY", valueFrom = aws_secretsmanager_secret.gateway_master.arn },
  ]
  namespace_id  = aws_service_discovery_private_dns_namespace.main.id
  health_path   = "/health"
  tags          = local.tags
}

module "litellm_service" {
  source = "./modules/ecs-service"

  name               = "${var.name}-litellm"
  cluster_arn        = aws_ecs_cluster.main.arn
  subnets            = module.vpc.private_subnets
  security_groups    = [aws_security_group.apps.id]
  task_execution_arn = aws_iam_role.task_execution.arn
  image              = "${aws_ecr_repository.repo["litellm"].repository_url}:${var.image_tag}"
  container_port     = 4000
  environment = [
    { name = "GATEWAY_ORG_ID", value = var.org_id },
    { name = "JWKS_URL", value = var.jwks_url },
    { name = "DATABASE_URL", value = local.db_url },
  ]
  secrets = concat(
    [
      { name = "LITELLM_MASTER_KEY", valueFrom = aws_secretsmanager_secret.litellm_master.arn },
    ],
    var.openrouter_api_key == "" ? [] : [
      { name = "OPENROUTER_API_KEY", valueFrom = aws_secretsmanager_secret.openrouter[0].arn },
    ],
  )
  namespace_id = aws_service_discovery_private_dns_namespace.main.id
  health_path  = "/health/liveliness"
  tags         = local.tags
}

module "admin_service" {
  source = "./modules/ecs-service"

  name               = "${var.name}-admin"
  cluster_arn        = aws_ecs_cluster.main.arn
  subnets            = module.vpc.private_subnets
  security_groups    = [aws_security_group.apps.id]
  task_execution_arn = aws_iam_role.task_execution.arn
  image              = "${aws_ecr_repository.repo["admin-ui"].repository_url}:${var.image_tag}"
  container_port     = 3000
  environment        = []
  secrets            = []
  namespace_id       = aws_service_discovery_private_dns_namespace.main.id
  health_path        = "/admin/"
  tags               = local.tags
}

module "caddy_service" {
  source = "./modules/ecs-service"

  name               = "${var.name}-caddy"
  cluster_arn        = aws_ecs_cluster.main.arn
  subnets            = module.vpc.private_subnets
  security_groups    = [aws_security_group.apps.id]
  task_execution_arn = aws_iam_role.task_execution.arn
  image              = "${aws_ecr_repository.repo["caddy"].repository_url}:${var.image_tag}"
  container_port     = 80
  environment = [
    { name = "GATEWAY_DOMAIN", value = var.domain_name == "" ? ":80" : var.domain_name },
    { name = "CADDY_TLS_MODE", value = "off" }, // TLS terminates at ALB
    { name = "ALLOWED_ORIGIN", value = var.allowed_origin },
    // ECS service discovery — each service registers at
    // `<svc>.<namespace>.local` via the private DNS namespace.
    { name = "UPSTREAM_RELAY",   value = "${var.name}-relay.${var.name}.local:8081" },
    { name = "UPSTREAM_LITELLM", value = "${var.name}-litellm.${var.name}.local:4000" },
    { name = "UPSTREAM_ADMIN",   value = "${var.name}-admin.${var.name}.local:3000" },
  ]
  secrets          = []
  namespace_id     = aws_service_discovery_private_dns_namespace.main.id
  target_group_arn = aws_lb_target_group.caddy.arn
  health_path      = "/health"
  tags             = local.tags
}

output "gateway_url" {
  value = var.domain_name != "" ? "https://${var.domain_name}" : "http://${aws_lb.main.dns_name}"
}
output "ecr_relay_repo" {
  value = aws_ecr_repository.repo["relay"].repository_url
}
output "ecr_litellm_repo" {
  value = aws_ecr_repository.repo["litellm"].repository_url
}
