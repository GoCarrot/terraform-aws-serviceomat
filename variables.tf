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

variable "account_canonical_slug" {
  description = "The canonical slug of the account that the service is being deployed in."
  type        = string
}

variable "service_name" {
  description = "The name of the service."
  type        = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "A list of subnet ids that service servers may run in. Must all be in the same VPC."

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "At least one subnet_id must be specified for the service."
  }
}

variable "instance_type" {
  description = "The EC2 instance type to use for this service."
  type        = string
}

variable "instance_security_group_ids" {
  type        = list(string)
  description = "List of additional security groups to attach to service instances."
  default     = []
}

variable "volume_size" {
  type        = number
  description = "The size of the root volume for service instances in GiB. If this is smaller than the size of the root volume for the AMI, will be increased to the size of the root volume for the AMI."
  default     = 2
}

variable "detailed_instance_monitoring" {
  type        = bool
  description = "Use detailed instance monitoring (1m interval) on service instances."
  default     = true
}

variable "min_instances" {
  description = "The minimum number of instances to run."
  type        = number
}

variable "max_instances" {
  description = "The maximum number of instances to run."
  type        = number
}

variable "ami_name_regex" {
  type        = string
  description = "Regex for the name of an AMI to look up to use as the default AMI for the launch template. If not specified, or not found, will use an appropriate official Debian 11 AMI."
  default     = null
}

variable "ami_owner_id" {
  type        = string
  description = "Owner of the AMI to look up with ami_name_regex, e.g. your CI/CD account id."
  default     = null
}

variable "lb_listener_arns" {
  type        = list(string)
  description = "List of ARNs for ALB listeners to receive traffic from. If empty, this service will not be configured to receive web traffic from an ALB."
  default     = []
}

variable "lb_security_group_ids" {
  type        = list(string)
  description = "List of security groups attached to an ALB. If lb_listener_arns is non-empty, this module will create a security group which permits ingress on var.port from all security groups here."
  default     = []
}

variable "port" {
  type        = number
  default     = 80
  description = "The port the service runs on. Only used if the service is receiving web traffic from an ALB."
}

variable "protocol" {
  type        = string
  default     = "HTTP"
  description = "The protocol the service speaks. Set to HTTPS for end to end SSL. Only used if the service is receiving web traffic from an ALB."
}

variable "health_check" {
  type        = map(any)
  description = <<-EOT
The health check configuration for the target group. Unspecified parameters will get terraform defaults as of AWS provider 4.1.0.
Refer to https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group#health_check."
Only used if the service is receiving web traffic from an ALB.
EOT

  default = {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 5
    timeout             = 4
    matcher             = "200-299"
    path                = "/"
    port                = "traffic-port"
  }
}

variable "load_balancing_algorithm_type" {
  type        = string
  description = <<-EOT
  Determines how the load balancer selects targets when routing requests.  Only used if the service is receiving web traffic from an ALB.
  See https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group#load_balancing_algorithm_type
EOT
  default     = "round_robin"
}

variable "lb_conditions" {
  type        = list(map(list(any)))
  description = <<-EOT
The conditions under which a request should be routed from the LB to this service.
Only used if the service is receiving web traffic from an ALB.
Refer to https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener_rule#condition-blocks
This is structured as a map, an example for host headers would be
[{
  host_headers = ["example.com", "*.example.com"]
}].

The query_strings and http_headers types are more complex.
[{
  http_headers = [
    {
      http_header_name = "StupidSecretAuth"
      values           = ["Password", "12345"]
    },
    {
      http_header_name = "Service"
      values           = ["Example"]
    }
  ]

  query_strings = [
    {
      key   = "myquery"
      value = "hasavalue"
    }
  ]
}]
EOT
  default     = []
}

variable "attach_default_tags_to_asg_instances" {
  type        = bool
  description = "When true, will read default tags off of the AWS provider and propogate them to EC2 instances managed by the AutoScaling Group."
  default     = true
}

variable "additional_tags_for_asg_instances" {
  type        = map(string)
  description = <<-EOT
  Map of additional tags to propogate to EC2 instances managed by the AutoSclaing Group. If attach_default_tags_to_asg_instances is
  true, tags specified here will override default tags in the event of a conflict.
  EOT
  default     = {}
}

variable "tags" {
  type        = map(string)
  description = <<-EOT
  Tags to attach to created sources. WILL NOT BE ATTACHED TO ASG INSTANCES. Use additional_tags_for_asg_instances to
  control tags assigned to ASG instances. Tags here will override default tags in the event of a conflict.
  EOT
  default     = {}
}

variable "warm_pool" {
  type        = bool
  description = "Allow the ASG to create a warm pool with default configuration."
  default     = true
}

variable "lb_priority" {
  description = "The rule priority for this service in the primary load balancer. Required if lb_listener_arns is specified."
  type        = number
  default     = 51000
}

variable "health_check_type" {
  type        = string
  description = "See https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group#health_check_type. If null, will default to ELB when lb_listener_arns is non-empty."
  default     = null
}

variable "key_name" {
  type        = string
  description = "Name of an AWS key pair to associate with launched instances."
  default     = null
}

variable "user_data" {
  type        = string
  description = "NOT BASE64 ENCODED userdata to supply to launched instances."
  default     = ""
}

variable "create_role" {
  type        = bool
  description = "If true creates a role to associate with launched instances. Ignored if iam_instance_profile is set."
  default     = true
}

variable "default_role_policies" {
  type        = list(string)
  description = "A list of IAM policies to attach to the created role."
  default     = ["LogAccess", "ConfigAccess"]
}

variable "iam_instance_profile" {
  type        = string
  description = "ARN of an IAM Instance Profile to associate with launched instances."
  default     = null
}
