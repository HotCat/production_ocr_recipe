#include "unistd.h"
#include "opencv2/opencv.hpp"
#include "opencv2/imgproc/imgproc_c.h"

class CameraV{

public:
        CameraV(char* camera_id);
        ~CameraV();

        void setProperties(std::string property_name, double property_value);
        void closeCamera();

        cv::Mat readFrameMat();

private:
        int m_hCamera;
        int m_timeout;
        cv::Mat m_ngMat;
        bool m_monochrome;
        bool m_patMode;
        unsigned char* m_pBuffer;

};
