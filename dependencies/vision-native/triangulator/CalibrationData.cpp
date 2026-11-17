#include "CalibrationData.h"

#include <fstream>
#include <iomanip>
#include <iostream>
#include <opencv2/calib3d/calib3d.hpp>

CalibrationData::CalibrationData()
    : Kc(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0), kc(0.0), cam_error(0.0),
      Kp(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0), kp(0.0), proj_error(0.0),
      Rp(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0), Tp(0.0),
      stereo_error(0.0), frameWidth(752), frameHeight(480), screenResX(0),
      screenResY(0),
      calibrationDateTime(
          "current time:") {}

bool CalibrationData::load(const std::string &filename) {

  return loadXML(filename);

  std::cerr << "TI2CalibrationData error: no such .xml file: "
            << filename << std::endl;
  return false;
}

bool CalibrationData::save(const std::string &filename) {
  return saveXML(filename);
}

bool CalibrationData::loadXML(const std::string &filename) {
  cv::FileStorage fs(filename, cv::FileStorage::READ); //
  if (!fs.isOpened()) {
    std::cerr << "TI2CalibrationData error: could not open file "
              << filename << std::endl;
    return false;
  }

  cv::Mat temp;
  fs["Kc"] >> temp;
  Kc = temp;
  fs["kc"] >> temp;
  kc = temp;
  fs["Kp"] >> temp;
  Kp = temp;
  fs["kp"] >> temp;
  kp = temp;
  fs["Rp"] >> temp;
  Rp = temp;
  fs["Tp"] >> temp;
  Tp = temp;

  fs["cam_error"] >> cam_error;
  fs["proj_error"] >> proj_error;
  fs["stereo_error"] >> stereo_error;

  fs["frameWidth"] >> frameWidth;
  fs["frameHeight"] >> frameHeight;
  fs["screenResX"] >> screenResX;
  fs["screenResY"] >> screenResY;

  fs.release();

  return true;
}

bool CalibrationData::saveXML(const std::string &filename) {
  cv::FileStorage fs(filename, cv::FileStorage::WRITE);
  if (!fs.isOpened())
    return false;

  fs << "Kc" << cv::Mat(Kc) << "kc" << cv::Mat(kc) << "Kp" << cv::Mat(Kp)
     << "kp" << cv::Mat(kp) << "Rp" << cv::Mat(Rp) << "Tp" << cv::Mat(Tp)
     << "cam_error" << cam_error << "proj_error" << proj_error << "stereo_error"
     << stereo_error << "frameWidth" << frameWidth << "frameHeight"
     << frameHeight << "screenResX" << screenResX << "screenResY" << screenResY;
  fs.release();

  return true;
}

void CalibrationData::print(std::ostream &stream) {

  stream << "======== Sensor Calibration ========\n\n";
  stream << "Date: " << calibrationDateTime << '\n';
  stream << std::setprecision(6) << "Camera: " << '\n'
         << "\t focal length: \t[" << Kc(0, 0) << " " << Kc(1, 1) << "] "
         << "\t\t +/- [" << cam_stdint[0] << " " << cam_stdint[1] << "]" << '\n'
         << "\t central point: \t[" << Kc(0, 2) << " " << Kc(1, 2) << "] "
         << "\t\t\t +/- [" << cam_stdint[2] << " " << cam_stdint[3] << "]"
         << '\n'
         << "\t lens distortion: \t" << kc << "\t +/- [" << cam_stdint[4] << " "
         << cam_stdint[5] << " " << cam_stdint[6] << " " << cam_stdint[7] << " "
         << cam_stdint[8] << "]" << '\n'
         << "\t reprojection errors: " << '\n';
  for (unsigned int i = 0; i < cam_pve.size(); i++)
    stream << "\t\t\t" << cam_pve[i] << " px" << '\n';

  stream << "Projector: " << '\n'
         << "\t focal length: \t[" << Kp(0, 0) << " " << Kp(1, 1) << "] "
         << "\t\t +/- [" << proj_stdint[0] << " " << proj_stdint[1] << "]"
         << '\n'
         << "\t central point: \t[" << Kp(0, 2) << " " << Kp(1, 2) << "] "
         << "\t\t +/- [" << proj_stdint[2] << " " << proj_stdint[3] << "]"
         << '\n'
         << "\t lens distortion: \t" << kp << "\t +/- [" << proj_stdint[4]
         << " " << proj_stdint[5] << " " << proj_stdint[6] << " "
         << proj_stdint[7] << " " << proj_stdint[8] << "]" << '\n'
         << "\t reprojection errors: " << '\n';
  for (unsigned int i = 0; i < proj_pve.size(); i++)
    stream << "\t\t\t" << proj_pve[i] << " px" << '\n';

  stream << "Stereo Parameters: " << '\n'
         << "\t rotation: \t\t[" << Rp(0, 0) << " " << Rp(0, 1) << " "
         << Rp(0, 2) << ";\n\t\t\t" << Rp(1, 0) << " " << Rp(1, 1) << " "
         << Rp(1, 2) << ";\n\t\t\t" << Rp(2, 0) << " " << Rp(2, 1) << " "
         << Rp(2, 2) << "]" << '\n'
         << "\t translation: \t[" << Tp(0) << " " << Tp(1) << " " << Tp(2)
         << "]" << '\n'
         << "\t reprojection error: \n\t\t\t" << stereo_error << " px"
         << std::endl;
}
