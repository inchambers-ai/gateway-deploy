variable "name" { type = string }
variable "cluster_arn" { type = string }
variable "subnets" { type = list(string) }
variable "security_groups" { type = list(string) }
variable "task_execution_arn" { type = string }
# Runtime role assumed by the container itself. Keep separate from (and more
# restricted than) the execution role so an in-container compromise can't read
# the execution role's secrets. Defaults to "" → no task role attached.
variable "task_role_arn" {
  type    = string
  default = ""
}
variable "image" { type = string }
variable "container_port" { type = number }
variable "environment" { type = list(map(string)) }
variable "secrets" { type = list(map(string)) }
variable "namespace_id" { type = string }
variable "target_group_arn" {
  type    = string
  default = ""
}
variable "health_path" {
  type    = string
  default = "/health"
}
variable "cpu" {
  type    = number
  default = 512
}
variable "memory" {
  type    = number
  default = 1024
}
variable "desired_count" {
  type    = number
  default = 1
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_cloudwatch_log_group" "lg" {
  name              = "/ecs/${var.name}"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_ecs_task_definition" "td" {
  family                   = var.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.task_execution_arn
  task_role_arn            = var.task_role_arn != "" ? var.task_role_arn : var.task_execution_arn

  container_definitions = jsonencode([
    {
      name      = var.name
      image     = var.image
      essential = true
      portMappings = [
        { containerPort = var.container_port, protocol = "tcp" }
      ]
      environment = var.environment
      secrets     = var.secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.lg.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "ecs"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "wget -q --spider http://127.0.0.1:${var.container_port}${var.health_path} || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
    }
  ])

  tags = var.tags
}

data "aws_region" "current" {}

resource "aws_service_discovery_service" "sd" {
  name = replace(var.name, "_", "-")

  dns_config {
    namespace_id = var.namespace_id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_ecs_service" "svc" {
  name                              = var.name
  cluster                           = var.cluster_arn
  task_definition                   = aws_ecs_task_definition.td.arn
  desired_count                     = var.desired_count
  launch_type                       = "FARGATE"
  platform_version                  = "LATEST"
  health_check_grace_period_seconds = var.target_group_arn != "" ? 30 : 0

  network_configuration {
    subnets          = var.subnets
    security_groups  = var.security_groups
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == "" ? [] : [1]
    content {
      target_group_arn = var.target_group_arn
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  service_registries {
    registry_arn = aws_service_discovery_service.sd.arn
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  tags = var.tags
}

output "service_name" { value = aws_ecs_service.svc.name }
output "task_definition_arn" { value = aws_ecs_task_definition.td.arn }
