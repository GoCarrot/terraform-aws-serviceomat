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
