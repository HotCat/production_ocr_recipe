#include "Camera.hpp"
#include "DeviceSelection.hpp"

CameraH::~CameraH(){
    closeCamera();
    free(m_pBuffer);
    free(m_pBufferT);
}

CameraH::CameraH(char* camera_id){
  static const int sdkInitResult = MV_CC_Initialize();
  CV_Assert(sdkInitResult == MV_OK);

  int nRet = MV_OK;
  MV_CC_DEVICE_INFO_LIST stDeviceList = {0};
  nRet = MV_CC_EnumDevices(MV_GIGE_DEVICE | MV_USB_DEVICE, &stDeviceList);
  CV_Assert(nRet == MV_OK);

  std::string selectionError;
  const int nIndex = hikvision::selectDevice(stDeviceList, camera_id, std::cout, selectionError);
  if (nIndex < 0) {
    CV_Error(cv::Error::StsError, selectionError);
  }

  nRet = MV_CC_CreateHandle(&m_hCamera, stDeviceList.pDeviceInfo[nIndex]);
  if(MV_OK != nRet) {
    std::cout << "MV_CC_CreateHandle failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  nRet = MV_CC_OpenDevice(m_hCamera);
  if(MV_OK != nRet) {
    std::cout << "MV_CC_OpenDevice failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  nRet = MV_CC_SetEnumValue(m_hCamera, "AcquisitionMode", MV_ACQ_MODE_CONTINUOUS);
  if (MV_OK != nRet) {
    std::cout << "MV_CC_SetAcquisitionMode failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  nRet = MV_CC_SetEnumValue(m_hCamera, "TriggerMode", 0);
  if (MV_OK != nRet) {
    std::cout << "MV_CC_SetTriggerMode failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  nRet = MV_CC_SetEnumValue(m_hCamera, "PixelFormat", 0x01080001);
  if(MV_OK != nRet) {
    std::cout << "MV_CC_SetEnumValue failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  nRet = MV_CC_SetBoolValue(m_hCamera, "GammaEnable", 1);
  if(MV_OK != nRet) {
    std::cout << "MV_CC_GammaEnable failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  nRet = MV_CC_SetEnumValue(m_hCamera, "GammaSelector", 1);
  if(MV_OK != nRet) {
    std::cout << "MV_CC_GammaSelector failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  nRet = MV_CC_SetBoolValue(m_hCamera, "DigitalShiftEnable", 1);
  if(MV_OK != nRet) {
    std::cout << "MV_CC_DigitalShiftEnable failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  nRet = MV_CC_SetEnumValue(m_hCamera, "GainAuto", 0);
  if(MV_OK != nRet) {
    std::cout << "MV_CC_SetGainAuto failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  nRet = MV_CC_SetEnumValue(m_hCamera, "ExposureAuto", 0);
  if(MV_OK != nRet) {
    std::cout << "MV_CC_SetExposureAuto failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  nRet = MV_CC_SetFloatValue(m_hCamera, "ExposureTime", 50000);
  if(MV_OK != nRet) {
    std::cout << "MV_CC_SetExposureTime failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  MVCC_INTVALUE stParam;
  memset(&stParam, 0, sizeof(MVCC_INTVALUE));
  nRet = MV_CC_GetIntValue(m_hCamera, "PayloadSize", &stParam);
  if (MV_OK != nRet) {
    std::cout << "Get PayloadSize failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  m_nDataSize = stParam.nCurValue;
  if(!m_pBuffer)
    m_pBuffer = (unsigned char *)malloc(sizeof(unsigned char) * m_nDataSize);
  if(!m_pBufferT)
    m_pBufferT = (unsigned char *)malloc(sizeof(unsigned char) * m_nDataSize);
}

void CameraH::setProperties(std::string property_name, double property_value){
  int nRet = MV_OK;
  if(property_name == "Exposure") {
    MV_CC_SetFloatValue(m_hCamera, "ExposureTime", property_value);

  } else if(property_name == "Sharpness") {
    MV_CC_SetFloatValue(m_hCamera, "Sharpness", property_value);

  } else if(property_name == "Gamma") {
    MV_CC_SetFloatValue(m_hCamera, "Gamma", property_value);

  } else if(property_name == "Grain") {
    MV_CC_SetFloatValue(m_hCamera, "Gain", property_value);

  } else if(property_name == "Contrast") {
    MV_CC_SetFloatValue(m_hCamera, "DigitalShift", property_value);

  } else if(property_name == "ReverseX") {
    if (property_value == 0.0) {
      MV_CC_SetBoolValue(m_hCamera, "ReverseX", false);
    } else if(property_value == 1.0) {
      MV_CC_SetBoolValue(m_hCamera, "ReverseX", true);
    }
  } else if(property_name == "ReverseY") {
    MV_CC_StopGrabbing(m_hCamera);
    if (property_value == 0.0) {
      nRet = MV_CC_SetBoolValue(m_hCamera, "ReverseY", false);
      if (nRet != MV_OK)
        std::cout << "ReverseY failed!" << nRet << std::endl;
    } else if(property_value == 1.0) {
      nRet = MV_CC_SetBoolValue(m_hCamera, "ReverseY", true);
      if (nRet != MV_OK)
        std::cout << "ReverseY failed!" << nRet << std::endl;
    }
    MV_CC_StartGrabbing(m_hCamera);
  } else if(property_name == "PIXLE") {

  }
  return;
}

void CameraH::closeCamera(){
  if (m_hCamera == NULL) return;
  MV_CC_StopGrabbing(m_hCamera);
  MV_CC_CloseDevice(m_hCamera);
  MV_CC_DestroyHandle(m_hCamera);
  m_hCamera = NULL;
  return;
}

void CameraH::start_video(){
  int nRet = MV_OK;

  nRet = MV_CC_StartGrabbing(m_hCamera);
  if(MV_OK != nRet) {
    std::cout << "MV_CC_StartGrabbing failed!" << nRet << std::endl;
    CV_Assert(false);
  }

  return;
}

cv::Mat CameraH::readFrameMat(){
  int nRet = MV_OK;

  MV_FRAME_OUT_INFO_EX stImageInfo = {0};
  memset(&stImageInfo, 0, sizeof(MV_FRAME_OUT_INFO_EX));

  nRet = MV_CC_GetOneFrameTimeout(m_hCamera, m_pBuffer, m_nDataSize, &stImageInfo, 1000);
  if (nRet == MV_OK) {
    // printf("Get One Frame: Width[%d], Height[%d], nFrameNum[%d]\n", stImageInfo.nWidth, stImageInfo.nHeight, stImageInfo.nFrameNum);
    ;
  } else {
    std::cout << "MV_CC_GetOneFrameTimeout failed!" << nRet << std::endl;

    MV_CC_StopGrabbing(m_hCamera);
    MV_CC_CloseDevice(m_hCamera);
    MV_CC_DestroyHandle(m_hCamera);
    m_hCamera = NULL;

    CV_Assert(false);
  }

  // MV_CC_FLIP_IMAGE_PARAM flip;
  // memset(&flip, 0, sizeof(MV_CC_FLIP_IMAGE_PARAM));
  // flip.enFlipType = MV_FLIP_VERTICAL;
  // flip.enPixelType = PixelType_Gvsp_RGB8_Packed;
  // flip.nWidth = stImageInfo.nWidth;
  // flip.nHeight = stImageInfo.nHeight;
  // flip.pSrcData = m_pBuffer;
  // flip.nSrcDataLen = m_nDataSize;
  // flip.nDstBufSize = m_nDataSize;
  // flip.pDstBuf = m_pBufferT;

  // nRet = MV_CC_FlipImage(m_hCamera, &flip);
  // if(MV_OK != nRet) {
  //   std::cout << "MV_CC_FlipImage failed!" << nRet << std::endl;
  //   CV_Assert(false);
  // }

  // cv::Mat matImage(cvSize(stImageInfo.nWidth,stImageInfo.nHeight),
  // 		       CV_8UC3,
  // 		       m_pBufferT);

  cv::Mat matImage2;
  cv::Mat matImage(cv::Size(stImageInfo.nWidth,stImageInfo.nHeight),
                       CV_8UC1,
                       m_pBuffer);

  cvtColor(matImage, matImage2, cv::COLOR_GRAY2RGB);
  return matImage2;
}
