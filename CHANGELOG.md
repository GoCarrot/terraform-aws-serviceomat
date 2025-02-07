## 0.5.3

BUG FIXES:

* launch_template output no longer marked as sensitive.

## 0.5.2

ENHNACEMENTS:

* Add boot_scripts input to execute arbitrary bash scripts at server boot.
* launch_template output is now marked as sensitive.

## 0.5.1

BUG FIXES:

* Fixed path_patterns in lb_conditions

## 0.5.0

* Too many breaking changes to list.

## 0.4.6

BUG FIXES:

* Fixed path_patterns in lb_conditions

## 0.4.5

BUG FIXES:

* Fixed having a subset of possible lb_conditions.

## 0.4.4

BUG FIXES:

* Fixed having multiple lb_conditions with different types of conditions.

## 0.4.3

BUG FIXES:

* No longer implicitly disables creating another role by setting iam_instance_profile. This breaks Terraform if the role is created in the same plan or comes from a data block.

## 0.4.2

ENHANCEMENTS:

* Setting iam_instance_profile implicitly disables creating another role
* Allow using AWS provider v5.

## 0.4.1

NEW FEATURES:

* AutoScaling Group metrics are now supported.

ENHANCEMENTS:

* Created target group is now provided as an output.

## 0.4.0

NEW FEATURES:

* Services may now have multiple load balancer rules with different conditions and priorities.

BUG FIXES:

* No longer generates impossible changes to aws_placement_group when placement_strategy = "spread" and AWS provider version is >= 4.22.

BREAKING CHANGES:

* Now requires AWS provider version >= 4.22
* lb_priority variable has been removed.
* lb_conditions is now type map(object({priority=number, conditions=list(map(list(any)))}))
* Example conversion:
```
# BEFORE
lb_priority   = var.lb_priority
lb_conditions = [{
  host_headers = ["api.${var.api_host}", var.api_host]
}]

# AFTER
lb_conditions = {
  api = {
    priority   = var.lb_priority
    conditions = [{
      host_headers = ["api.${var.api_host}", var.api_host]
    }]
  }
}
```
* The destroy and recreate of lb listener rules for this migration is safe. Deployed rules are unaffected. Services with only a single entry in lb_conditions may be deployed by deployomat >= 0.2.10, services with multiple entries require deployomat >= 0.3.0.

## 0.3.4

ENHANCEMENTS:

* Prefer x86_64 over i386 for instance types which support both.

## 0.3.3

ENHANCEMENTS:

* Launch template instance tags are now sourced from the ASG tags instead of the resource tags. The main purpose for this is to allow instances to have a different set of tags than their associated IAM role.

## 0.3.2

ENHANCEMENTS:

* Make the load balancer deregistration delay configurable.

## 0.3.1

BUG FIXES:

* Do not tag spot-instances-request so ASGs can bring up instances.
* Support instance types that do not support EBS optimized.

## 0.3.0

NEW FEATURES:

* Assigns tags to instances launched directly from the launch template
* Assigns a default subnet to all launch templates
* Now requires deployomat >= 0.2.10

## 0.2.1

NEW FEATURES:

* EBS volumes of launched instances can now be encrypted by setting the `kms_key_id` input ([#1](https://github.com/GoCarrot/terraform-aws-serviceomat/pull/1))

SPECIAL THANKS:

* [@MrJoy](https://github.com/MrJoy)

## 0.2.0

BREAKING CHANGES:

* Now outputs json encoded listener_arns SSM parameter. You must update to deployomat 0.2.9 or greater before using serviceomat 0.2.0.

## 0.1.3

ENHANCEMENTS:

* Add instance_metadata_tags input to enable or disable instance tags in IMDS. Default to true (enabled).

## 0.1.2

BUG FIXES:

* Fix using http_headers in lb_conditions.

## 0.1.1

BUG FIXES:

* Resolve issue when lb_security_group_ids is set but lb_listener_arns is not.

## 0.1.0

BREAKING CHANGES:

* State keys for aws_security_group_rule.lb-ingress and aws_lb_listener_rule.listener have changed in order to support configuring a load balancer and a serviceomat instance in the same module. The moved block is insufficiently powerful to handle this automatically -- you will need to perform terraform state mv commands. It is unsafe to allow terraform to delete/create these resources for you over multiple applies as this may prevent the load balancer from being able to communicate with service instances for the duration.
* listener_arns and lb_security_group_ids are now map types instead of list types. Keys in the map must be known at plan time -- that is they should be hardcoded or at least inferrable without depending on the created source.

ENHANCEMENTS:

* Now support configuring a load balancer and serviceomat instance in the same module.

## 0.0.7

BUG FIXES:

* warm_pool = false should now correctly disable the warm pool.

## 0.0.6

ENHANCEMENTS:

* Added placement_strategy which will manage an aws_placement_group resource to influence distribution of service instances. This value defaults to "7", which will partition each AZ the service runs in into seven distinct zones with separate networks and power sources and attempt to distribute running instances evenly across partitions.

## 0.0.5

ENHANCEMENTS:

* Adjust sorting and column order for unified logs query to make it more skimmable.

## 0.0.4

FEATURES:

* Create a [CloudWatch Logs Insights Query](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_AnalyzeLogData_RunSampleQuery.html) which will search all log groups that the service can log to using the prototype LogAccess attribute based access control IAM policy. Enable this by setting `create_logs_query` to true.

ENHANCEMENTS:

* Switch to dynamic `tag` block in aws_autoscaling_group instead of deprecated `tags` attribute.

## 0.0.3

BREAKING CHANGES:

* For web services, the created target group now uses a name_prefix of the first six characters of service_name. This will require a recreating of the target group resource on updates.
* Now requires a providers = { aws.meta = provider } additional provider
* Now requires account_canonical_slug input
* Now requires the prescence of an /omat/organization_prefix parameter in the account used by the configured aws.meta provider
* No longer takes organization_prefix as an input

ENHANCEMENTS:

* Automatically provides /{prefix}/config/{service_name}/lb_listener_arns for web services
* Automatically provides /{prefix}/config/{service_name}/architecture, equal to the processor architecture of the instance type for the service
* Allows passing tags to attach to created resources other than the autoscaling group.

BUG FIXES:

* Port can now be changed.

## 0.0.2

BUG FIXES:

* Remove uses of create_before_destroy. This propagates to dependent resources and was resulting in the module attempting to create IAM roles before destroying them.

## 0.0.1

Initial release
