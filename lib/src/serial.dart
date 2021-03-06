library chrome.serial;

import 'dart:async';

import 'package:js/js.dart' as js;
import 'package:logging/logging.dart';

import 'common.dart';
import 'runtime.dart';

typedef void SerialReadCallback(String data);
typedef void SerialWriteCallback(WriteInfo writeInfo);

class OpenOptions {
  int bitrate;
  OpenOptions({this.bitrate: 9600});
  Map toMap() => { 'bitrate': this.bitrate };
}

class OpenInfo {
  int connectionId;
  OpenInfo(this.connectionId);
}

class ReadInfo {
  int bytesRead;
  var data;
  ReadInfo(this.bytesRead, this.data);
}

class WriteInfo {
  int bytesWritten;
  WriteInfo(this.bytesWritten);
}

class ControlSignalOptions {

  /**
   * Serial control signals that your machine can send.
   * Missing fields will be set to false.
   */
  bool dtr;

  /**
   * Serial control signals that your machine can receive.
   * If a get operation fails, success will be false,
   * and these fields will be absent.
   *
   * DCD (Data Carrier Detect) is equivalent to
   * RLSD (Receive Line Signal Detect) on some platforms.
   */
  bool dcd;

  /**
   * Request to Send (RTS) signal is enabled during serial communication.
   *
   * The Request to Transmit (RTS) signal is typically used in
   * Request to Send/Clear to Send (RTS/CTS) hardware handshaking.
   */
  bool rts;

  /**
   * Clear-to-Send line.
   *
   * The Clear-to-Send (CTS) line is used in Request to Send/Clear to
   * Send (RTS/CTS) hardware handshaking. The CTS line is queried
   * by a port before data is sent.
   */
  bool cts;
  ControlSignalOptions({this.dtr: false, this.dcd: false,
    this.rts: false, this.cts: false});

  ControlSignalOptions.fromMap(Map map) {
    _parseMap(map);
  }

  _parseMap(Map map) {
    this.dtr = map.containsKey('dtr') ? map['dtr'] : false;
    this.dtr = map.containsKey('dcd') ? map['dcd'] : false;
    this.dtr = map.containsKey('rts') ? map['rts'] : false;
    this.dtr = map.containsKey('cts') ? map['cts'] : false;
  }

  Map toMap() =>
      { 'dtr': this.dtr, 'dcd': this.dcd, 'rts': this.rts, 'cts': this.cts };
}

class Serial {
  Logger logger = new Logger("chrome.serial");
  OpenInfo openInfo;
  OpenOptions openOptions;

  StringBuffer _dataRead;

  final String port;
  final int speed;

  Serial(this.port, this.speed);

  /// callbacks need to check lastError
  static _safeExecute(completer, f) {
    var lastError = runtime.lastError;
    if (lastError != null) {
      completer.completeException(lastError);
      return;
    } else {
      f();
    }
  }

  static Future<List<String>> get ports {
    var completer = new Completer();

    _jsGetPorts() {
      void getPortsCallback(var result) {
        _safeExecute(completer, () {
          List ports = new List();
          for (int i = 0; i < result.length; i++) {
            ports.add(result[i]);
          }

          completer.complete(ports);
        });
      };

      jsContext.getPortsCallback = new js.Callback.once(getPortsCallback);
      var chrome = chromeProxy;
      chrome.serial.getPorts(jsContext.getPortsCallback);
    };

    js.scoped(_jsGetPorts);

    return completer.future;
  }

  bool get isConnected => openInfo != null && openInfo.connectionId >= 0;

  Future<ControlSignalOptions> getControlSignalOptions() {
    var completer = new Completer();

    _jsGetControlSignalOptions() {
      void getControlSignalOptionsCallback(var result) {
        _safeExecute(completer, () {
          var controlSignalOptions =
              new ControlSignalOptions.fromMap(convertJsonResponse(result));
          completer.complete(controlSignalOptions);
        });
      };

      jsContext.getControlSignalOptionsCallback =
          new js.Callback.once(getControlSignalOptionsCallback);
      chromeProxy.serial.getControlSignals(
          openInfo.connectionId, jsContext.getControlSignalOptionsCallback);
    };

    js.scoped(_jsGetControlSignalOptions);

    return completer.future;
  }

  Future<bool> setControlSignalOptions(ControlSignalOptions options) {
    var completer = new Completer();

    _jsSetControlSignalOptions() {
      void setControlSignalOptionsCallback(var result) {
        _safeExecute(completer, () => completer.complete(result));
      };
      jsContext.setControlSignalOptionsCallback =
          new js.Callback.once(setControlSignalOptionsCallback);
      chromeProxy.serial.setControlSignals(
          openInfo.connectionId,
          js.map(options.toMap()),
          jsContext.setControlSignalOptionsCallback);
    };

    js.scoped(_jsSetControlSignalOptions);

    return completer.future;
  }

  Future<OpenInfo> open() {
    var completer = new Completer();

    _jsOpen() {
      void openCallback(var openInfo) {
        _safeExecute(completer, () {
          logger.fine("openInfo = $openInfo");

          if (openInfo != null) {
            this.openInfo = new OpenInfo(openInfo.connectionId);
          }

          completer.complete(openInfo);
        });
      };

      jsContext.openCallback = new js.Callback.once(openCallback);
      openOptions = new OpenOptions(bitrate: speed);
      var jsOpenOptions = js.map(openOptions.toMap());
      // TODO(adam): set control options before opening, control options should
      // an optioanl parameter.
      chromeProxy.serial.open(port, jsOpenOptions, jsContext.openCallback);
    };

    js.scoped(_jsOpen);

    return completer.future;
  }

  bool startListening() {
    if (isConnected) {
      _dataRead = new StringBuffer();
      _onCharRead();
      _dataRead.clear();
      return true;
    } else {
      return false;
    }
  }

  void _onCharRead() {
    if (isConnected) {
      _jsRead() {
        void readCallback(var readInfo) {
          if (readInfo != null &&
              readInfo.bytesRead > 0 &&
              readInfo.data != null) {

            var bufView = new js.Proxy(jsContext.Uint8Array, readInfo.data);
            List chars = [];
            for (var i = 0; i < bufView.length; i++) {
              chars.add(bufView[i]);
            }

            var str = new String.fromCharCodes(chars);
            if (str.endsWith("\n")) {
              _dataRead.write(str.substring(0, str.length - 1));

              if (onRead != null) {
                onRead(_dataRead.toString());
              }

              _dataRead.clear();
            } else {
              _dataRead.write(str);
            }
          }

          chromeProxy.serial.read(
              openInfo.connectionId, 1, jsContext.readCallback);
        };

        jsContext.readCallback = new js.Callback.many(readCallback);
        chromeProxy.serial.read(
            openInfo.connectionId, 1, jsContext.readCallback);
      };

      js.scoped(_jsRead);
    } else {
      throw new StateError("Not Connected to $port $speed");
    }

  }

  Future<bool> close() {
    var completer = new Completer();

    _jsClose() {
      void closeCallback(var result) {
        _safeExecute(completer, () {
          logger.fine("closeCallback = ${result}");
          openInfo = null;
          completer.complete(result);
        });
      };

      jsContext.closeCallback = new js.Callback.once(closeCallback);
      chromeProxy.serial.close(openInfo.connectionId, jsContext.closeCallback);
    };

    js.scoped(_jsClose);

    return completer.future;
  }

  SerialWriteCallback onWrite;
  SerialReadCallback onRead;

  Future<WriteInfo> write(String data) {
    Completer completer = new Completer();

    if (isConnected) {
      _jsWrite() {
        void writeCallback(var result) {
          _safeExecute(completer, () {
            logger.fine("writeInfo = ${result}");
            var writeInfo = new WriteInfo(result.bytesWritten);

            if (onWrite != null) {
              onWrite(writeInfo);
            }

            completer.complete(writeInfo);
          });
        };

        jsContext.writeCallback = new js.Callback.once(writeCallback);

        var buf = new js.Proxy(jsContext.ArrayBuffer, data.codeUnits.length);
        var bufView = (new js.Proxy(jsContext.Uint8Array, buf) as dynamic)
            ..set(js.array(data.codeUnits));

        chromeProxy.serial.write(
            openInfo.connectionId, buf, jsContext.writeCallback);
      };

      js.scoped(_jsWrite);
    } else {
      completer.completeError(
          new StateError("Serial port not connected $port $speed"));
    }

    return completer.future;
  }

  Future<bool> flush() {
    var completer = new Completer();

    _jsFlush() {
      void flushCallback(var result) {
        _safeExecute(completer, () => completer.complete(result));
      };

      jsContext.flushCallback = new js.Callback.once(flushCallback);
      chromeProxy.serial.flush(openInfo.connectionId, jsContext.flushCallback);
    };

    js.scoped(_jsFlush);
    return completer.future;
  }
}
