// Compile the production Camera.cpp against fake MVS entry points. Enumeration
// and handle selection are exercised without loading the SDK or opening devices.
#include "Camera.cpp"
#include <algorithm>
#include <cstring>
#include <initializer_list>
#include <sstream>
#include <stdexcept>
#include <vector>

static std::vector<MV_CC_DEVICE_INFO*> enumerated;
static const MV_CC_DEVICE_INFO* opened = nullptr;
static unsigned int handleCalls = 0;
static int enumerationResult = MV_OK;

extern "C" {
int MV_CC_Initialize() { return MV_OK; }
int MV_CC_EnumDevices(unsigned int transport, MV_CC_DEVICE_INFO_LIST* list) {
    if (transport != (MV_GIGE_DEVICE | MV_USB_DEVICE)) return -1;
    list->nDeviceNum = enumerated.size();
    std::copy(enumerated.begin(), enumerated.end(), list->pDeviceInfo);
    return enumerationResult;
}
int MV_CC_CreateHandle(void** handle, const MV_CC_DEVICE_INFO* device) {
    ++handleCalls; opened = device; *handle = reinterpret_cast<void*>(1); return MV_OK;
}
int MV_CC_OpenDevice(void*, unsigned int, unsigned short) { return MV_OK; }
int MV_CC_CloseDevice(void*) { return MV_OK; }
int MV_CC_DestroyHandle(void*) { return MV_OK; }
int MV_CC_StartGrabbing(void*) { return MV_OK; }
int MV_CC_StopGrabbing(void*) { return MV_OK; }
int MV_CC_SetEnumValue(void*, const char*, unsigned int) { return MV_OK; }
int MV_CC_SetBoolValue(void*, const char*, bool) { return MV_OK; }
int MV_CC_SetFloatValue(void*, const char*, float) { return MV_OK; }
int MV_CC_GetIntValue(void*, const char*, MVCC_INTVALUE* value) { value->nCurValue = 4; return MV_OK; }
int MV_CC_GetOneFrameTimeout(void*, unsigned char*, unsigned int, MV_FRAME_OUT_INFO_EX*, unsigned int) { return -1; }
}

template <size_t N>
void set(unsigned char (&field)[N], const char* value) {
    std::memset(field, 0, N);
    std::memcpy(field, value, std::min(N, std::strlen(value)));
}

MV_CC_DEVICE_INFO camera(unsigned int transport, const char* maker, const char* serial) {
    MV_CC_DEVICE_INFO result = {};
    result.nTLayerType = transport;
    if (transport == MV_USB_DEVICE) {
        auto& info = result.SpecialInfo.stUsb3VInfo;
        set(info.chManufacturerName, maker); set(info.chSerialNumber, serial);
        set(info.chModelName, "MV-USB-HIK");
    } else if (transport == MV_GIGE_DEVICE) {
        auto& info = result.SpecialInfo.stGigEInfo;
        set(info.chManufacturerName, maker); set(info.chSerialNumber, serial);
        set(info.chModelName, "GE-CAMERA");
    }
    return result;
}

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

void check(std::initializer_list<MV_CC_DEVICE_INFO*> devices, const char* selector,
           const MV_CC_DEVICE_INFO* expected, const char* error = nullptr) {
    enumerated.assign(devices);
    opened = nullptr; handleCalls = 0;
    bool failed = false;
    std::string failure;
    try {
        CameraH actual(const_cast<char*>(selector));
        actual.start_video();
    } catch (const cv::Exception& exception) {
        failed = true; failure = exception.what();
    }
    if (expected) {
        require(!failed, failure);
        require(handleCalls == 1 && opened == expected, "wrong device passed to MV_CC_CreateHandle");
    } else {
        require(failed && handleCalls == 0, "failed selection must not open ANY camera");
        require(error && failure.find(error) != std::string::npos, "missing useful selection error: " + failure);
    }
}

int main() {
    auto mind = camera(MV_GIGE_DEVICE, "MindVision", "MIND-001");
    auto usb = camera(MV_USB_DEVICE, "Hikrobot", "USB-HIK-001");
    auto gige = camera(MV_GIGE_DEVICE, "Hangzhou Hikvision", "GE-HIK-001");
    auto otherUsb = camera(MV_USB_DEVICE, "MindVision", "USB-MIND-001");
    auto unknown = camera(MV_USB_DEVICE, "", "UNKNOWN");
    auto unsupported = camera(0xFFFFFFFF, "", "");
    auto vendorOnly = camera(MV_USB_DEVICE, "", "VENDOR-001");
    set(vendorOnly.SpecialInfo.stUsb3VInfo.chVendorName, "HIK ROBOT Co., Ltd.");

    check({&mind, &usb}, "Hikvision", &usb);
    check({&usb, &mind}, "Hikvision", &usb);
    check({&mind, &otherUsb, nullptr, &usb}, "Hikvision", &usb);
    check({&mind, &gige}, "Hikvision", &gige);
    check({&vendorOnly, &mind}, "Hikvision", &vendorOnly);
    check({&mind, &usb}, "Hikvision:USB-HIK-001", &usb);
    check({&mind, &usb}, "USB-HIK-001", &usb); // existing direct hv_init serial API
    check({&mind, &usb}, nullptr, &usb);
    check({&mind, &usb}, "", &usb);
    check({&mind}, "Hikvision", nullptr, "No Hikvision/Hikrobot");
    check({&otherUsb, &unknown, &unsupported, nullptr}, "Hikvision", nullptr, "No Hikvision/Hikrobot");
    check({}, "Hikvision", nullptr, "No Hikvision/Hikrobot");
    check({&mind, &usb}, "Hikvision:MIND-001", nullptr, "No Hikvision/Hikrobot");
    check({&mind, &usb}, "Hikvision:missing", nullptr, "No Hikvision/Hikrobot");
    check({&usb}, "Hikvision:", nullptr, "requires an exact");
    check({&gige, &usb, &mind}, "Hikvision", nullptr, "Multiple Hikvision/Hikrobot");
    check({&gige, &usb, &mind}, "Hikvision:USB-HIK-001", &usb);
    check({&gige, &usb, &mind}, "Hikvision:GE-HIK-001", &gige);

    // Full, non-NUL-terminated SDK arrays must not spill into adjacent fields.
    auto bounded = camera(MV_GIGE_DEVICE, "HIKROBOT", "1234567890ABCDEF");
    std::memset(bounded.SpecialInfo.stGigEInfo.chUserDefinedName, 'X', 16);
    check({&mind, &bounded}, "Hikvision:1234567890ABCDEF", &bounded);
    auto duplicate = usb;
    check({&usb, &duplicate}, "Hikvision:USB-HIK-001", nullptr, "Multiple Hikvision/Hikrobot");
    enumerationResult = -1;
    check({&usb}, "Hikvision", nullptr, "nRet == MV_OK");
    std::cout << "PASS: 21 mixed-vendor enumeration/selection constructor cases; no hardware or SDK runtime used" << std::endl;
}
