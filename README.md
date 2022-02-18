# Serviceomat

Serviceomat is a module to create basic infrastructure required to deploy a service with the [Deployomat](https://registry.terraform.io/modules/GoCarrot/deployomat/aws/latest).

At a minimum it will create a template [EC2 AutoScaling Group](https://docs.aws.amazon.com/autoscaling/ec2/userguide/what-is-amazon-ec2-auto-scaling.html) and
[EC2 Launch Template](https://docs.aws.amazon.com/autoscaling/ec2/userguide/LaunchTemplates.html) suitable for Deployomat.

## Installation

This is a complete example of a minimal serviceomat setup for a service that does not receive inbound web requests.


```hcl
variable "subnet_ids" {
  description = "A list of subnets to run the service in."
  type        = list(string)
}

module "example_service" {
  source = "GoCarrot/serviceomat/aws"

  organization_prefix = "myorg"

  service_name  = "example"
  subnet_ids    = var.subnet_ids
  instance_type = "t4g.small"

  min_instances  = 1
  max_instances  = 2

  # By default serviceomat will look up and attach IAM policies named LogAccess and ConfigAccess
  # to the role it creates
  default_role_policies = []
}
```

This is will automatically provision an EC2 AutoScaling Group, an EC2 Launch Template, an IAM Role, and an IAM instance profile to attach that role to instances launched by the autoscaling group. The autoscaling group provisioned by this module will have its min_size and max_size set to 0 -- it will not boot any instances, and is intended for use as a template for Deployomat.

This is a complete example of a minimal serviceomat setup for a service that receives inbound web requests.

```hcl
variable "subnet_ids" {
  description = "A list of subnets to run the service in."
  type        = list(string)
}

variable "lb_listener_arns" {
  description = "A list of Application Load Balancer listener ARNs that this service should receive traffic from."
  type        = list(string)
}

variable "lb_security_group_ids" {
  description = "A list of security group ids attached to the load balancer."
  type        = list(string)
}

variable "lb_priority" {
  description = "The priority of this service the ALB rule list. Remember, lower == handled earlier in the pipeline."
  type        = number
}

variable "hosts" {
  description = "A list of hostnames that the service handles requests for."
  type        = list(string)
}

module "example_service" {
  source = "GoCarrot/serviceomat/aws"

  organization_prefix = "myorg"

  service_name  = "example"
  subnet_ids    = var.subnet_ids
  instance_type = "t4g.small"

  min_instances  = 1
  max_instances  = 2

  # By default serviceomat will look up and attach IAM policies named LogAccess and ConfigAccess
  # to the role it creates
  default_role_policies = []

  lb_listener_arns      = var.lb_listener_arns
  lb_security_group_ids = var.lb_security_group_ids
  lb_priority           = var.lb_priority
  lb_conditions = [{
    host_headers = var.hosts
  }]

  # By default serviceomat assumes that your web service will be listening for requests on port 80.
  # port = 80
}
```

In addition to the standard resources provisioned, this will also create a VPC Security Group permitting ingress from all lb_security_group_ids to service instances, an [Application Load Balancer Rule](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/listener-update-rules.html) suitable for Deployomat to use as a template, and a [Target Group](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-target-groups.html) suitable for Deployomat to use as a template.

Much more complex configuration is possible. This is an example of our development setup for a service which has both web frontends and background job workers.

```hcl
data "aws_ssm_parameter" "subnet_ids" {
  provider = aws.admin

  name = "${local.param_prefix}/config/core/public_service_subnet_ids"
}

data "aws_security_group" "ssh" {
  name = "AllowGlobalSSH"
}

data "aws_ssm_parameter" "lb_security_group_ids" {
  provider = aws.admin

  name = "${local.param_prefix}/config/core/lb_security_group_ids"
}

data "aws_ssm_parameter" "lb_listener_arns" {
  provider = aws.admin

  name = "${local.param_prefix}/config/core/listener_arns"
}

resource "aws_ssm_parameter" "lb_listener_arns" {
  provider = aws.admin

  name  = "${local.param_prefix}/config/${local.service}/listener_arns"
  type  = "StringList"
  value = data.aws_ssm_parameter.lb_listener_arns.value
}

data "aws_key_pair" "new-laptop" {
  key_name = "new-laptop"
}

data "aws_ssm_parameter" "ci-cd-account_id" {
  provider = aws.admin

  name = "/${var.organization_prefix}/${local.environment}/ci-cd/account_id"
}

data "aws_subnet" "exemplar" {
  id = split(",", data.aws_ssm_parameter.subnet_ids.value)[0]
}

data "aws_key_pair" "admin-key" {
  key_name = "admin-key"
}

resource "aws_security_group" "example" {
  name        = "example"
  description = "Group for tagging and allows HTTPS egress to the internet because hey."
  vpc_id      = data.aws_subnet.exemplar.vpc_id

  egress {
    from_port        = 443
    to_port          = 443
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

module "example_service" {
  source = "./modules/service_o_mat"

  service_name  = "example"
  subnet_ids    = split(",", data.aws_ssm_parameter.subnet_ids.value)
  instance_type = var.instance_type

  # This is part of a hack to allow setting the EBS volume size to lower than 8GiB, which is the
  # default volume size for Debian AMIs. We don't need that much space.
  ami_owner_id   = data.aws_ssm_parameter.ci-cd-account_id.value
  ami_name_regex = "${local.environment}_example.*"

  lb_listener_arns      = [for arn in split(",", nonsensitive(data.aws_ssm_parameter.lb_listener_arns.value)) : arn if arn != "0"]
  lb_security_group_ids = split(",", nonsensitive(data.aws_ssm_parameter.lb_security_group_ids.value))
  lb_priority           = var.lb_priority
  lb_conditions = [{
    host_headers = var.hosts
  }]

  min_instances = var.min_size
  max_instances = var.max_size

  health_check = {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 5
    timeout             = 4
    path                = "/health"
    matcher             = "200-299"
  }

  key_name = data.aws_key_pair.admin-key.key_name

  instance_security_group_ids = [data.aws_security_group.ssh.id, aws_security_group.example.id]

  user_data = <<-EOT
    ## template: jinja
    #cloud-config
    hostname: "{{ v1.availability_zone }}-{{ v1.local_hostname }}"
    bootcmd:
      - |
        systemctl enable nginx.service teak-example@1.service --now --no-block
EOT
}

module "example-sidekiq_service" {
  source = "./modules/service_o_mat"

  service_name  = "example-sidekiq"
  subnet_ids    = split(",", data.aws_ssm_parameter.subnet_ids.value)
  instance_type = var.instance_type

  ami_owner_id   = data.aws_ssm_parameter.ci-cd-account_id.value
  ami_name_regex = "${local.environment}_example.*"

  # We disable creating a role and instead reuse the instance profile created by the web service, since
  # our sidekiq and web frontends interact with the same AWS resources in the same way.
  create_role          = false
  iam_instance_profile = module.example_service.instance_profile.arn

  min_instances = var.min_size
  max_instances = var.max_size

  key_name = data.aws_key_pair.admin-key.key_name

  instance_security_group_ids = [data.aws_security_group.ssh.id, aws_security_group.example.id]

  additional_tags_for_asg_instances = {
    CostCenter = "example-sidekiq"
  }

  user_data = <<-EOT
    ## template: jinja
    #cloud-config
    hostname: "{{ v1.availability_zone }}-{{ v1.local_hostname }}"
    bootcmd:
      - |
       ${indent(5, file("${path.module}/dropins/bootcmd/sidekiq_per_core.sh"))}
    write_files:
      - path: /etc/fluent/conf.d/32_sidekiq_logs.conf
        owner: root:root
        content: |
         ${indent(5, file("${path.module}/dropins/fluentd/32_sidekiq_logs.conf"))}
        permissions: '0644'
      - path: /etc/teak-configurator/31_sidekiq.yml.conf
        owner: root:root
        content: |
         ${indent(5, file("${path.module}/dropins/teak-configurator/31_sidekiq.yml.conf"))}
EOT
}
```

All variables are well documented. Refer to the variable descriptions for additional details on how Serviceomat can be configured.
