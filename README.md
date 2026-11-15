# ios-polaris-build

Public build mirror for the private `ios-polaris` XNU kernel. It contains only
the patch series and the GitHub Actions workflow; no device images, firmware,
or personal data. Pushes to `xnu/patches/**` or manual dispatches build the
kernel on `macos-15` and upload `xnu-kernel` and `xnu-buildtree`.
