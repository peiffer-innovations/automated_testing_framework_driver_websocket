# automated_testing_framework_driver_websocket

## Table of Contents

* [Introduction](#introduction)
* [App Usage](#app-usage)
* [Example Scripts](#example-scripts)
    * [list_devices](#list_devices)
    * [run_test](#run_test)

---

## Introduction 

Websocket based driver for the [Automated Testing Framework](https://pub.dev/packages/automated_testing_framework_driver_websocket).

This packages allows for remote control of a Flutter based application in coordination with the [Automated Testing Framework Server Websocket](https://pub.dev/packages/automated_testing_framework_server_websocket) package.


## App Usage

Within your flutter application, you will need to create and activate the automation driver.  This should typically be done at startup, but can technically be done at any point of your application.

Though, applications will default to using the package identifier, it is typically recommended to create a stable "code name" for the application to be used by the automation framework.  This is referred to as the `appIdentifier` in the framework.

```dart
// ...

void main() async {
  // ...
  TestAppSettings.initialize(appIdentifier: 'My Application Identifier');

  var navigatorKey = GlobalKey<NavigatorState>();

  var testController = TestController(
    navigatorKey: navigatorKey,
    onReset: () async {
      // your application's reset steps
    },
  );

  var communicator = WebSocketTestDeviceCommunicator(
    secret: 'my-secret-device-id-set-on-the-server',
    testControllerState: controller.state,
    url: 'wss://my-server-host/my-path',
  );
  await communicator.activate(
    () => TestDeviceInfoHelper.initialize(null),
  );
  var testDriver = TestDriver(
    communicator: communicator,
    testController: testController,
  );

  testDriver.activate();

  // ...

  runApp(MyApp(
    navigatorKey: navigatorKey,
    // ...
  ));
}
```

---

## Example Scripts

The example scripts are in the `bin` folder and can be run via:
```
dart bin/[scriptName] {options}
```

Each script utilizes optional environment variables (called the `Optional Env Var` in the documentation) that can be used as a fallback for CLI parameters.  It may be easier to set the environment variables for your test runs rather than passing them in via the CLI each time, but both modes are supported, and the CLI params always take precedence over the environment variables.

Not all paramets have a fallback parameter, and when they do not, they must be passed in via the CLI.

Script Name                 | Description
----------------------------|-------------
[list_device](#list_device) | Lists the devices that are connected to the back end server.
[run_test](#run_test)       | Runs the given test on the device and outputs the logs and screenshots to the `output` folder.


### list_devices

**Introduction**

1. Connects to the backend server.
2. Announces itself as a driver and sends a challenge to the server to prove it should be trusted.
3. Verifies the server's challenge response and if valid, responds to the server's challenge request.
4. Lists all the devices that are currently connected to the backend server and responding to commands.

**Command Reference**

```
dart bin/list_devices.dart
  -a | --app [appIdentifier]
  -n | --driver [testDriverName]
  -s | --secret [driverSecret]
  -u | --url [websocketUrl]
```

**Options**

Full         | Short | Optional Env Var     | Description
-------------|-------|----------------------|------------
`--app`      | `-a`  | `ATF_APP_IDENTIFIER` | The `appIdentifier` the application is using.
`--driver`   | `-n`  | `ATF_DRIVER_NAME`    | The human readable name of the driver.
`--secret`   | `-s`  | `ATF_DRIVER_SECRET`  | The pre-shared key for the server's driver key.
`--url`      | `-u`  | `ATF_WEBSOCKET_URL`  | The websocket URL for the server.


---

### run_test

**Introduction**

1. Connects to the backend server.
2. Announces itself as a driver and sends a challenge to the server to prove it should be trusted.
3. Verifies the server's challenge response and if valid, responds to the server's challenge request.
4. Attempts to reserve the requested device and fails if not reserved.
5. Runs the given test on the device and saves all logs and screenshots in the `output` folder.
6. Releases the device back to the availability pool.

**Command Reference**

```
dart bin/list_devices.dart
  -a | --app [appIdentifier]
  -d | --driver [testDriverName]
  -s | --secret [driverSecret]
  -t | --test [path/to/test.json]
  -u | --url [websocketUrl]
```

**Options**

Full         | Short | Optional Env Var     | Description
-------------|-------|----------------------|------------
`--app`      | `-a`  | `ATF_APP_IDENTIFIER` | The `appIdentifier` the application is using.
`--driver`   | `-d`  | `ATF_DRIVER_NAME`    | The human readable name of the driver.
`--secret`   | `-s`  | `ATF_DRIVER_SECRET`  | The pre-shared key for the server's driver key.
`--test`     | `-t`  | _n/a_                | Path to the JSON file containing the test files.
`--url`      | `-u`  | `ATF_WEBSOCKET_URL`  | The websocket URL for the server.

**Notes**

There are three example tests included with this package that can be used to run test in the [example](example) application.  They are all located in the `assets` folder and are as such:

1. `assets/buttons.json`
2. `assets/double_tap.json`
3. `assets/dropdowns.json`