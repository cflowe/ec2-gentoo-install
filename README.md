THIS IS NOT FULLY TESTED YET

In your ~/.aws/config, change [default] to [profile default].

Modify your ~/.aws/config with the following paramters:


gentoo-build-security-group
  Optional
  The security group to use. If this parameter is not set then 'gentoo-build'
  is used.

gentoo-build-use-instance
  Optional
  An ec2 instance to use as the build machine. If this is not set then a
  new instance of type gentoo-build-instance-type is created.

gentoo-build-instance-type
  Required if gentoo-build-use-instance is not set
  The instance type to create if gentoo-build-use-instance is not set.

gentoo-build-key-name
  Required
  The name to use for the ec2 key name

gentoo-build-public-keyfile
  Required if gentoo-build-use-instance is not set
  The full path to the public keyfile
  Globs or filename expansion are not supported

gentoo-build-private-keyfile
  Required
  The full path to the public keyfile
  Globs or filename expansion are not supported

gentoo-build-shutdown-after-build
  Optional
  This value is used if gentoo-build-use-instance is not set
  Either true or files


To build an Gentoo root volume:
  build.sh [profile]

Where [profile] is the name of a profile in ~/.aws/config.  if [profile] is not
given, then the default profile is used.
