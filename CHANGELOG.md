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
