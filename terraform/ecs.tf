resource "aws_cloudwatch_log_group" "bao" {
  name              = "/ecs/${var.name}"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "this" {
  name = var.name
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: pull image, write logs, read the DB password parameter.
resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secret" {
  name = "db-password"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters"]
      Resource = aws_ssm_parameter.db_password.arn
    }]
  })
}

# Task role: what OpenBao itself can do (KMS unseal, ECS Exec).
resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "task" {
  name = "openbao"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.unseal.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_ecs_task_definition" "bao" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name       = "openbao"
    image      = var.openbao_image
    essential  = true
    entryPoint = ["/bin/sh", "-c"]
    command    = [file("${path.module}/files/bao-entrypoint.sh")]

    portMappings = [
      { containerPort = 8200, protocol = "tcp" },
      { containerPort = 8201, protocol = "tcp" },
    ]

    environment = [
      { name = "AWS_REGION", value = var.region },
      { name = "KMS_KEY_ID", value = aws_kms_key.unseal.key_id },
      { name = "KMS_PLUGIN_IMAGE", value = var.kms_plugin_image },
      { name = "PG_HOST", value = aws_rds_cluster.this.endpoint },
      { name = "PG_USER", value = aws_rds_cluster.this.master_username },
      { name = "PG_DB", value = aws_rds_cluster.this.database_name },
      { name = "RDS_CA_B64", value = base64encode(data.http.rds_ca.response_body) },
      { name = "VPC_CIDR", value = data.aws_vpc.default.cidr_block },
    ]

    secrets = [
      { name = "PGPASSWORD", valueFrom = aws_ssm_parameter.db_password.arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.bao.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "bao"
      }
    }
  }])
}

# The service (and so the tasks) only exists while var.running is true.
resource "aws_ecs_service" "bao" {
  count = var.running ? 1 : 0

  name            = var.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.bao.arn
  desired_count   = var.node_count
  launch_type     = "FARGATE"

  enable_execute_command            = true
  health_check_grace_period_seconds = 60

  # Replace nodes one at a time during deploys so there is always an active node.
  deployment_minimum_healthy_percent = 66
  deployment_maximum_percent         = 134

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.bao.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.bao[0].arn
    container_name   = "openbao"
    container_port   = 8200
  }

  depends_on = [aws_lb_listener.https]
}
