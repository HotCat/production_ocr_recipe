#include "Camera.hpp"

CameraM::~CameraM(){
  CameraUnInit(m_hCamera);
  free(m_pBuffer);
  std::cout << "~CameraM" << std::endl;
}

void CameraM::unInitCamera() {
  CameraUnInit(m_hCamera);
  free(m_pBuffer);
}

CameraM::CameraM(char* camera_id){
  CameraSdkInit(1);
  int i = CameraEnumerateDeviceEx();
  int status;
  tSdkCameraCapbility tCapability;
  std::cout << "Camera count:" << i << std::endl;
  CV_Assert(i > 0);
  status = CameraInitEx2(camera_id, &m_hCamera);
  CV_Assert(status == CAMERA_STATUS_SUCCESS);

  std::string camid = camera_id;

  m_patMode = false;
  m_monochrome = true;

  // CameraSetMonochrome(m_hCamera, true);

  if(camid == "GE500M") {
    m_monochrome = true;
  }

  m_timeout = 200;
  m_ngMat = cv::imread("/home/hotcat/Downloads/new3dvision/controller/ngmat.png", cv::IMREAD_UNCHANGED);
  CameraGetCapability(m_hCamera,&tCapability);

  if(m_monochrome) {
    CameraSetIspOutFormat(m_hCamera,CAMERA_MEDIA_TYPE_MONO8);
  } else {
    CameraSetIspOutFormat(m_hCamera,CAMERA_MEDIA_TYPE_RGB8);
  }

  // CameraSetFrameSpeed(m_hCamera, 1);

  m_pBuffer = (unsigned char*)malloc(tCapability.sResolutionRange.iHeightMax*tCapability.sResolutionRange.iWidthMax*3);
}

void CameraM::setProperties(std::string property_name, double property_value){
    if(property_name == "Exposure") {
      CameraSetExposureTime(m_hCamera, property_value);
    } else if(property_name == "Sharpness") {
      CameraSetSharpness(m_hCamera, (int)property_value);
    } else if(property_name == "Gamma") {
      CameraSetGamma(m_hCamera, (int)property_value);
    } else if(property_name == "Grain") {
      CameraSetAnalogGain(m_hCamera, (int)property_value);
    } else if(property_name == "Contrast") {
      CameraSetContrast(m_hCamera, (int)property_value);
    } else if(property_name == "ReverseX") {
      if (property_value == 0.0) {
          CameraSetMirror(m_hCamera, MIRROR_DIRECTION_HORIZONTAL, false);
      } else if(property_value == 1.0) {
          CameraSetMirror(m_hCamera, MIRROR_DIRECTION_HORIZONTAL, true);
      }
    } else if(property_name == "ReverseY") {
      if (property_value == 0.0) {
          CameraSetMirror(m_hCamera, MIRROR_DIRECTION_VERTICAL, false);
      } else if(property_value == 1.0) {
          CameraSetMirror(m_hCamera, MIRROR_DIRECTION_VERTICAL, true);
      }
    } else if(property_name == "PIXLE") {
      // CameraSetIspOutFormat(m_hCamera,CAMERA_MEDIA_TYPE_MONO8);
    } else if(property_name == "triggerMode") {
      if (property_value == 0.0) {
        CameraSetTriggerMode(m_hCamera, 0);
      } else if(property_value == 1.0) {
        CameraSetTriggerMode(m_hCamera, 1);
      } else if(property_value == 2.0) {
        CameraSetTriggerMode(m_hCamera, 2);
      }
    } else if(property_name == "patternMode") {

      int ipType = 0;
      CameraGetExtTrigSignalType(m_hCamera, &ipType);
      std::cout << "CameraGetExtTrigSignalType: " << ipType << std::endl;

      // CameraSetExtTrigSignalType(m_hCamera, 3);

      if (property_value == 0.0) {
        m_patMode = false;
      } else if(property_value == 1.0) {
        m_patMode = true;
      }
    } else if(property_name == "LutPreset") {
      int status;
      CameraSetLutMode(m_hCamera, LUTMODE_PRESET);
      status = CameraSelectLutPreset(m_hCamera, (int)property_value);
      std::cout << "CameraSelectLutPreset: " << status << std::endl;
    } else if(property_name == "LutGen") {
      CameraSetLutMode(m_hCamera, LUTMODE_PARAM_GEN);
      CameraSetGamma(m_hCamera, 100);
      CameraSetContrast(m_hCamera, 100);
    } else if(property_name == "Snapshot") {
      CameraSoftTrigger(m_hCamera);
    } else if(property_name == "Speed") {
      CameraSetFrameSpeed(m_hCamera, property_value);
    } else if(property_name == "GetBayer") {
      int alg;
      CameraGetBayerDecAlgorithm(m_hCamera, ISP_PROCESSSOR_PC, &alg);
      std::cout << "CameraGetBayergDecAlgorithm: " << alg << std::endl;
    } else if(property_name == "GetWbMode") {
      BOOL mode;
      CameraGetWbMode(m_hCamera, &mode);
      std::cout << "CameraGetWbMode: " << mode << std::endl;
    } else if(property_name == "SetOnceWB") {
      CameraSetOnceWB(m_hCamera);
    } else if(property_name == "SetOnceBB") {
      CameraSetOnceBB(m_hCamera);
    } else if(property_name == "SwitchResolution") {
      tSdkImageResolution resolution = {0};
      resolution.iIndex = property_value;
      CameraSetImageResolution(m_hCamera, &resolution);
    } else if(property_name == "GetNoiseFilter") {
      BOOL enable;
      CameraGetNoiseFilterState(m_hCamera, &enable);
      std::cout << "GetNoiseFilter: " << enable << std::endl;
    } else if(property_name == "SetNoiseFilter") {
      if (property_value == 0.0) {
        CameraSetNoiseFilter(m_hCamera, false);
      } else if(property_value == 1.0) {
        CameraSetNoiseFilter(m_hCamera, true);
      }
    }
    return;
}

void CameraM::closeCamera(){
  // unInitCamera();
  return;
}

void CameraM::start_video(){
  CameraPlay(m_hCamera);
  CameraSetAeState(m_hCamera, FALSE);
  // CameraSetExposureTime(m_hCamera, 10000.0);
  // CameraSetAnalogGain(m_hCamera, 2.0);
  int status;
  status = CameraSetLutMode(m_hCamera, LUTMODE_PRESET);
  // status = CameraSetLutMode(m_hCamera, LUTMODE_PARAM_GEN);
  CV_Assert(status == CAMERA_STATUS_SUCCESS);
  status = CameraSelectLutPreset(m_hCamera, 3);
  CV_Assert(status == CAMERA_STATUS_SUCCESS);

  return;
}

cv::Mat CameraM::readFrameMat(){
  tSdkFrameHead sFrameInfo;
  BYTE* pbyBuffer;
  int status;
  cv::Mat matImage2;

  if(!m_patMode) {
    status = CameraGetImageBuffer(m_hCamera,&sFrameInfo,&pbyBuffer,m_timeout);
    if (status == CAMERA_STATUS_SUCCESS) {
      m_timeout = 200;
      CameraImageProcess(m_hCamera, pbyBuffer, m_pBuffer,&sFrameInfo);
      cv::Mat matImage(cvSize(sFrameInfo.iWidth,sFrameInfo.iHeight),
                       m_monochrome?CV_8UC1:CV_8UC3,
                       m_pBuffer);
      CameraReleaseImageBuffer(m_hCamera,pbyBuffer);
      if(m_monochrome) {
        cvtColor(matImage, matImage2, cv::COLOR_GRAY2RGB);
        return matImage2;
      } else return matImage;
    }
    else {
      printf("status = %d\n", status);
      m_timeout = 20;
      cv::Mat matImage(cvSize(1280,1024),
                       CV_8UC3,
                       m_ngMat.data);
      return matImage;

      // m_timeout = 40;
      // CV_Assert(FALSE);
    }
  } else {
    cv::Mat matImage(cvSize(1280,1024),
                     CV_8UC3,
                     m_ngMat.data);
    return matImage;
  }
}


// void CameraM::captureSequence(){
//   tSdkFrameHead sFrameInfo;
//   BYTE* pbyBuffer;
//   int status;
//   cv::Mat matImage2;

//   std::vector<cv::Mat> mats;
//   mats.clear();

//   while(true) {

//     // Polling for hardware trigger mode
//     while(!m_patMode) {
//       std::this_thread::sleep_for(std::chrono::milliseconds(10)); // Poll every 10ms
//     }

//     while(true) {
//       status = CameraGetImageBuffer(m_hCamera,&sFrameInfo,&pbyBuffer,m_timeout);
//       if (status == CAMERA_STATUS_SUCCESS) {
// 	m_timeout = 200;
// 	CameraImageProcess(m_hCamera, pbyBuffer, m_pBuffer,&sFrameInfo);
// 	cv::Mat matImage(cvSize(sFrameInfo.iWidth,sFrameInfo.iHeight),
// 			 m_monochrome?CV_8UC1:CV_8UC3,
// 			 m_pBuffer);
// 	CameraReleaseImageBuffer(m_hCamera,pbyBuffer);

// 	std::cout << "readFrameMatAsync+++++++++++++" << std::endl;

// 	cvtColor(matImage, matImage2, cv::COLOR_GRAY2RGB);
// 	cv::Mat my = matImage2.clone();
// 	mats.push_back(my);
// 	if(mats.size() == 6) {
// 	  cv::imwrite("/home/hotcat/Downloads/new3dvision/controller/1/111/my1.png", mats[0]);
// 	  cv::imwrite("/home/hotcat/Downloads/new3dvision/controller/1/111/my2.png", mats[1]);
// 	  cv::imwrite("/home/hotcat/Downloads/new3dvision/controller/1/111/my3.png", mats[2]);
// 	  cv::imwrite("/home/hotcat/Downloads/new3dvision/controller/1/111/my4.png", mats[3]);
// 	  cv::imwrite("/home/hotcat/Downloads/new3dvision/controller/1/111/my5.png", mats[4]);
// 	  cv::imwrite("/home/hotcat/Downloads/new3dvision/controller/1/111/my6.png", mats[5]);
// 	  mats.clear();
// 	}

//       }

//       if(!m_patMode)
// 	break;
//     }

//   }
// }



void CameraM::captureSequence(int dir){
  tSdkFrameHead sFrameInfo;
  BYTE* pbyBuffer;
  int status;
  cv::Mat matImage2;

  std::vector<cv::Mat> mats;
  mats.clear();

  while(true) {
    status = CameraGetImageBuffer(m_hCamera,&sFrameInfo,&pbyBuffer,m_timeout);
    if (status == CAMERA_STATUS_SUCCESS) {
      m_timeout = 200;
      CameraImageProcess(m_hCamera, pbyBuffer, m_pBuffer,&sFrameInfo);
      cv::Mat matImage(cvSize(sFrameInfo.iWidth,sFrameInfo.iHeight),
                       m_monochrome?CV_8UC1:CV_8UC3,
                       m_pBuffer);
      CameraReleaseImageBuffer(m_hCamera,pbyBuffer);

      std::cout << "readFrameMatAsync+++++++++++++" << std::endl;

      cvtColor(matImage, matImage2, cv::COLOR_GRAY2RGB);
      cv::Mat my = matImage2.clone();
      mats.push_back(my);
      if(mats.size() == 12) {
        char name[256];

        for (int i = 0; i < 12; i++) {
          snprintf(name, 256, "/home/hotcat/Downloads/new3dvision/controller/1/calseq%02d/frameSeq_%02d.png", dir, i+1);
          cv::imwrite(name, mats[i]);
        }
        return;
      }
    }
  }
}


void CameraM::captureProfilo(Reconstruct &a, int thresh){
  using Clock = std::chrono::steady_clock;
  auto start = Clock::now();
  const auto timeout = std::chrono::seconds(3);

  tSdkFrameHead sFrameInfo;
  BYTE* pbyBuffer;
  int status;
  cv::Mat matImage2;

  while(true) {
    // Check elapsed time
    if(Clock::now() - start >= timeout) {
      std::cerr << "captureProfilo: timeout of 3 seconds reached" << std::endl;
      return;
    }

    status = CameraGetImageBuffer(m_hCamera,&sFrameInfo,&pbyBuffer,m_timeout);
    if (status == CAMERA_STATUS_SUCCESS) {
      m_timeout = 200;
      CameraImageProcess(m_hCamera, pbyBuffer, m_pBuffer,&sFrameInfo);
      cv::Mat matImage(cvSize(sFrameInfo.iWidth,sFrameInfo.iHeight),
                       m_monochrome?CV_8UC1:CV_8UC3,
                       m_pBuffer);
      CameraReleaseImageBuffer(m_hCamera,pbyBuffer);

      std::cout << "readFrameMatAsync+++++++++++++" << std::endl;

      cvtColor(matImage, matImage2, cv::COLOR_GRAY2RGB);
      cv::Mat my = matImage2.clone();

      int ret = a.conductProduction(my, thresh);
      if(ret == 1)
        return;
    }
  }
}


void CameraM::profiloCircle(Reconstruct &a, int thresh){
  tSdkFrameHead sFrameInfo;
  BYTE* pbyBuffer;
  int status;
  cv::Mat matImage2;

  while(true) {

    // Polling for hardware trigger mode
    while(!m_patMode) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10)); // Poll every 10ms
    }

    status = CameraGetImageBuffer(m_hCamera,&sFrameInfo,&pbyBuffer,m_timeout);
    if (status == CAMERA_STATUS_SUCCESS) {
      m_timeout = 200;
      CameraImageProcess(m_hCamera, pbyBuffer, m_pBuffer,&sFrameInfo);
      cv::Mat matImage(cvSize(sFrameInfo.iWidth,sFrameInfo.iHeight),
                       m_monochrome?CV_8UC1:CV_8UC3,
                       m_pBuffer);
      CameraReleaseImageBuffer(m_hCamera,pbyBuffer);

      std::cout << "readFrameMatAsync+++++++++++++" << std::endl;

      cvtColor(matImage, matImage2, cv::COLOR_GRAY2RGB);
      cv::Mat my = matImage2.clone();

      int ret = a.conductProduction(my, thresh);
      if(ret == 1) {
        std::cout << "one epoch complete +++++++++++++" << std::endl;
      }
    }
  }
}
