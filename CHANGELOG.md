## 0.0.2

BUG FIXES:

* Remove uses of create_before_destroy. This propagates to dependent resources and was resulting in the module attempting to create IAM roles before destroying them.

## 0.0.1

Initial release
