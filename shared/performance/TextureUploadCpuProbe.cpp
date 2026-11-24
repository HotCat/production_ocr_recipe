// Camera/PLC-free benchmark of the actual RGB upload operations used by clients.
// Compare unused mipmap generation with base-level uploads at identical FPS.
#include <GL/glew.h>
#include <GLFW/glfw3.h>
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <vector>
#include <sys/resource.h>

static double cpuSeconds() {
    rusage usage{};
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6
         + usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}

int main(int argc, char** argv) {
    const std::string mode = argc > 1 ? argv[1] : "legacy";
    if (mode != "legacy" && mode != "base" && mode != "reuse")
        throw std::invalid_argument("expected legacy, base or reuse");
    if (!glfwInit()) throw std::runtime_error("GLFW initialization failed");
    glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);
    auto* window = glfwCreateWindow(640, 480, "OCR texture benchmark", nullptr, nullptr);
    if (!window) throw std::runtime_error("OpenGL context creation failed");
    glfwMakeContextCurrent(window);
    if (glewInit() != GLEW_OK) throw std::runtime_error("GLEW initialization failed");
    while (glGetError() != GL_NO_ERROR) {}
    std::cout << "mode=" << mode << " renderer=" << glGetString(GL_RENDERER) << '\n';
    cv::setNumThreads(1);
    cv::Mat rgb(1024, 1280, CV_8UC3), flipped;
    cv::randu(rgb, 0, 255);
    GLuint texture;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, rgb.cols, rgb.rows, 0, GL_RGB, GL_UNSIGNED_BYTE, nullptr);
    const auto begin = std::chrono::steady_clock::now();
    const auto cpuBegin = cpuSeconds();
    unsigned count = 0;
    for (; std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count() < 4; ++count) {
        cv::flip(rgb, flipped, 0);
        if (mode == "reuse")
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, rgb.cols, rgb.rows, GL_RGB, GL_UNSIGNED_BYTE, flipped.data);
        else
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, rgb.cols, rgb.rows, 0, GL_RGB, GL_UNSIGNED_BYTE, flipped.data);
        if (mode == "legacy") glGenerateMipmap(GL_TEXTURE_2D);
        glFinish(); // Include driver workers rather than timing queued commands.
        std::this_thread::sleep_until(begin + std::chrono::nanoseconds(
            (static_cast<std::int64_t>(count) + 1) * 1000000000 / 60));
    }
    const auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
    const auto cpu = cpuSeconds() - cpuBegin;
    std::vector<unsigned char> pixels(rgb.total() * rgb.elemSize());
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RGB, GL_UNSIGNED_BYTE, pixels.data());
    if (glGetError() != GL_NO_ERROR) throw std::runtime_error("OpenGL upload/readback failed");
    if (!std::equal(pixels.begin(), pixels.end(), flipped.data))
        throw std::runtime_error("uploaded base-level pixels changed");
    std::uint64_t hash = 14695981039346656037ULL;
    for (auto pixel : pixels) { hash ^= pixel; hash *= 1099511628211ULL; }
    std::cout << "frames=" << count << " fps=" << count / elapsed
              << " cpu_pct=" << 100 * cpu / elapsed << " pixels_hash=" << hash << '\n';
    glDeleteTextures(1, &texture);
    glfwDestroyWindow(window);
    glfwTerminate();
}
