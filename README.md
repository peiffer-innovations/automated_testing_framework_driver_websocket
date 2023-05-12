**ARCHIVED**: This is no longer maintained to focus on other packages.

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
**Table of Contents**

- [automated_testing_framework_driver_websocket](#automated_testing_framework_driver_websocket)
  - [Table of Contents](#table-of-contents)
  - [Introduction](#introduction)
  - [App Usage](#app-usage)
  - [Example Scripts](#example-scripts)
    - [list_devices](#list_devices)
    - [run_test](#run_test)
  - [Running the Example App](#running-the-example-app)
  - [Commands](#commands)
  - [Creating Custom Commands](#creating-custom-commands)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

# automated_testing_framework_driver_websocket

## Table of Contents

* [Introduction](#introduction)
* [App Usage](#app-usage)
* [Example Scripts](#example-scripts)
    * [list_devices](#list_devices)
    * [run_test](#run_test)
* [Running the Example App](#running-the-example-app)
* [Commands](#commands)
* [Creating Custom Commands](#creating-custom-commands)

---

## Introduction 

This package provides a mechanism for running tests on remote devices in conjunction with the [Websocket Server](https://pub.dev/packages/automated_testing_framework_server_websocket).

Both the application and the server need a preshared key to authenticate the device to the server.  The key can be a key of any length that matches your preshared key security constraints.

When launched, the application will attempt to connect to the server using the givne Websocket URL.  The server and the app will mutually authenticate so that each knows the other can be trusted.

The library supports multiple built in [Commands](#commands) that can be sent via a driver script or program.  It also provides a plugin mechanism for libraries or applications to provide their own commands that can be sent and executed by a host device.

The library contains the code for both creating drivers as well as embedding the framework within the Flutter application.  The drivers can be Flutter, CLIs, or any other pure Dart setup.


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
  -d | --device [deviceId]
  -n | --driver [testDriverName]
  -s | --secret [driverSecret]
  -t | --test [path/to/test.json]
  -u | --url [websocketUrl]
```

**Options**

Full         | Short | Optional Env Var     | Description
-------------|-------|----------------------|------------
`--app`      | `-a`  | `ATF_APP_IDENTIFIER` | The `appIdentifier` the application is using.
`--device`   | `-d`  | _n/a                 | Unique device identifier.  This can be obtained from the `list_devices` script, or set in the `TestAppSettings` when the device starts the application.
`--driver`   | `-n`  | `ATF_DRIVER_NAME`    | The human readable name of the driver.
`--secret`   | `-s`  | `ATF_DRIVER_SECRET`  | The pre-shared key for the server's driver key.
`--test`     | `-t`  | _n/a_                | Path to the JSON file containing the test files.
`--url`      | `-u`  | `ATF_WEBSOCKET_URL`  | The websocket URL for the server.

**Notes**

There are three example tests included with this package that can be used to run test in the [example](example) application.  They are all located in the `assets` folder and are as such:

1. `assets/buttons.json`
2. `assets/double_tap.json`
3. `assets/dropdowns.json`


---

## Running the Example App

The fastest way to run the example is to create an `assets/config.json` file with the following data:

```json
{
  "secret": "my-preshared-secret-key",
  "url": "ws://localhost:15333"
}
```

With that configuration file, the application can connect to the back end and authenticate with the server.  When running the example app with a server and the scripts, the `app` parameter should be set to `ATF Websocket`.

As a note, Android's Emulator is unique in that it uses `localhost` to refer to the emulated device rather than the host computer.  Avoid using `localhost` for a URL when running on Android.  Instead, for Android Emulators, use the loopback IP: `10.0.2.2`.

---

## Commands

This package has a series of built in commands that it knows how to handle within the application itself:

Command Class                  | Description
-------------------------------|---------------------------------
`ReleaseDeviceCommand`         | Informs the device that the driver is no longer utilizing it, making it available for net new drivers.
`RequestScreenshotCommand`     | Requests a screenshot from the device right now.
`ReserveDeviceCommand`         | Informs the device that a driver has requested exclusive control of the device.
`RunTestCommand`               | Runs a test on the device.  In order for the device to accept this command it must first be reserved.
`StartLogStreamCommand`        | Asks the device to start streaming log events back to the driver.  In order for the device to accept this command it must first be reserved.
`StartScreenshotStreamCommand` | Asks the device to start sending screen shots repeatedly over a defined interval.  In order for the device to accept this command it must first be reserved.
`StopLogStreamCommand`         | Asks the device to stop streaming log events.
`StopScreenshotStreamCommand`  | Asks the device to stop streaming screenshots.

---

## Creating Custom Commands

An application may require custom commands to extend the functionality of the testing system.  When this is required, the application must first register the commands via the [DeviceCommand](https://pub.dev/documentation/automated_testing_framework_models/latest/automated_testing_framework_models/DeviceCommand-class.html)'s `registerCustomCommands` function.  Once commands are registered, the application can listen to the [WebSocketTestDeviceCommunicator](https://pub.dev/documentation/automated_testing_framework_driver_websocket/latest/device/WebSocketTestDeviceCommunicator-class.html)'s `commandStream` and react appropriately when a custom command comes in.

