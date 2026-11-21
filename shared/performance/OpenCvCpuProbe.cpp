// Reproduce the live capture/ROI transforms using the same system OpenCV.
// No camera, GUI, PLC, Haskell runtime, or OCR service is involved.
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <sys/resource.h>

static double cpuSeconds() {
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6
         + usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}

int main(int argc, char** argv) {
    const int threads = argc > 1 ? std::stoi(argv[1]) : -1;
    const int fps = argc > 2 ? std::stoi(argv[2]) : 30;
    if (threads < -1 || threads > 16 || threads == 0 || fps < 0 || fps > 1000)
        throw std::invalid_argument("threads must be -1 or 1..16; fps must be 0..1000");
    cv::setNumThreads(threads);
    const std::string info = cv::getBuildInformation();
    const auto backend = info.find("Parallel framework:");
    std::cout << "opencv_threads=" << cv::getNumThreads() << " "
              << info.substr(backend, info.find('\n', backend) - backend) << '\n';
    cv::Mat gray(1024, 1280, CV_8UC1);
    cv::randu(gray, 0, 255);
    cv::Mat rgb, flipped, bgr, crop, out;
    const auto begin = std::chrono::steady_clock::now();
    const double cpuBegin = cpuSeconds();
    unsigned count = 0;
    for (; std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count() < 4; ++count) {
        // CameraH::readFrameMat expands grayscale to RGB. The region pipelines
        // then flip and swap channels on the entire frame before cropping.
        cv::cvtColor(gray, rgb, cv::COLOR_GRAY2RGB);
        cv::flip(rgb, flipped, 0);
        cv::cvtColor(flipped, bgr, cv::COLOR_RGB2BGR);
        crop = bgr(cv::Rect(100, 100, 300, 120));
        cv::cvtColor(crop, out, cv::COLOR_BGR2RGB);
        if (fps) std::this_thread::sleep_until(begin + std::chrono::nanoseconds(
            (static_cast<std::int64_t>(count) + 1) * 1000000000 / fps));
    }
    const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
    const double cpu = cpuSeconds() - cpuBegin;
    std::uint64_t hash = 14695981039346656037ULL;
    for (int row = 0; row < out.rows; ++row)
        for (std::size_t col = 0; col < out.cols * out.elemSize(); ++col) {
            hash ^= out.ptr<unsigned char>(row)[col];
            hash *= 1099511628211ULL;
        }
    std::cout << "frames=" << count << " fps=" << count / elapsed
              << " wall_s=" << elapsed << " cpu_s=" << cpu
              << " cpu_pct=" << 100 * cpu / elapsed << " pixels_hash=" << hash << '\n';
}
