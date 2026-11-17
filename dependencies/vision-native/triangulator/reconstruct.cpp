 
#include "diplib.h"
#include "dipviewer.h"
#include "diplib/simple_file_io.h"
#include "diplib/linear.h"       // for dip::Gauss()
#include "diplib/segmentation.h" // for dip::Threshold()
#include "diplib/regions.h"      // for dip::Label()
#include "diplib/measurement.h"
#include "diplib/mapping.h"      // for dip::ContrastStretch() and dip::ErfClip()
#include "diplib/binary.h"
#include "diplib/testing.h"
#include "diplib/generation.h"
#include "diplib/statistics.h"

#include <opencv2/opencv.hpp>

#include <vector>

#include "open3d/Open3D.h"

using namespace cv;

std::tuple<Eigen::Vector4d, std::vector<size_t>> PlaneRegression(const open3d::geometry::PointCloud& point_cloud, double threshold = 0.01, int init_n = 3, int iter = 1000) {
  auto result = point_cloud.SegmentPlane(threshold, init_n, iter);
  return std::make_tuple(std::get<0>(result), std::get<1>(result));
}


std::vector<std::tuple<Eigen::Vector4d, open3d::geometry::PointCloud>> DetectMultiPlanes2(const open3d::geometry::PointCloud& point_cloud, double min_ratio = 0.05, double threshold = 0.01, int iterations = 1000) {
  using namespace open3d;
  std::vector<std::tuple<Eigen::Vector4d, open3d::geometry::PointCloud>> plane_list;
  size_t N = point_cloud.points_.size();
  open3d::geometry::PointCloud target = point_cloud;
  open3d::geometry::PointCloud temp;
  temp.points_.clear();
  size_t count = 0;

  while(count < (1 - min_ratio) * N) {
    auto result = PlaneRegression(target, threshold, 3, iterations);
    auto plane_eq = std::get<0>(result);
    auto inliers = std::get<1>(result);
    count += inliers.size();
    temp = *target.SelectByIndex(inliers);
    target = *target.SelectByIndex(inliers, true);

    plane_list.push_back(std::make_tuple(plane_eq, temp));

    // auto my = std::make_shared<geometry::PointCloud>();
    // *my = temp;
    // visualization::DrawGeometries({my}, "PointCloud", 1600, 900);
  }
  return plane_list;
}



void myPointCloud(cv::Mat deepMat, cv::Mat shading) {
  using namespace open3d;

  // Create an empty PointCloud
  geometry::PointCloud pointCloud;
  pointCloud.Clear();

  // Convert CV_32FC3 Mat to Open3D PointCloud
  for(int y = 0; y < deepMat.rows; ++y) {
    for(int x = 0; x < deepMat.cols; ++x) {
      Vec3f xyz = deepMat.at<Vec3f>(y, x);
      // std::cout << "xyz: " << xyz << '\n';
      unsigned char shade = shading.at<unsigned char>(y, x);
      if(xyz[0] != 0 && xyz[1] != 0 && xyz[2] != 0) {
	Eigen::Vector3d point(xyz[0],xyz[1], xyz[2]);
	Eigen::Vector3d color(shade/255.0, shade/255.0, shade/255.0);
	pointCloud.points_.push_back(point);
	pointCloud.colors_.push_back(color);
      }
    }
  }

  std::cout << "point cloud size: " << pointCloud.points_.size() << '\n';


  // Load STL mesh
  geometry::TriangleMesh mesh;
  open3d::io::ReadTriangleMesh("/home/hotcat/Downloads/new3dvision/controller/src/reconstruct/samples/205.stl", mesh);
  

  auto cloud_ptr = std::make_shared<geometry::PointCloud>();
  // *cloud_ptr = pointCloud;
  // visualization::DrawGeometries({cloud_ptr}, "PointCloud", 1600, 900);

  // Convert mesh to point cloud
  cloud_ptr = mesh.SamplePointsUniformly(100000);

  io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/structureLight/slstudio/example_data/skull_2x3/my2.ply", pointCloud, true);


  auto allcloud = std::make_shared<geometry::PointCloud>();
  auto results2 = DetectMultiPlanes2(*cloud_ptr, 0.03, 0.1, 1000);

  for(size_t i = 0; i< results2.size(); ++i) {
    std::cout << "Plane " << i << " equation: " << std::get<0>(results2[i]).transpose() << std::endl;
  }


  visualization::DrawGeometries({cloud_ptr}, "PointCloud");

  // auto cloud_ptr = std::make_shared<geometry::PointCloud>();
  // if (io::ReadPointCloud("/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply", *cloud_ptr)) { 
  //   utility::LogInfo("Successfully read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
  // } else {
  //   utility::LogWarning("Failed to read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
  //   return;
  // }
  // cloud_ptr->NormalizeNormals();
  // visualization::DrawGeometries({cloud_ptr}, "PointCloud", 1600, 900);


  
}
