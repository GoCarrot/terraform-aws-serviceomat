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

output "asg" {
  description = "The AutoSclaing Group created by this module."
  value       = aws_autoscaling_group.asg
}

output "target_group" {
  description = "The Target Group created by this module, or null if var.lb_listener_arns is empty."
  value       = try(aws_lb_target_group.tg[0], null)
}

output "launch_template" {
  description = "The EC2 launch template created by this module."
  value       = aws_launch_template.template
  sensitive   = true
}

output "iam_role" {
  description = "The IAM role created by this module, or null if var.create_role is false."
  value       = try(aws_iam_role.role[0], null)
}

output "instance_profile" {
  description = "The IAM instance profile created by this module, or null if var.create_role is false."
  value       = try(aws_iam_instance_profile.instance-profile[0], null)
}

output "security_group" {
  description = "The security group created to permit ingress from the load balancer to instances. Null if the service is not behind an ALB."
  value       = try(aws_security_group.sg[0], null)
}
