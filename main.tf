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
      version = ">= 4.22, < 6"

      configuration_aliases = [aws.meta]
    }
  }
}

terraform {
  required_version = ">= 1.3.0"
}

data "aws_default_tags" "tags" {}
data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "account-info" {
  provider = aws.meta

  name = "/omat/account_id_registry/${data.aws_caller_identity.current.account_id}"
}

# I tried to get rid of this by reading the prefix from the
# account-info param and getting the first component, but it caused
# terraform to error in a bizarre way in cases where a downstream service
# on an earlier version relied on one of our outputs (other cases not tested).
data "aws_ssm_parameter" "organization-prefix" {
  provider = aws.meta

  name = "/omat/organization_prefix"
}

data "aws_ssm_parameters_by_path" "core-config" {
  provider = aws.meta

  path      = local.core_config_prefix
  recursive = true
}

locals {
  setup_lb = length(local.conditions) > 0
  service  = join("-", compact([var.service_name, var.component_name]))

  listeners = [
    for key, value in local.lb_listener_arns : {
      key   = key
      value = value
    }
  ]

  conditions = [for key, value in var.lb_conditions : {
    key   = key
    value = value
  }]

  rule_setups = {
    for pair in setproduct(local.listeners, local.conditions) :
    "${pair[0].key}-${pair[1].key}" => {
      listener_arn = pair[0].value
      priority     = pair[1].value.priority
      conditions   = pair[1].value.conditions
    }
  }

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
  param_prefix        = local.account_info["prefix"]
  organization_prefix = nonsensitive(data.aws_ssm_parameter.organization-prefix.value)
  core_config_prefix  = "${local.param_prefix}/config/core"
  network_level       = var.network_level

  always_required_config = ["config_backup_bucket", "${local.network_level}_service_subnet_ids"]
  web_required_config    = ["lb_security_group_ids", "listener_arns"]
  mandatory_config       = local.setup_lb ? concat(local.always_required_config, local.web_required_config) : local.always_required_config
  core_config = {
    for config in local.mandatory_config : config => nonsensitive(data.aws_ssm_parameters_by_path.core-config.values[index(data.aws_ssm_parameters_by_path.core-config.names, "${local.core_config_prefix}/${config}")])
  }

  subnet_ids            = coalescelist(var.subnet_ids, split(",", local.core_config["${var.network_level}_service_subnet_ids"]))
  lb_security_group_ids = coalesce(var.lb_security_group_ids, jsondecode(lookup(local.core_config, "lb_security_group_ids", "{}")))
  lb_listener_arns      = coalesce(var.lb_listener_arns, jsondecode(lookup(local.core_config, "listener_arns", "{}")))
  config_backup_bucket  = local.core_config["config_backup_bucket"]

  module_dropins = {
    "/etc/teak-configurator/30_fallbacks.yml.conf" = { bucket = local.config_backup_bucket }
  }

  module_files = [for dropin_path, template_vars in local.module_dropins :
    {
      path    = dropin_path,
      content = length(template_vars) > 0 ? templatefile("${path.module}/dropins/${dropin_path}", template_vars) : file("${path.module}/dropins/${dropin_path}")
    }
  ]

  files = concat(
    local.module_files,
    [for dropin_path, template_vars in var.dropins :
      {
        path    = dropin_path,
        content = length(template_vars) > 0 ? templatefile("${path.root}/dropins/${dropin_path}", template_vars) : file("${path.root}/dropins/${dropin_path}")
      }
    ]
  )

  bootfiles = [for dropin_path, template_vars in var.boot_scripts :
    indent(5, length(template_vars) > 0 ? templatefile("${path.root}/dropins/${dropin_path}", template_vars) : file("${path.root}/dropins/${dropin_path}"))
  ]

  hostname_template = join("-", compact([var.component_name, "{{ v1.availability_zone }}", "{{ v1.local_hostname }}"]))
  runcmds           = length(var.firstboot_services) > 0 ? ["systemctl start ${join(" ", formatlist("%s.service", var.firstboot_services))} --no-block"] : []
  bootcmds          = concat(length(local.bootfiles) > 0 ? local.bootfiles : [], length(var.enabled_services) > 0 ? ["systemctl enable ${join(" ", formatlist("%s.service", var.enabled_services))} --now --no-block"] : [])
  packages          = var.packages
  default_user_data = templatefile(
    "${path.module}/templates/user_data.yml.tftpl",
    {
      write_files       = local.files
      runcmds           = local.runcmds
      packages          = local.packages
      hostname_template = local.hostname_template
      bootcmds          = local.bootcmds
    }
  )
  user_data = coalesce(var.user_data, local.default_user_data)
}

data "aws_subnet" "exemplar" {
  id = local.subnet_ids[0]
}

resource "aws_security_group" "sg" {
  count = local.setup_lb ? 1 : 0

  name        = "${local.service}-allow_lb"
  description = "Allows traffic from the load balancer to ${local.service}"
  vpc_id      = data.aws_subnet.exemplar.vpc_id

  tags = local.tags
}

resource "aws_security_group_rule" "lb-ingress" {
  for_each = local.setup_lb ? local.lb_security_group_ids : {}

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

  deregistration_delay = var.lb_deregistration_delay

  health_check {
    enabled             = var.health_check["enabled"]
    healthy_threshold   = var.health_check["healthy_threshold"]
    unhealthy_threshold = var.health_check["unhealthy_threshold"]
    interval            = var.health_check["interval"]
    timeout             = var.health_check["timeout"]
    matcher             = var.health_check["matcher"]
    path                = var.health_check["path"]
    port                = var.health_check["port"]
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "listener" {
  for_each = local.setup_lb ? local.rule_setups : {}

  listener_arn = each.value.listener_arn
  priority     = each.value.priority + 40000

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg[0].arn
  }

  dynamic "condition" {
    for_each = [
      for condition_rule in each.value.conditions : condition_rule if length(coalesce(lookup(condition_rule, "host_headers", []), [])) > 0
    ]

    content {
      host_header {
        values = condition.value["host_headers"]
      }
    }
  }

  dynamic "condition" {
    for_each = [
      for condition_rule in each.value.conditions : condition_rule if length(coalesce(lookup(condition_rule, "http_headers", []), [])) > 0
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
      for condition_rule in each.value.conditions : condition_rule if length(coalesce(lookup(condition_rule, "http_request_methods", []), [])) > 0
    ]

    content {
      http_request_method {
        values = condition.value["http_request_methods"]
      }
    }
  }

  dynamic "condition" {
    for_each = [
      for condition_rule in each.value.conditions : condition_rule if length(coalesce(lookup(condition_rule, "path_patterns", []), [])) > 0
    ]

    content {
      path_pattern {
        values = condition.value["path_patterns"]
      }
    }
  }

  dynamic "condition" {
    for_each = [
      for condition_rule in each.value.conditions : condition_rule if length(coalesce(lookup(condition_rule, "query_strings", []), [])) > 0
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
      for condition_rule in each.value.conditions : condition_rule if length(coalesce(lookup(condition_rule, "source_ips", []), [])) > 0
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
  value = jsonencode(local.lb_listener_arns)

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
  instance_arch = data.aws_ec2_instance_type.instance-info.supported_architectures[length(data.aws_ec2_instance_type.instance-info.supported_architectures) - 1]
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
  default_ami_id = coalescelist(try(data.aws_ami_ids.built-ami[0].ids, []), [nonsensitive(data.aws_ssm_parameter.stub-ami[local.instance_arch].value)])[0]
}

data "aws_ami" "default-ami" {
  # See https://wiki.debian.org/Cloud/AmazonEC2Image/Bullseye
  owners = compact(["136693071363", var.ami_owner_id])

  filter {
    name   = "image-id"
    values = [local.default_ami_id]
  }
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
  subnet_randomizer    = { for id in local.subnet_ids : sha256("${local.service}-${id}") => id }
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
      volume_size           = var.volume_size
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
    ignore_changes = [image_id]
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
    subnet_id       = local.subnet
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
      tags          = { for key, value in local.asg_tags : key => value if key != "Managed" }
    }
  }

  user_data = local.user_data != null && length(local.user_data) > 0 ? base64encode(local.user_data) : ""

  tags = local.tags
}

resource "aws_placement_group" "group" {
  count = var.placement_strategy != null ? 1 : 0

  name            = "${local.service}-placement"
  strategy        = can(regex("^[1-7]$", var.placement_strategy)) ? "partition" : var.placement_strategy
  partition_count = can(regex("^[1-7]$", var.placement_strategy)) ? parseint(var.placement_strategy, 10) : null
  spread_level    = var.placement_strategy == "spread" ? "rack" : null
}

resource "aws_autoscaling_group" "asg" {
  name     = "${local.service}-template"
  min_size = 0
  max_size = 0

  vpc_zone_identifier = local.subnet_ids
  placement_group     = try(aws_placement_group.group[0].id, null)
  enabled_metrics     = var.asg_metrics

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
