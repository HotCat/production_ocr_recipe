#include "unistd.h"
#include "MvCameraControl.h"
#include "opencv2/opencv.hpp"

class CameraH{

public:
        CameraH(char* camera_id);
        ~CameraH();

        void setProperties(std::string property_name, double property_value);
        void closeCamera();

        cv::Mat readFrameMat();
        void start_video();

private:
        void* m_hCamera = NULL;
        unsigned int m_nDataSize;
        cv::Mat m_ngMat;
        int m_timeout;
        unsigned char* m_pBuffer = NULL;
        unsigned char* m_pBufferT = NULL;
};
