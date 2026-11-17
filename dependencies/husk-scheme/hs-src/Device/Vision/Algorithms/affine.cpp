
#include <opencv2/opencv.hpp>

#include <string>

using namespace cv;
using namespace std;

namespace vision {

  void sinkMat(Mat input) {
    return;
  }

  std::vector<cv::Point2d> string2Point2d(std::string pointString){

    // Define a vector to store the Point2d objects
    std::vector<cv::Point2d> points;

    // Create a string stream from the pointString
    std::istringstream iss(pointString);

    std::string pointPair;
    while (std::getline(iss, pointPair, ';')) {
      // Split the point pair into individual coordinates
      std::istringstream pairIss(pointPair);
      std::string xStr, yStr;
      if (std::getline(pairIss, xStr, ',') && std::getline(pairIss, yStr, ',')) {
        // Convert coordinate strings to double values
        double x = std::stod(xStr);
        double y = std::stod(yStr);

        // Create a Point2d object and add it to the vector
        points.emplace_back(x, y);
      }
    }

    return points;
  }


}

