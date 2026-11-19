#ifndef PRODUCTION_OCR_HIKVISION_DEVICE_SELECTION_HPP
#define PRODUCTION_OCR_HIKVISION_DEVICE_SELECTION_HPP

#include "MvCameraControl.h"
#include <cctype>
#include <ostream>
#include <string>

namespace hikvision {

// SDK identity fields are fixed-size byte arrays, not guaranteed C strings.
// Read the union only after checking the transport type.
template <size_t N>
inline std::string identity(const unsigned char (&field)[N]) {
    size_t length = 0;
    while (length < N && field[length] != 0) ++length;
    return std::string(reinterpret_cast<const char*>(field), length);
}

inline bool isHikvision(const std::string& manufacturer) {
    std::string normalized;
    for (unsigned char c : manufacturer) {
        if (std::isalnum(c)) normalized += static_cast<char>(std::tolower(c));
    }
    return normalized.find("hikvision") != std::string::npos ||
           normalized.find("hikrobot") != std::string::npos;
}

struct DeviceIdentity {
    std::string transport, manufacturer, vendor, model, serial;
    bool supported = false;
    bool hikvision = false;
};

inline DeviceIdentity describe(const MV_CC_DEVICE_INFO& device) {
    DeviceIdentity result;
    if (device.nTLayerType == MV_USB_DEVICE) {
        const auto& usb = device.SpecialInfo.stUsb3VInfo;
        result.transport = "USB3";
        result.manufacturer = identity(usb.chManufacturerName);
        result.vendor = identity(usb.chVendorName);
        result.model = identity(usb.chModelName);
        result.serial = identity(usb.chSerialNumber);
        result.supported = true;
    } else if (device.nTLayerType == MV_GIGE_DEVICE) {
        const auto& gige = device.SpecialInfo.stGigEInfo;
        result.transport = "GigE";
        result.manufacturer = identity(gige.chManufacturerName);
        result.model = identity(gige.chModelName);
        result.serial = identity(gige.chSerialNumber);
        result.supported = true;
    } else {
        result.transport = "unsupported";
    }
    result.hikvision = result.supported &&
        (isHikvision(result.manufacturer) || isHikvision(result.vendor));
    return result;
}

// MVS enumerates third-party GigE Vision cameras too. A successful enumeration
// does not mean every entry belongs to Hikvision. Never use index zero or retry
// opening another vendor's camera when the requested device is absent/busy.
// Return a unique match; with multiple Hikvision cameras use Hikvision:SERIAL.
inline int selectDevice(const MV_CC_DEVICE_INFO_LIST& devices, const char* cameraId,
                        std::ostream& log, std::string& error) {
    std::string serial = cameraId ? cameraId : "";
    const bool automatic = serial.empty() || serial == "Hikvision" || serial == "Hikrobot";
    const std::string prefix = "Hikvision:";
    if (serial.compare(0, prefix.size(), prefix) == 0) {
        serial.erase(0, prefix.size());
        if (serial.empty()) {
            error = "Hikvision: requires an exact camera serial number";
            return -1;
        }
    }

    int selected = -1;
    unsigned int matches = 0;
    for (unsigned int i = 0; i < devices.nDeviceNum; ++i) {
        const auto* device = devices.pDeviceInfo[i];
        if (!device) continue;
        const auto info = describe(*device);
        log << "[Hikvision] MVS device " << i << ": " << info.transport
            << " manufacturer=\"" << info.manufacturer << "\" vendor=\"" << info.vendor
            << "\" model=\"" << info.model << "\" serial=\"" << info.serial << "\""
            << (info.hikvision ? " [Hikvision/Hikrobot]" : " [ignored]") << '\n';
        if (info.hikvision && (automatic || info.serial == serial)) {
            selected = static_cast<int>(i);
            ++matches;
        }
    }
    if (matches == 0) {
        error = "No Hikvision/Hikrobot USB3 or GigE camera matches '" +
                std::string(cameraId ? cameraId : "") + "'. Check the device identities above.";
        return -1;
    }
    if (matches > 1) {
        error = "Multiple Hikvision/Hikrobot cameras match. Select one using Hikvision:SERIAL in the camera setting.";
        return -1;
    }
    const auto info = describe(*devices.pDeviceInfo[selected]);
    log << "[Hikvision] Selected " << info.transport << " model=\"" << info.model
        << "\" serial=\"" << info.serial << "\"" << std::endl;
    return selected;
}

} // namespace hikvision
#endif
