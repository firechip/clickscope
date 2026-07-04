import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart' as ffi;
import 'package:dart_libusb/dart_libusb.dart';
import 'package:flusbserial/flusbserial.dart';
import 'package:flusbserial/src/models/usb_configuration.dart';
import 'package:flusbserial/src/models/usb_endpoint.dart';
import 'package:flusbserial/src/models/usb_interface.dart';
import 'package:flusbserial/src/utils/utils.dart';
import 'package:flutter/foundation.dart';

class Pl2303SerialDevice extends UsbSerialDevice {
  final Libusb _libusb = libusb;
  UsbConfiguration? configuration;
  static late final UsbInterface usbInterface;

  static const int reqTypeHostToDeviceVendor = 0x40;
  static const int reqTypeDeviceToHostVendor = 0xC0;
  static const int reqTypeHostToDevice = 0x21;

  static const int vendorWriteRequest = 0x01;
  static const int setLineCoding = 0x20;
  static const int setControlRequest = 0x22;

  static Uint8List defaultSetLine = Uint8List.fromList([
    0x80, // Baud Rate 0:3
    0x25,
    0x00,
    0x00,
    0x00, // Stop Bits 4
    0x00, // Parity 5
    0x08, // Data Bits 6
  ]);

  Pl2303SerialDevice(super.device, super.interfaceId);

  @override
  Future<void> close() async {
    _libusb.libusb_release_interface(
      deviceHandle,
      configuration!.interfaces[usbInterfaceId].id,
    );
  }

  @override
  Future<bool> open() async {
    assert(deviceHandle == nullptr, 'Last device not closed');

    var handle = _libusb.libusb_open_device_with_vid_pid(
      nullptr,
      usbDevice.vendorId,
      usbDevice.productId,
    );
    if (handle == nullptr) {
      return false;
    }

    deviceHandle = handle;

    if (UsbSerialDevice.autoDetachKernelDriverEnabled && Platform.isLinux) {
      _libusb.libusb_set_auto_detach_kernel_driver(deviceHandle, 1);
    }

    configuration = await getConfiguration(0);

    if (usbInterfaceId > 1) {
      throw Exception('Multi-interface PL2303 devices not supported');
    }

    if (_libusb.libusb_claim_interface(
          deviceHandle,
          configuration!.interfaces[usbInterfaceId].id,
        ) !=
        libusb_error.LIBUSB_SUCCESS.value) {
      return false;
    }

    usbInterface = configuration!.interfaces[usbInterfaceId];

    int numberOfEndpoints = usbInterface.endpoints.length;

    for (int i = 0; i < numberOfEndpoints; i++) {
      UsbEndpoint endpoint = usbInterface.endpoints[i];
      if (endpoint.transferType ==
              libusb_transfer_type.LIBUSB_TRANSFER_TYPE_BULK.value &&
          endpoint.direction == UsbEndpoint.directionIn) {
        inEndpoint = endpoint;
      } else if (endpoint.transferType ==
              libusb_transfer_type.LIBUSB_TRANSFER_TYPE_BULK.value &&
          endpoint.direction == UsbEndpoint.directionOut) {
        outEndpoint = endpoint;
      }
    }

    if (outEndpoint == null || inEndpoint == null) {
      return false;
    }

    Uint8List buffer = Uint8List(7);

    if (await setControlCommand(
          reqTypeDeviceToHostVendor,
          vendorWriteRequest,
          0x8484,
          0,
          buffer,
        ) <
        0) {
      return false;
    }
    if (await setControlCommand(
          reqTypeHostToDeviceVendor,
          vendorWriteRequest,
          0x0404,
          0,
          null,
        ) <
        0) {
      return false;
    }
    if (await setControlCommand(
          reqTypeDeviceToHostVendor,
          vendorWriteRequest,
          0x8484,
          0,
          buffer,
        ) <
        0) {
      return false;
    }
    if (await setControlCommand(
          reqTypeDeviceToHostVendor,
          vendorWriteRequest,
          0x8383,
          0,
          buffer,
        ) <
        0) {
      return false;
    }
    if (await setControlCommand(
          reqTypeDeviceToHostVendor,
          vendorWriteRequest,
          0x8484,
          0,
          buffer,
        ) <
        0) {
      return false;
    }
    if (await setControlCommand(
          reqTypeHostToDeviceVendor,
          vendorWriteRequest,
          0x0404,
          1,
          null,
        ) <
        0) {
      return false;
    }
    if (await setControlCommand(
          reqTypeDeviceToHostVendor,
          vendorWriteRequest,
          0x8484,
          0,
          buffer,
        ) <
        0) {
      return false;
    }
    if (await setControlCommand(
          reqTypeDeviceToHostVendor,
          vendorWriteRequest,
          0x8383,
          0,
          buffer,
        ) <
        0) {
      return false;
    }
    if (await setControlCommand(
          reqTypeHostToDeviceVendor,
          vendorWriteRequest,
          0x0000,
          1,
          null,
        ) <
        0) {
      return false;
    }
    if (await setControlCommand(
          reqTypeHostToDeviceVendor,
          vendorWriteRequest,
          0x0001,
          0,
          null,
        ) <
        0) {
      return false;
    }
    if (await setControlCommand(
          reqTypeHostToDeviceVendor,
          vendorWriteRequest,
          0x0002,
          0x0044,
          null,
        ) <
        0) {
      return false;
    }

    if (await setControlCommand(
          reqTypeHostToDevice,
          setControlRequest,
          0x0003,
          0,
          null,
        ) <
        0) {
      return false;
    }
    if (await setControlCommand(
          reqTypeHostToDevice,
          setLineCoding,
          0x0000,
          0,
          defaultSetLine,
        ) <
        0) {
      return false;
    }
    if (await setControlCommand(
          reqTypeHostToDeviceVendor,
          vendorWriteRequest,
          0x0505,
          0x1311,
          null,
        ) <
        0) {
      return false;
    }

    return true;
  }

  Future<int> setControlCommand(
    int reqType,
    int request,
    int value,
    int index,
    Uint8List? data,
  ) async {
    assert(deviceHandle != nullptr, 'Device not open');

    Pointer<UnsignedChar> ptrData = nullptr;
    int dataLength = 0;

    if (data != null && data.isNotEmpty) {
      ptrData = toPtr(data);
      dataLength = data.length;
    }

    var result = _libusb.libusb_control_transfer(
      deviceHandle,
      reqType,
      request,
      value,
      index,
      ptrData,
      dataLength,
      UsbSerialDevice.usbTimeout,
    );
    if (result < 0) {
      throw 'controlTransfer error: ${_libusb.describeError(result)}';
    }
    debugPrint('Control Transfer Response: $result');
    if (ptrData != nullptr) {
      ffi.calloc.free(ptrData);
    }
    return result;
  }

  @override
  Future<void> setBaudRate(int baudRate) async {
    Uint8List tempBuffer = Uint8List(4);
    tempBuffer[0] = (baudRate & 0xFF);
    tempBuffer[1] = ((baudRate >> 8) & 0xFF);
    tempBuffer[2] = ((baudRate >> 16) & 0xFF);
    tempBuffer[3] = ((baudRate >> 24) & 0xFF);

    if (tempBuffer[0] != defaultSetLine[0] ||
        tempBuffer[1] != defaultSetLine[1] ||
        tempBuffer[2] != defaultSetLine[2] ||
        tempBuffer[3] != defaultSetLine[3]) {
      defaultSetLine[0] = tempBuffer[0];
      defaultSetLine[1] = tempBuffer[1];
      defaultSetLine[2] = tempBuffer[2];
      defaultSetLine[3] = tempBuffer[3];
      await setControlCommand(
        reqTypeHostToDevice,
        setLineCoding,
        0x0000,
        0,
        defaultSetLine,
      );
    }
  }

  @override
  Future<void> setBreak(bool state) async {}

  @override
  Future<void> setDataBits(int dataBits) async {
    switch (dataBits) {
      case 5:
        if (defaultSetLine[6] != 0x05) {
          defaultSetLine[6] = 0x05;
          await setControlCommand(
            reqTypeHostToDevice,
            setLineCoding,
            0x0000,
            0,
            defaultSetLine,
          );
        }
        break;
      case 6:
        if (defaultSetLine[6] != 0x06) {
          defaultSetLine[6] = 0x06;
          await setControlCommand(
            reqTypeHostToDevice,
            setLineCoding,
            0x0000,
            0,
            defaultSetLine,
          );
        }
        break;
      case 7:
        if (defaultSetLine[6] != 0x07) {
          defaultSetLine[6] = 0x07;
          await setControlCommand(
            reqTypeHostToDevice,
            setLineCoding,
            0x0000,
            0,
            defaultSetLine,
          );
        }
        break;
      case 8:
        if (defaultSetLine[6] != 0x08) {
          defaultSetLine[6] = 0x08;
          await setControlCommand(
            reqTypeHostToDevice,
            setLineCoding,
            0x0000,
            0,
            defaultSetLine,
          );
        }
        break;
      default:
        break;
    }
  }

  @override
  Future<void> setDtr(bool state) async {}

  @override
  Future<void> setFlowControl(int flowControl) async {}

  @override
  Future<void> setParity(int parity) async {
    switch (parity) {
      case 0:
        if (defaultSetLine[5] != 0x00) {
          defaultSetLine[5] = 0x00;
          await setControlCommand(
            reqTypeHostToDevice,
            setLineCoding,
            0x0000,
            0,
            defaultSetLine,
          );
        }
        break;
      case 1:
        if (defaultSetLine[5] != 0x01) {
          defaultSetLine[5] = 0x01;
          await setControlCommand(
            reqTypeHostToDevice,
            setLineCoding,
            0x0000,
            0,
            defaultSetLine,
          );
        }
        break;
      case 2:
        if (defaultSetLine[5] != 0x02) {
          defaultSetLine[5] = 0x02;
          await setControlCommand(
            reqTypeHostToDevice,
            setLineCoding,
            0x0000,
            0,
            defaultSetLine,
          );
        }
        break;
      case 3:
        if (defaultSetLine[5] != 0x03) {
          defaultSetLine[5] = 0x03;
          await setControlCommand(
            reqTypeHostToDevice,
            setLineCoding,
            0x0000,
            0,
            defaultSetLine,
          );
        }
        break;
      case 4:
        if (defaultSetLine[5] != 0x04) {
          defaultSetLine[5] = 0x04;
          await setControlCommand(
            reqTypeHostToDevice,
            setLineCoding,
            0x0000,
            0,
            defaultSetLine,
          );
        }
        break;
      default:
        break;
    }
  }

  @override
  Future<void> setRts(bool state) async {}

  @override
  Future<void> setStopBits(int stopBits) async {
    switch (stopBits) {
      case 1:
        if (defaultSetLine[4] != 0x00) {
          defaultSetLine[4] = 0x00;
          await setControlCommand(
            reqTypeHostToDevice,
            setLineCoding,
            0x0000,
            0,
            defaultSetLine,
          );
        }
        break;
      case 3:
        if (defaultSetLine[4] != 0x01) {
          defaultSetLine[4] = 0x01;
          await setControlCommand(
            reqTypeHostToDevice,
            setLineCoding,
            0x0000,
            0,
            defaultSetLine,
          );
        }
        break;
      case 2:
        if (defaultSetLine[4] != 0x02) {
          defaultSetLine[4] = 0x02;
          await setControlCommand(
            reqTypeHostToDevice,
            setLineCoding,
            0x0000,
            0,
            defaultSetLine,
          );
        }
        break;
      default:
        break;
    }
  }

  Pointer<UnsignedChar> toPtr(Uint8List data) {
    final ptr = ffi.calloc<UnsignedChar>(data.length);
    final nativeList = ptr.cast<Uint8>().asTypedList(data.length);
    nativeList.setAll(0, data);
    return ptr;
  }
}
