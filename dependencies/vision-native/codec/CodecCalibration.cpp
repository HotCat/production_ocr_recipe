#include "CodecCalibration.h"
#include <math.h>

#include "cvtools.h"
#include "pstools.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Encoder

EncoderCalibration::EncoderCalibration(unsigned int _screenCols,
                                       unsigned int _screenRows, CodecDir _dir)
    : Encoder(_screenCols, _screenRows, _dir) {

  // Set N
  if (dir == CodecDirBoth)
    N = 12;
  else
    N = 6;

  // Precompute encoded patterns
  const float pi = M_PI;

  if (dir & CodecDirHorizontal) {
    // Horizontally encoding patterns
    for (unsigned int i = 0; i < 3; i++) {
      float phase = 2.0 * pi / 3.0 * i;
      float pitch = (float)screenCols / (float)16;
      cv::Mat patternI(1, 1, CV_8U);
      patternI = pstools::computePhaseVector(screenCols, phase, pitch);
      patternI = patternI.t();
      patterns.push_back(patternI);
    }

    // Phase cue patterns
    for (unsigned int i = 0; i < 3; i++) {
      float phase = 2.0 * pi / 3.0 * i;
      float pitch = screenCols;
      cv::Mat patternI;
      patternI = pstools::computePhaseVector(screenCols, phase, pitch);
      patternI = patternI.t();
      patterns.push_back(patternI);
    }
  }
  if (dir & CodecDirVertical) {
    // Precompute vertically encoding patterns
    for (unsigned int i = 0; i < 3; i++) {
      float phase = 2.0 * pi / 3.0 * i;
      float pitch = (float)screenRows / (float)16;
      cv::Mat patternI;
      patternI = pstools::computePhaseVector(screenRows, phase, pitch);
      patterns.push_back(patternI);
    }

    // Precompute vertically phase cue patterns
    for (unsigned int i = 0; i < 3; i++) {
      float phase = 2.0 * pi / 3.0 * i;
      float pitch = screenRows;
      cv::Mat patternI;
      patternI = pstools::computePhaseVector(screenRows, phase, pitch);
      patterns.push_back(patternI);
    }
  }
}

cv::Mat EncoderCalibration::getEncodingPattern(unsigned int depth) const {
  return patterns[depth];
}

// Decoder
DecoderCalibration::DecoderCalibration(unsigned int _screenCols,
                                       unsigned int _screenRows, CodecDir _dir)
    : Decoder(_screenCols, _screenRows, _dir) {

  if (dir == CodecDirBoth)
    N = 12;
  else
    N = 6;

  frames.resize(N);
}

void DecoderCalibration::setFrame(unsigned int depth, cv::Mat frame) {
  frames[depth] = frame;
}

void DecoderCalibration::decodeFrames(cv::Mat &up, cv::Mat &vp, cv::Mat &mask,
                                      cv::Mat &shading) const {

  const float pi = M_PI;

  if (dir & CodecDirHorizontal) {
    std::vector<cv::Mat> framesHorz(frames.begin(), frames.begin() + 6);

    // Horizontal decoding
    up = pstools::getPhase(framesHorz[0], framesHorz[1], framesHorz[2]);
    cv::Mat upCue =
        pstools::getPhase(framesHorz[3], framesHorz[4], framesHorz[5]);
    up = pstools::unwrapWithCue(up, upCue, 16);
    up *= screenCols / (2 * pi);
  }
  if (dir & CodecDirVertical) {
    std::vector<cv::Mat> framesVert(frames.end() - 6, frames.end());

    // Vertical decoding
    vp = pstools::getPhase(framesVert[0], framesVert[1], framesVert[2]);
    cv::Mat vpCue =
        pstools::getPhase(framesVert[3], framesVert[4], framesVert[5]);
    vp = pstools::unwrapWithCue(vp, vpCue, 16);
    vp *= screenRows / (2 * pi);
  }

  // Calculate modulation
  shading = pstools::getMagnitude(frames[0], frames[1], frames[2]);

  mask = shading > 10;

  
  // cv::Mat binary;
  // cv::threshold(shading, binary, 0, 255, cv::THRESH_BINARY_INV + cv::THRESH_OTSU);

  // std::vector<std::vector<cv::Point>> contours;
  // std::vector<cv::Vec4i> hierarchy;
  // cv::findContours(binary, contours, hierarchy, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

  // if(contours.empty()) {
  //   return;
  // }

  // size_t largestContourIndex = 0;
  // double maxArea = 0;
  // for (size_t i = 0; i < contours.size(); ++i) {
  //   double area = cv::contourArea(contours[i]);
  //   if (area > maxArea) {
  //     maxArea = area;
  //     largestContourIndex = i;
  //   }
  // }

  // // Find the convex hull of the largest contour
  // std::vector<cv::Point> hull;
  // cv::convexHull(contours[largestContourIndex], hull);

  // // Create a binary mask
  // cv::Mat mask2 = cv::Mat::zeros(shading.size(), CV_8UC1);

  // // Draw the convex hull on the binary mask
  // std::vector<std::vector<cv::Point>> hullContours = {hull};
  // cv::drawContours(mask2, hullContours, -1, cv::Scalar(255), cv::FILLED);

  // mask = mask2;
}
