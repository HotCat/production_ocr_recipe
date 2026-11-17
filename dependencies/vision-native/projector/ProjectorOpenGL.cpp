#include <GL/glew.h>

#include "ProjectorOpenGL.h"

ProjectorOpenGL::ProjectorOpenGL(unsigned int _screenNum) {

  // Create the OpenGL context
  context = new OpenGLContext(_screenNum);

  // OpenGL setup
  context->makeContextCurrent();

  glEnable(GL_TEXTURE_2D);

  glClearColor(0.0, 0.0, 0.0, 1.0);
  glClear(GL_COLOR_BUFFER_BIT);

  // Set up for 1:1 pixel mapping in the z=0 plane. Upper left corner is (0,0).
  glViewport(0, 0, context->getScreenResX(), context->getScreenResY());
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity();
  glOrtho(0, 1, 1, 0, -1, 1);
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity();

  // Set up fragment shader
  GLenum err = glewInit();
  if (err != GLEW_OK)
    std::cerr << "ProjectorOpenGL: Could not initialize GLEW!" << std::endl;

  //    const GLchar *vertexShaderSource =
  //    "void main(){\n"
  //    "    gl_Position = ftransform();\n"
  //    "}";

  //    const GLchar *fragmentShaderSource =
  //    "uniform sampler2D texture;\n"
  //    "void main(void){\n"
  //    "   gl_FragColor = texture2D(texture, gl_TexCoord[0].st);\n"
  //    "}";

  //    GLuint vertexShader = glCreateShader(GL_VERTEX_SHADER);
  //    glShaderSource(vertexShader, 1, &vertexShaderSource, NULL);
  //    glCompileShader(vertexShader);
  //    GLuint fragmentShader = glCreateShader(GL_FRAGMENT_SHADER);
  //    glShaderSource(fragmentShader, 1, &fragmentShaderSource, NULL);
  //    glCompileShader(fragmentShader);

  //    GLint status;
  //    glGetShaderiv(vertexShader, GL_COMPILE_STATUS, &status);
  //    if(status != GL_TRUE)
  //        std::cerr << "ProjectorOpenGL: Could not compile vertex shader!" <<
  //        std::endl;

  //    glGetShaderiv(fragmentShader, GL_COMPILE_STATUS, &status);
  //    if(status != GL_TRUE)
  //        std::cerr << "ProjectorOpenGL: Could not compile fragment shader!"
  //        << std::endl;

  //    int len = 0;
  //    glGetShaderiv(vertexShader, GL_INFO_LOG_LENGTH, &len);
  //    char* log = new char[len];
  //    glGetShaderInfoLog(vertexShader, len, NULL, log);
  //    std::cout << log << std::endl;

  //    glGetShaderiv(fragmentShader, GL_INFO_LOG_LENGTH, &len);
  //    glGetShaderInfoLog(fragmentShader, len, NULL, log);
  //    std::cout << log << std::endl;

  //    shaderProgram = glCreateProgram();
  //    glAttachShader(shaderProgram, vertexShader);
  //    glAttachShader(shaderProgram, fragmentShader);
  //    glLinkProgram(shaderProgram);
  //    glUseProgram(shaderProgram);

  context->flush();
}


unsigned char* generateSiemensStar(int width, int height, int numSpokes) {
    unsigned char* image = new unsigned char[width * height * 3];
    memset(image, 255, width * height * 3);  // Initialize the image to white

    float centerX = width / 2.0f;
    float centerY = height / 2.0f;
    float radius = std::min(width, height) / 2.0f;

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            float dx = x - centerX;
            float dy = y - centerY;
            float distance = std::sqrt(dx * dy + dy * dy);
            if (distance > radius) continue;

            float angle = std::atan2(dy, dx);
            if (angle < 0) angle += 2.0f * M_PI;

            int spoke = static_cast<int>(angle / (2.0f * M_PI / numSpokes));
            if (spoke % 2 == 0) {
                image[(y * width + x) * 3 + 0] = 0;  // R
                image[(y * width + x) * 3 + 1] = 0;  // G
                image[(y * width + x) * 3 + 2] = 0;  // B
            }
        }
    }

    return image;
}

void ProjectorOpenGL::setSiemens() {
  unsigned char* pattern = generateSiemensStar(912, 1140, 50);
  displayTexture(pattern, 912, 1140);
}


void ProjectorOpenGL::setPatterns(
    const std::vector<const unsigned char *> patterns,
    unsigned int patternWidth, unsigned int patternHeight) {

  context->makeContextCurrent();
  frameBuffers.clear();

  for (const auto &pattern : patterns) {

    GLuint frameBuffer;

    // Generate frame buffer object
    glGenFramebuffers(1, &frameBuffer);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, frameBuffer);
    frameBuffers.push_back(frameBuffer);

    // Generate render buffer object to store pixel data
    GLuint renderBuffer;
    glGenRenderbuffers(1, &renderBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, renderBuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, context->getScreenResX(),
                          context->getScreenResY());

    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                              GL_RENDERBUFFER, renderBuffer);

    GLint status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE)
      std::cout << "Error Framebuffer Complete" << std::endl;
    else
      std::cout << "Framebuffer Complete" << std::endl;

    // Render pattern into buffer
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, patternWidth, patternHeight, 0,
                 GL_RGB, GL_UNSIGNED_BYTE, pattern);

    glTexParameteri(GL_TEXTURE_2D, GL_GENERATE_MIPMAP, GL_FALSE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);

    float texWidthf = (float)context->getScreenResX() / patternWidth;
    float texHeightf = (float)context->getScreenResY() / patternHeight;

    glBegin(GL_QUADS);
    glTexCoord2f(0, 0);
    glVertex2i(0, 0);
    glTexCoord2f(texWidthf, 0);
    glVertex2i(1, 0);
    glTexCoord2f(texWidthf, texHeightf);
    glVertex2i(1, 1);
    glTexCoord2f(0, texHeightf);
    glVertex2i(0, 1);
    glEnd();
  }
}


std::vector<const unsigned char*> ProjectorOpenGL::remapPatterns(
    const std::vector<const unsigned char*> patterns,
    unsigned int patternWidth, unsigned int patternHeight) {

  if (patternWidth != 1824 || patternHeight != 1140) {
    std::cerr << "Error: Patterns must have dimensions 1824x1140 for proper remapping!" << std::endl;
    return {};
  }

  // Number of patterns
  const size_t nPatterns = patterns.size();

  // Prepare splash images for each pattern
  std::vector<cv::Mat_<cv::Vec3b>> splashImages(nPatterns);
  for (size_t p = 0; p < nPatterns; ++p) {
    splashImages[p] = cv::Mat_<cv::Vec3b>(PTN_HEIGHT, PTN_WIDTH); // PTN_HEIGHT=1140, PTN_WIDTH=912
  }

  // Remap each pattern independently
  for (size_t p = 0; p < nPatterns; ++p) {
    const unsigned char* pattern = patterns[p];

    for (unsigned int j = 0; j < PTN_HEIGHT; ++j) { // Rows in 912x1140
      const int jIdx = j % patternHeight;          // Map to 1824x1140 row
      for (unsigned int i = 0; i < PTN_WIDTH; ++i) { // Columns in 912x1140
        const int iIdx = (i * 2 + j % 2) % patternWidth; // Zig-zag remap
        splashImages[p](j, i) = cv::Vec3b(
            pattern[jIdx * patternWidth * 3 + iIdx * 3 + 0], // R channel
            pattern[jIdx * patternWidth * 3 + iIdx * 3 + 1], // G channel
            pattern[jIdx * patternWidth * 3 + iIdx * 3 + 2]  // B channel
        );
      }
    }
  }

  // Convert splash images into a vector of raw data pointers (const unsigned char*)
  std::vector<const unsigned char*> remappedPatternPtrs;
  for (size_t p = 0; p < nPatterns; ++p) {
    // Push the raw data pointer of each remapped splash image
    remappedPatternPtrs.push_back(splashImages[p].data);
  }

  // Write remapped patterns to BMP files
  for (size_t p = 0; p < nPatterns; ++p) {
    std::string filename = "/home/hotcat/Downloads/new3dvision/controller/1/splashImages" + std::to_string(p) + ".bmp";

    // Ensure continuity
    cv::Mat continuousImage = splashImages[p].clone();

    cv::imwrite(filename, continuousImage);
    std::cout << "Written: " << filename << std::endl;
  }

  std::cout << "All patterns remapped and written as BMP files!" << std::endl;

  // Return the vector containing the raw data pointers
  return remappedPatternPtrs;
}


// void ProjectorOpenGL::remapPatterns(
//     const std::vector<const unsigned char *> patterns,
//     unsigned int patternWidth, unsigned int patternHeight) {

//   if (patternWidth != 1824 || patternHeight != 1140) {
//     std::cerr << "Error: Patterns must have dimensions 1824x1140 for proper remapping!" << std::endl;
//     return;
//   }

//   // Number of patterns
//   const size_t nPatterns = patterns.size();

//   // Prepare splash images for each pattern
//   std::vector<cv::Mat_<cv::Vec3b>> splashImages(nPatterns);
//   for (size_t p = 0; p < nPatterns; ++p) {
//     splashImages[p] = cv::Mat_<cv::Vec3b>(PTN_HEIGHT, PTN_WIDTH); // PTN_HEIGHT=1140, PTN_WIDTH=912
//   }

//   // Remap each pattern independently
//   for (size_t p = 0; p < nPatterns; ++p) {
//     const unsigned char *pattern = patterns[p];

//     for (unsigned int j = 0; j < PTN_HEIGHT; ++j) { // Rows in 912x1140
//       const int jIdx = j % patternHeight;          // Map to 1824x1140 row
//       for (unsigned int i = 0; i < PTN_WIDTH; ++i) { // Columns in 912x1140
//         const int iIdx = (i * 2 + j % 2) % patternWidth; // Zig-zag remap
//         splashImages[p](j, i) = cv::Vec3b(
//             pattern[jIdx * patternWidth * 3 + iIdx * 3 + 0], // R channel
//             pattern[jIdx * patternWidth * 3 + iIdx * 3 + 1], // G channel
//             pattern[jIdx * patternWidth * 3 + iIdx * 3 + 2]  // B channel
//         );
//       }
//     }
//   }

//   // Write remapped patterns to BMP files
//   for (size_t p = 0; p < nPatterns; ++p) {
//     std::string filename = "/home/hotcat/Downloads/new3dvision/controller/1/splashImages" + std::to_string(p) + ".bmp";
//     cv::imwrite(filename, splashImages[p]);
//     std::cout << "Written: " << filename << std::endl;
//   }

//   std::cout << "All patterns remapped and written as BMP files!" << std::endl;
// }


// void ProjectorOpenGL::remapPatterns(
//     const std::vector<const unsigned char *> patterns,
//     unsigned int patternWidth, unsigned int patternHeight) {

//   const size_t nPatterns = patterns.size();

//   // Calculate the number of splash images required (3 patterns per splash)
//   const int nSplashImages = std::ceil(nPatterns / 3.0);

//   // Prepare storage for splash images
//   std::vector<cv::Mat_<cv::Vec3b>> splashImages(nSplashImages);
//   for (int s = 0; s < nSplashImages; ++s) {
//     splashImages[s] = cv::Mat_<cv::Vec3b>(PTN_HEIGHT, PTN_WIDTH); // 912x1140
//   }

//   // Remap patterns to splash images (1824x1140 ¡ú 912x1140)
//   for (size_t p = 0; p < nPatterns; ++p) {
//     const int s = p / 3;          // Select splash image
//     const int c = (p + 1) % 3;    // Map pattern to GRB color channel

//     for (unsigned int j = 0; j < PTN_HEIGHT; j++) { // For each row in 912x1140
//       const int jIdx = j % patternHeight;          // Map to 1824x1140 row
//       for (unsigned int i = 0; i < PTN_WIDTH; i++) { // For each column in 912x1140
//         int iIdx = (i * 2 + j % 2) % patternWidth;   // Zig-zag horizontal mapping
//         splashImages[s](j, i)[c] =
//             patterns[p][jIdx * patternWidth * 3 + iIdx * 3];
//       }
//     }
//   }

//   // Write splash images to BMP files
//   for (int s = 0; s < nSplashImages; ++s) {
//     std::vector<uchar> buf;
//     cv::imencode(".bmp", splashImages[s], buf);
//     std::string filename = "/home/hotcat/Downloads/new3dvision/controller/1/splashImages" + std::to_string(s) + ".bmp";
//     cv::imwrite(filename, splashImages[s]);

//     std::cout << "Saved splash image to: " << filename << std::endl;
//   }
// }








void ProjectorOpenGL::displayPattern(unsigned int patternNumber) {

  if (patternNumber + 1 > frameBuffers.size()) {
    std::cerr << "ProjectorOpenGL: cannot display pattern " << patternNumber
              << "! Out of bounds." << std::endl;
    return;
  }

  context->makeContextCurrent();

  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, frameBuffers[patternNumber]);

  glBlitFramebuffer(0, 0, context->getScreenResX(), context->getScreenResY(), 0,
                    0, context->getScreenResX(), context->getScreenResY(),
                    GL_COLOR_BUFFER_BIT, GL_NEAREST);

  //    glClear(GL_COLOR_BUFFER_BIT);

  // glBindTexture(GL_TEXTURE_2D, textures[patternNumber].texName);

  //    GLint locTex = glGetUniformLocation(shaderProgram, "texture");
  //    glUniform1i(locTex, 0);

  context->flush();
}

void ProjectorOpenGL::displayTexture(const unsigned char *tex,
                                     unsigned int texWidth,
                                     unsigned int texHeight) {

  context->makeContextCurrent();

  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, texWidth, texHeight, 0, GL_RGB,
               GL_UNSIGNED_BYTE, tex);

  //    glTexParameteri(GL_TEXTURE_2D, GL_GENERATE_MIPMAP, GL_FALSE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);

  float texWidthf = (float)context->getScreenResX() / texWidth;
  float texHeightf = (float)context->getScreenResY() / texHeight;

  glBegin(GL_QUADS);
  glTexCoord2f(0, 0);
  glVertex2i(0, 0);
  glTexCoord2f(texWidthf, 0);
  glVertex2i(1, 0);
  glTexCoord2f(texWidthf, texHeightf);
  glVertex2i(1, 1);
  glTexCoord2f(0, texHeightf);
  glVertex2i(0, 1);
  glEnd();

  context->flush();
}

void ProjectorOpenGL::displayBlack() {
  context->makeContextCurrent();
  glClearColor(0.0, 0.0, 0.0, 1.0);
  glClear(GL_COLOR_BUFFER_BIT);
  context->flush();
}

void ProjectorOpenGL::displayWhite() {
  context->makeContextCurrent();
  glClearColor(1.0, 1.0, 1.0, 1.0);
  glClear(GL_COLOR_BUFFER_BIT);
  context->flush();
}

void ProjectorOpenGL::getScreenRes(unsigned int *nx, unsigned int *ny) {
  *nx = context->getScreenResX() * 2;
  *ny = context->getScreenResY();
}

ProjectorOpenGL::~ProjectorOpenGL() {
  // context->makeContextCurrent();
  // delete context;
  std::cout << "delete context" << std::endl;
}


