#include "unistd.h"
#include "CameraApi.h"
#include "opencv2/opencv.hpp"
#include "opencv2/imgproc/imgproc_c.h"
#include "reconstruct.h"
#include "thread"
#include "chrono"

class CameraM{

public:
        CameraM(char* camera_id);
        ~CameraM();

        void setProperties(std::string property_name, double property_value);
        void closeCamera();

        cv::Mat readFrameMat();
        void captureSequence(int dir);
        void captureProfilo(Reconstruct&, int);
        void profiloCircle(Reconstruct&, int);
        void start_video();

        void unInitCamera();

private:
        int m_hCamera;
        int m_timeout;
        cv::Mat m_ngMat;
        bool m_monochrome;
        bool m_patMode;
        unsigned char* m_pBuffer;

};
