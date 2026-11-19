#include "Camera.hpp"

CameraV::~CameraV(){
  std::cout << "~CameraV" << std::endl;
}

CameraV::CameraV(char* camera_id){
  // m_ngMat = cv::imread("/home/hotcat/Downloads/new3dvision/controller/ngmat.png", cv::IMREAD_UNCHANGED);
  // m_ngMat = cv::imread("/home/hotcat/Downloads/new3dvision/myplys/barcode.jpg", cv::IMREAD_UNCHANGED);
  m_ngMat = cv::imread("/home/hotcat/Downloads/sam2/notebooks/segsample3.jpg", cv::IMREAD_UNCHANGED);
}

void CameraV::setProperties(std::string property_name, double property_value){
  return;
}

void CameraV::closeCamera(){
  return;
}

cv::Mat CameraV::readFrameMat(){
  cv::Mat matImage(cvSize(1280,1024),
                   CV_8UC3,
                   m_ngMat.data);
  return matImage;
}
