#pragma once

#include <iostream>
#include <sys/types.h>
#include <vector>
#include <cmath>
#include <cstring>

#include "OpenGLContext.h"
#include "Projector.h"

#include <GL/gl.h>
#include <opencv2/opencv.hpp>

#define PTN_WIDTH             912
#define PTN_HEIGHT            1140

// ProjectorOpenGL implementations
class ProjectorOpenGL : public Projector {
public:
  // Interface function
  ProjectorOpenGL(unsigned int _screenNum = 0);
  // Define preset pattern sequence and upload to GPU
  void setPatterns(const std::vector<const unsigned char *> patterns,
                   unsigned int patternWidth,
                   unsigned int patternHeight) override;
  std::vector<const unsigned char*> remapPatterns(const std::vector<const unsigned char *> patterns,
		   unsigned int patternWidth,
		   unsigned int patternHeight);
  void displayPattern(unsigned int patternNumber) override;
  void displayBlack() override;
  void displayWhite() override;
  void getScreenRes(unsigned int *nx, unsigned int *ny) override;
  bool requiresPatternUpload() override { return false; }
  void setSiemens();

  ~ProjectorOpenGL();

  void displayTexture(const unsigned char *tex, unsigned int texWidth,
                      unsigned int texHeight);

private:
  std::vector<GLuint> frameBuffers;
  OpenGLContext *context;
  GLuint shaderProgram;
};
