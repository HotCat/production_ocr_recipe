#include "ProjectorFactory.h"

#include "ProjectorOpenGL.h"

std::unique_ptr<Projector> ProjectorFactory::NewProjector(const int screenNum) {

  if (screenNum >= 0) {
    return std::make_unique<ProjectorOpenGL>(screenNum);
  } else {
    return nullptr;
  }
}
