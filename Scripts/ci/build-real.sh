#!/bin/bash

xcodebuild clean build-for-testing \
  -project WebDriverAgent.xcodeproj \
  -derivedDataPath $DERIVED_DATA_PATH \
  -scheme $SCHEME \
  -destination "$DESTINATION" \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64

# The Tunnel scheme builds the same WebDriverAgentRunner-Runner.app as the
# plain scheme, so the app name can differ from the scheme name.
APP_NAME="${APP_NAME:-$SCHEME-Runner.app}"

pushd $WD

# The reason why here excludes several frameworks are:
# - to remove test packages to refer to the device local instead of embedded ones
#   XCTAutomationSupport.framework, XCTest.framewor, XCTestCore.framework,
#   XCUIAutomation.framework, XCUnit.framework.
#   This can be excluded only for real devices.
# - Xcode 16 started generating 5.9MB of 'Testing.framework', but it might not be necessary for WDA.
# - libXCTestSwiftSupport is used for Swift testing. WDA doesn't include Swift stuff, thus this is not needed.
zip -r $ZIP_PKG_NAME $APP_NAME \
    -x "$APP_NAME/Frameworks/XC*.framework*" \
       "$APP_NAME/Frameworks/Testing.framework*" \
       "$APP_NAME/Frameworks/libXCTestSwiftSupport.dylib"
popd
mv $WD/$ZIP_PKG_NAME ./
