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
      version = ">= 3.72, < 5"

      configuration_aliases = [aws.meta]
    }
  }
}

data "aws_default_tags" "tags" {}

data "aws_ssm_parameter" "account-info" {
  provider = aws.meta

  name = "/omat/account_registry/${var.account_canonical_slug}"
}

data "aws_ssm_parameter" "organization-prefix" {
  provider = aws.meta

  name = "/omat/organization_prefix"
}

locals {
  setup_lb = length(var.lb_listener_arns) > 0
  service  = var.service_name

  default_asg_health_check_type = local.setup_lb ? "ELB" : "EC2"
  asg_health_check_type         = coalesce(var.health_check_type, local.default_asg_health_check_type)
  default_tags                  = { for key, value in data.aws_default_tags.tags.tags : key => value if var.attach_default_tags_to_asg_instances }
  asg_tags                      = merge(local.default_tags, var.additional_tags_for_asg_instances)
  asg_tag_structures = concat(
    [for k, v in local.asg_tags : { key = k, value = v, propagate_at_launch = true }],
    [
      {
        key                 = "${local.organization_prefix}:min_size"
        value               = var.min_instances
        propagate_at_launch = false
      },
      {
        key                 = "${local.organization_prefix}:max_size"
        value               = var.max_instances
        propagate_at_launch = false
      }
    ]
  )

  tags = { for key, value in var.tags : key => value if lookup(data.aws_default_tags.tags.tags, key, null) != value }

  create_role = var.create_role

  account_info        = jsondecode(nonsensitive(data.aws_ssm_parameter.account-info.value))
  organization_prefix = nonsensitive(data.aws_ssm_parameter.organization-prefix.value)
}

data "aws_subnet" "exemplar" {
  id = var.subnet_ids[0]
}

resource "aws_security_group" "sg" {
  count = local.setup_lb ? 1 : 0

  name        = "${local.service}-allow_lb"
  description = "Allows traffic from the load balancer to ${local.service}"
  vpc_id      = data.aws_subnet.exemplar.vpc_id

  tags = local.tags
}

resource "aws_security_group_rule" "lb-ingress" {
  for_each = local.setup_lb ? var.lb_security_group_ids : {}

  security_group_id = aws_security_group.sg[0].id

  type      = "ingress"
  from_port = var.port
  to_port   = var.port
  protocol  = "tcp"

  source_security_group_id = each.value

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "tg" {
  count = local.setup_lb ? 1 : 0

  name_prefix = substr(local.service, 0, 6)
  port        = var.port
  protocol    = var.protocol
  vpc_id      = data.aws_subnet.exemplar.vpc_id

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

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "listener" {
  for_each = local.setup_lb ? var.lb_listener_arns : {}

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
        for_each = condition.value["http_headers"]

        content {
          http_header_name = http_header.value["http_header_name"]
          values           = http_header.value["values"]
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

  tags = local.tags
}

resource "aws_ssm_parameter" "lb_listener_arns" {
  count = local.setup_lb ? 1 : 0

  provider = aws.meta

  name  = "${local.account_info["prefix"]}/config/${local.service}/listener_arns"
  type  = "String"
  value = jsonencode(var.lb_listener_arns)

  tags = local.tags
}

resource "aws_ssm_parameter" "architecture" {
  provider = aws.meta

  name  = "${local.account_info["prefix"]}/config/${local.service}/architecture"
  type  = "String"
  value = local.instance_arch

  tags = local.tags
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
  path = "/${local.organization_prefix}/service-role/"

  description = "Role assumed by servers running the ${local.service} service."

  assume_role_policy = data.aws_iam_policy_document.allow_ec2_assume.json

  tags = local.tags
}

resource "aws_iam_instance_profile" "instance-profile" {
  count = local.create_role ? 1 : 0

  name = "${title(local.service)}InstanceProfile"
  path = "/${local.organization_prefix}/service-role/"
  role = aws_iam_role.role[0].name

  tags = local.tags
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
  subnet_randomizer    = { for id in var.subnet_ids : sha256("${local.service}-${id}") => id }
  subnet               = local.subnet_randomizer[sort(keys(local.subnet_randomizer))[0]]
}

resource "aws_launch_template" "template" {
  name_prefix = "${local.service}-lt"

  key_name = var.key_name

  image_id = local.default_ami_id

  instance_type = var.instance_type
  ebs_optimized = data.aws_ec2_instance_type.instance-info.ebs_optimized_support != "unsupported"

  instance_initiated_shutdown_behavior = "terminate"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = max(var.volume_size, local.min_ebs_size)
      delete_on_termination = true
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125

      kms_key_id = var.kms_key_id
      encrypted  = var.kms_key_id != null
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = var.instance_metadata_tags ? "enabled" : "disabled"
  }

  lifecycle {
    ignore_changes = [image_id, latest_version]
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

  network_interfaces {
    subnet_id = local.subnet
    security_groups = concat(aws_security_group.sg[*].id, var.instance_security_group_ids)
  }

  dynamic "tag_specifications" {
    # elastic-gpu is intentionally omitted from this list.
    # The EC2 API gets mad and logs errors to cloudtrail if autoscaling tries to
    # tag elastic-gpus when the request has no elastic-gpus. I do not want spurious
    # errors in my cloudtrail logs.
    #
    # spot-instances-request is intentionally omitted from this list.
    # If an ASG isn't requesting spot intances, having spot-instances-request in the
    # list causes the ASG to fail to boot instances.
    for_each = toset(["instance", "volume", "network-interface"])

    content {
      resource_type = tag_specifications.value
      tags          = { for key, value in merge(local.default_tags, local.tags) : key => value if key != "Managed" }
    }
  }

  user_data = var.user_data != null && length(var.user_data) > 0 ? base64encode(var.user_data) : ""

  tags = local.tags
}

resource "aws_placement_group" "group" {
  count = var.placement_strategy != null ? 1 : 0

  name            = "${local.service}-placement"
  strategy        = can(regex("^[1-7]$", var.placement_strategy)) ? "partition" : var.placement_strategy
  partition_count = can(regex("^[1-7]$", var.placement_strategy)) ? parseint(var.placement_strategy, 10) : null
}

resource "aws_autoscaling_group" "asg" {
  name     = "${local.service}-template"
  min_size = 0
  max_size = 0

  vpc_zone_identifier = var.subnet_ids
  placement_group     = try(aws_placement_group.group[0].id, null)

  launch_template {
    id      = aws_launch_template.template.id
    version = "$Latest"
  }

  dynamic "warm_pool" {
    for_each = var.warm_pool ? [{}] : []

    content {}
  }

  health_check_type = local.asg_health_check_type

  target_group_arns = aws_lb_target_group.tg[*].id

  dynamic "tag" {
    for_each = local.asg_tag_structures

    content {
      key                 = tag.value.key
      value               = tag.value.value
      propagate_at_launch = tag.value.propagate_at_launch
    }
  }
}

data "aws_cloudwatch_log_groups" "ancillary" {
  count = var.create_logs_query ? 1 : 0

  log_group_name_prefix = "/${local.organization_prefix}/server/${local.asg_tags["Environment"]}/ancillary"
}

data "aws_cloudwatch_log_groups" "service" {
  count = var.create_logs_query ? 1 : 0

  log_group_name_prefix = "/${local.organization_prefix}/server/${local.asg_tags["Environment"]}/service/${local.asg_tags["Service"]}"
}

resource "aws_cloudwatch_query_definition" "unified-logs" {
  count = var.create_logs_query ? 1 : 0

  name = "${local.organization_prefix}/${local.asg_tags["Environment"]}/${local.asg_tags["Service"]}/UnifiedLogs"

  query_string = <<-EOT
  fields @timestamp, @message
  | parse @logStream "${local.asg_tags["Service"]}.*" as host
  | parse @log /[0-9]*:.*\/(?<group>[a-zA-Z0-9-_]+$)/
  | filter @logStream like /${local.asg_tags["Service"]}\..*/
  | sort @timestamp desc
  | display @timestamp, group, host, @message
EOT

  log_group_names = setunion(
    data.aws_cloudwatch_log_groups.ancillary[count.index].log_group_names,
    data.aws_cloudwatch_log_groups.service[count.index].log_group_names
  )
}
