## 0.0.3

BREAKING CHANGES:

* For web services, the created target group now uses a name_prefix of the first six characters of service_name. This will require a recreating of the target group resource on updates.

BUG FIXES:

* Port can now be changed.

## 0.0.2

BUG FIXES:

* Remove uses of create_before_destroy. This propagates to dependent resources and was resulting in the module attempting to create IAM roles before destroying them.

## 0.0.1

Initial release
