mock_provider "aws" {
  override_data {
    target = data.aws_ec2_instance_type.instance-info
    values = {
      "supported_architectures" = ["arm64"]
    }
  }

  override_data {
    target = data.aws_iam_policy_document.allow_ec2_assume
    values = {
      "json" = "{}"
    }
  }

}
mock_provider "aws" {
  alias = "meta"

  override_data {
    target = data.aws_ssm_parameter.account-info
    values = {
      value = "{\"prefix\":\"/test\"}"
    }
  }

  override_data {
    target = data.aws_ssm_parameters_by_path.core-config
    values = {
      names = ["/test/config/core/config_backup_bucket", "/test/config/core/public_service_subnet_ids"]
      values = ["configbucket", "subnet-1234"]
    }
  }
}

variables {
  service_name = "test"
  network_level = "public"
  instance_type = "t4g.micro"
  volume_size = 2
  min_instances = 0
  max_instances = 0
}

run "no_info" {
  command = plan

  assert {
    condition = trimspace(base64decode(aws_launch_template.template.user_data)) == trimspace(file("${path.module}/tests/expected_user_data/no_info.yml"))
    error_message = "Expected\n${trimspace(file("${path.module}/tests/expected_user_data/no_info.yml"))}\ngot\n${trimspace(base64decode(aws_launch_template.template.user_data))}\n"
  }
}

run "boot_scripts" {
  command = plan

  variables {
    boot_scripts = {
      "tests/sidekiq_per_core.sh.tftpl" = { instance_count = null, service_name = "test" }
    }
  }

  assert {
    condition = trimspace(base64decode(aws_launch_template.template.user_data)) == trimspace(file("${path.module}/tests/expected_user_data/sidekiq_per_core.yml"))
    error_message = "Expected\n${trimspace(file("${path.module}/tests/expected_user_data/sidekiq_per_core.yml"))}\ngot\n${trimspace(base64decode(aws_launch_template.template.user_data))}\n"
  }
}
