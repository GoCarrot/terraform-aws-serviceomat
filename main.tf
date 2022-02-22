# Copyright 2022 Teak.io, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3, < 5"
    }
  }
}

data "aws_default_tags" "tags" {}

locals {
  setup_lb     = length(var.lb_listener_arns) > 0
  service      = var.service_name

  default_asg_health_check_type = local.setup_lb ? "ELB" : "EC2"
  asg_health_check_type         = coalesce(var.health_check_type, local.default_asg_health_check_type)
  default_tags                  = { for key, value in data.aws_default_tags.tags.tags : key => value if var.attach_default_tags_to_asg_instances }
  our_tags                      = merge(local.default_tags, var.additional_tags_for_asg_instances)

  create_role = var.create_role
}

data "aws_subnet" "exemplar" {
  id = var.subnet_ids[0]
}

resource "aws_security_group" "sg" {
  count = local.setup_lb ? 1 : 0

  name        = "${local.service}-allow_lb"
  description = "Allows traffic from the load balancer to ${local.service}"
  vpc_id      = data.aws_subnet.exemplar.vpc_id
}

resource "aws_security_group_rule" "lb-ingress" {
  for_each = local.setup_lb ? toset(var.lb_security_group_ids) : toset([])

  security_group_id = aws_security_group.sg[0].id

  type      = "ingress"
  from_port = var.port
  to_port   = var.port
  protocol  = "tcp"

  source_security_group_id = each.key
}

resource "aws_lb_target_group" "tg" {
  count = local.setup_lb ? 1 : 0

  name     = "${local.service}-template"
  port     = var.port
  protocol = var.protocol
  vpc_id   = data.aws_subnet.exemplar.vpc_id

  load_balancing_algorithm_type = var.load_balancing_algorithm_type

  health_check {
    enabled             = lookup(var.health_check, "enabled", true)
    healthy_threshold   = lookup(var.health_check, "healthy_threshold", 3)
    unhealthy_threshold = lookup(var.health_check, "unhealthy_threshold", 3)
    interval            = lookup(var.health_check, "interval", 30)
    timeout             = lookup(var.health_check, "timeout", 5)
    matcher             = lookup(var.health_check, "matcher", null)
    path                = lookup(var.health_check, "path", null)
    port                = lookup(var.health_check, "port", "traffic-port")
  }
}

resource "aws_lb_listener_rule" "listener" {
  for_each = toset(var.lb_listener_arns)

  listener_arn = each.value
  priority     = var.lb_priority + 40000

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg[0].arn
  }

  dynamic "condition" {
    for_each = [
      for condition_rule in var.lb_conditions : condition_rule if length(lookup(condition_rule, "host_headers", [])) > 0
    ]

    content {
      host_header {
        values = condition.value["host_headers"]
      }
    }
  }

  dynamic "condition" {
    for_each = [
      for condition_rule in var.lb_conditions : condition_rule if length(lookup(condition_rule, "http_headers", [])) > 0
    ]

    content {
      dynamic "http_header" {
        for_each = condition.value["https_headers"]

        content {
          key    = http_header.value["http_header_name"]
          values = http_header.value["values"]
        }
      }
    }
  }

  dynamic "condition" {
    for_each = [
      for condition_rule in var.lb_conditions : condition_rule if length(lookup(condition_rule, "http_request_methods", [])) > 0
    ]

    content {
      http_request_method {
        values = condition.value["http_request_methods"]
      }
    }
  }

  dynamic "condition" {
    for_each = [
      for condition_rule in var.lb_conditions : condition_rule if length(lookup(condition_rule, "path_patterns", [])) > 0
    ]

    content {
      path_pattern {
        values = condition.value["path_patterns"]
      }
    }
  }

  dynamic "condition" {
    for_each = [
      for condition_rule in var.lb_conditions : condition_rule if length(lookup(condition_rule, "query_strings", [])) > 0
    ]

    content {
      dynamic "query_string" {
        for_each = condition.value["query_strings"]

        content {
          key   = lookup(query_string.value, "key", null)
          value = query_string.value["value"]
        }
      }
    }
  }

  dynamic "condition" {
    for_each = [
      for condition_rule in var.lb_conditions : condition_rule if length(lookup(condition_rule, "source_ips", [])) > 0
    ]

    content {
      source_ip {
        values = condition.value["source_ips"]
      }
    }
  }
}

data "aws_ssm_parameter" "stub-ami" {
  for_each = { arm64 = "arm64", x86_64 = "amd64" }

  name = "/aws/service/debian/release/11/latest/${each.value}"
}

data "aws_ec2_instance_type" "instance-info" {
  instance_type = var.instance_type
}

locals {
  instance_arch = data.aws_ec2_instance_type.instance-info.supported_architectures[0]
}

data "aws_ami_ids" "built-ami" {
  count = var.ami_name_regex != null && var.ami_owner_id != null ? 1 : 0

  owners = [var.ami_owner_id]

  filter {
    name   = "architecture"
    values = [local.instance_arch]
  }

  name_regex = var.ami_name_regex
}

locals {
  default_ami_id = coalescelist(try(data.aws_ami_ids.built-ami[0].ids, []), [data.aws_ssm_parameter.stub-ami[local.instance_arch].value])[0]
}

data "aws_ami" "default-ami" {
  # See https://wiki.debian.org/Cloud/AmazonEC2Image/Bullseye
  owners = compact(["136693071363", var.ami_owner_id])

  filter {
    name   = "image-id"
    values = [local.default_ami_id]
  }
}

locals {
  root_ebs_volume = [for volume in data.aws_ami.default-ami.block_device_mappings : volume if volume.device_name == data.aws_ami.default-ami.root_device_name][0]
  min_ebs_size    = local.root_ebs_volume.ebs.volume_size
}

data "aws_iam_policy_document" "allow_ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "role" {
  count = local.create_role ? 1 : 0

  name = "${title(local.service)}Role"
  path = "/${var.organization_prefix}/service-role/"

  description = "Role assumed by servers running the ${local.service} service."

  assume_role_policy = data.aws_iam_policy_document.allow_ec2_assume.json
}

resource "aws_iam_instance_profile" "instance-profile" {
  count = local.create_role ? 1 : 0

  name = "${title(local.service)}InstanceProfile"
  path = "/${var.organization_prefix}/service-role/"
  role = aws_iam_role.role[0].name
}

data "aws_iam_policy" "default-policies" {
  for_each = local.create_role ? toset(var.default_role_policies) : toset([])

  name = each.key
}

resource "aws_iam_role_policy_attachment" "default-policies" {
  for_each = data.aws_iam_policy.default-policies

  role       = aws_iam_role.role[0].name
  policy_arn = each.value.arn
}

locals {
  instance_profile_arn = try(coalescelist(try(compact([var.iam_instance_profile]), []), aws_iam_instance_profile.instance-profile[*].arn), [])
}

resource "aws_launch_template" "template" {
  name_prefix = "${local.service}-lt"

  key_name = var.key_name

  image_id = local.default_ami_id

  instance_type = var.instance_type
  ebs_optimized = true

  vpc_security_group_ids = concat(aws_security_group.sg[*].id, var.instance_security_group_ids)

  instance_initiated_shutdown_behavior = "terminate"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = max(var.volume_size, local.min_ebs_size)
      delete_on_termination = true
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  lifecycle {
    ignore_changes        = [image_id, latest_version]
  }

  dynamic "iam_instance_profile" {
    for_each = toset(local.instance_profile_arn)

    content {
      arn = iam_instance_profile.value
    }
  }

  monitoring {
    enabled = var.detailed_instance_monitoring
  }

  user_data = var.user_data != null && length(var.user_data) > 0 ? base64encode(var.user_data) : ""
}

resource "aws_autoscaling_group" "asg" {
  name     = "${local.service}-template"
  min_size = 0
  max_size = 0

  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = aws_launch_template.template.id
    version = "$Latest"
  }

  dynamic "warm_pool" {
    for_each = [
      var.warm_pool ? [{}] : []
    ]

    content {}
  }

  health_check_type = local.asg_health_check_type

  target_group_arns = aws_lb_target_group.tg[*].id

  tags = concat(
    [for k, v in local.our_tags : { key = k, value = v, propagate_at_launch = true }],
    [
      {
        key                 = "${var.organization_prefix}:min_size"
        value               = var.min_instances
        propagate_at_launch = false
      },
      {
        key                 = "${var.organization_prefix}:max_size"
        value               = var.max_instances
        propagate_at_launch = false
      }
    ]
  )
}
