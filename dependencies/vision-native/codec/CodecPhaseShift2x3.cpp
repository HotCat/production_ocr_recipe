#include "CodecPhaseShift2x3.h"
#include <math.h>

#include "cvtools.h"
#include "pstools.h"

#include <iostream>
#include <fstream>
#include <string>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Encoder

EncoderPhaseShift2x3::EncoderPhaseShift2x3(unsigned int _screenCols,
                                           unsigned int _screenRows,
                                           CodecDir _dir)
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

cv::Mat EncoderPhaseShift2x3::getEncodingPattern(unsigned int depth) const {
  return patterns[depth];
}

// Decoder
DecoderPhaseShift2x3::DecoderPhaseShift2x3(unsigned int _screenCols,
                                           unsigned int _screenRows,
                                           CodecDir _dir)
    : Decoder(_screenCols, _screenRows, _dir) {

  if (dir == CodecDirBoth)
    N = 12;
  else
    N = 6;

  frames.resize(N);
}

void DecoderPhaseShift2x3::setFrame(unsigned int depth, cv::Mat frame) {
  frames[depth] = frame;
}

void DecoderPhaseShift2x3::decodeFrames(cv::Mat &up, cv::Mat &vp, cv::Mat &mask,
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

    // cv::GaussianBlur(up, up, cv::Size(0,0), 3, 3);
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
  // cvtools::writeMat(shading, "shading.mat");
  //  Threshold modulation image for mask

  return;

  std::ifstream inputFile("/home/hotcat/Downloads/new3dvision/controller/1/shading.txt");
  if(!inputFile) {
    mask = shading > 208;
    return;
  }

  std::string line;
  if(std::getline(inputFile, line)) {
    try {
      int number = std::stoi(line);
      std::cout << "shading threshold is: " << number << std::endl;
      mask = shading > number;
      return;
    } catch (const std::invalid_argument& e) {
      mask = shading > 208;
      return;
    } catch (const std::out_of_range& e) {
      mask = shading > 208;
      return;
    }
  } else {
    mask = shading > 208;
    return;
  }

  mask = shading > 208;
  // cvtools::writeMat(mask, "mask.mat");
  //     cv::Mat edges;
  //     cv::Sobel(up, edges, -1, 1, 1, 7);
  //     edges = abs(edges) < 200;

  //    cv::Mat strel = cv::getStructuringElement(cv::MORPH_ELLIPSE,
  //    cv::Size(3,3)); cv::dilate(edges, edges, strel); strel =
  //    cv::getStructuringElement(cv::MORPH_ELLIPSE, cv::Size(6,6));
  //    cv::erode(edges, edges, cv::Mat());

  //    cv::Mat dx, dy;
  //    cv::Sobel(up, dx, -1, 1, 0, 3);
  //    cv::Sobel(up, dy, -1, 0, 1, 3);
  //    cv::Mat edges;
  //    cv::magnitude(dx, dy, edges);
  // cvtools::writeMat(edges, "edges.mat", "edges");
  //    mask = mask & (edges < 200);
  // cvtools::writeMat(mask, "mask.mat");
}
