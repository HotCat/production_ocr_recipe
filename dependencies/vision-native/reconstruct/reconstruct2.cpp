
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
#include <iostream>
#include <chrono>
#include <string>
#include <chrono>


#include "open3d/Open3D.h"
#include "open3d/visualization/rendering/Camera.h"
#include "open3d/visualization/rendering/filament/FilamentEngine.h"
#include "open3d/visualization/rendering/filament/FilamentRenderer.h"


using namespace cv;

using namespace open3d;
using namespace open3d::visualization::gui;
using namespace open3d::visualization::rendering;




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



// void readPointCloud(const char* filePath, std::vector<Eigen::Vector3d>& points) {
//   using namespace open3d;
//   auto cloud = io::CreatePointCloudFromFile(filePath, "auto", true);
//   for(const auto& point : cloud->points_) {
//     points.push_back(point);
//   }
// }


// PointCloud* readPointCloud(const char* filePath) {
//   PointCloud* pc = new PointCloud;
//   open3d::geometry::PointCloud pcd;
//   if (open3d::io::ReadPointCloud(filePath, pcd)) {
//       for (const auto& point : pcd.points_) {
//           pc->points.push_back(Eigen::Vector3d(point(0), point(1), point(2)));
//       }
//   } else {
//       std::cerr << "Failed to read point cloud from file: " << filePath << std::endl;
//   }
//   return pc;
// }



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

  auto start3 = std::chrono::high_resolution_clock::now();

  auto cloud_ptr = std::make_shared<geometry::PointCloud>();
  *cloud_ptr = pointCloud;
  // visualization::DrawGeometries({cloud_ptr}, "PointCloud", 1600, 900);

  io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/my.ply", pointCloud, true);

  auto end3 = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> duration3 = end3 - start3;
  std::cout << "save point cloud Execution time: " << duration3.count() << " seconds" << std::endl;

  return;

  // Load STL mesh
  geometry::TriangleMesh mesh;
  open3d::io::ReadTriangleMesh("/home/hotcat/Downloads/new3dvision/controller/src/reconstruct/samples/248.stl", mesh);
  

  // auto cloud_ptr = std::make_shared<geometry::PointCloud>();
  // *cloud_ptr = pointCloud;
  // visualization::DrawGeometries({cloud_ptr}, "PointCloud", 1600, 900);

  // Convert mesh to point cloud
  cloud_ptr = mesh.SamplePointsUniformly(100000);
  io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/src/reconstruct/samples/Mesh3.ply", *cloud_ptr);

  io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/structureLight/slstudio/example_data/skull_2x3/my2.ply", pointCloud, true);


  auto start = std::chrono::high_resolution_clock::now();
  
  auto allcloud = std::make_shared<geometry::PointCloud>();
  auto results2 = DetectMultiPlanes2(*cloud_ptr, 0.03, 0.1, 1000);

  auto end = std::chrono::high_resolution_clock::now();

  std::chrono::duration<double> duration = end - start;
  std::cout << "Execution time: " << duration.count() << " seconds" << std::endl;

  for(size_t i = 0; i< results2.size(); ++i) {
    std::cout << "Plane " << i << " equation: " << std::get<0>(results2[i]).transpose() << std::endl;
  }

  // auto cloud_ptr = std::make_shared<geometry::PointCloud>();
  // if (io::ReadPointCloud("/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply", *cloud_ptr)) { 
  //   utility::LogInfo("Successfully read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
  // } else {
  //   utility::LogWarning("Failed to read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
  //   return;
  // }
  // cloud_ptr->NormalizeNormals();
  // visualization::DrawGeometries({cloud_ptr}, "PointCloud", 1600, 900);



  // Command line arguments
  std::vector<std::string> args = {"/usr/local/bin/Open3D/resources"};
  static const std::string kOutputFilename = "offscreen.png";


  // Convert to C-style arrays
  int argc = static_cast<int>(args.size());
  std::vector<const char*> argv_c;
  for(const auto& arg : args) {
    argv_c.push_back(const_cast<char*>(arg.c_str()));
  }
  argv_c.push_back(nullptr); // Null-terminate the array

  // Pass argc and argv to the application initialization function
  auto &app = Application::GetInstance();
  app.Initialize(argc, argv_c.data());

  auto *renderer = new FilamentRenderer(EngineInstance::GetInstance(), 1280, 1024, EngineInstance::GetResourceManager());

  auto *scene = new Open3DScene(*renderer);
  MaterialRecord mat;
  mat.shader = "defaultLit";
  
  // auto torus = open3d::geometry::TriangleMesh::CreateTorus();
  // torus->ComputeVertexNormals();
  // torus->PaintUniformColor({1.0f, 1.0f, 0.0f});
  // scene->AddGeometry("torus", torus.get(), mat);


  auto mypc_ptr = std::make_shared<open3d::geometry::PointCloud>();
  // io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/src/reconstruct/samples/Mesh2.ply", *mypc_ptr);
  io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/structureLight/slstudio/example_data/skull_2x3/my2.ply", *mypc_ptr);

  mypc_ptr->PaintUniformColor({1.0f, 1.0f, 0.0f});
  scene->AddGeometry("tutu", mypc_ptr.get(), mat);
  
  scene->ShowAxes(true);

  scene->GetCamera()->SetProjection(60.0f, float(1280.0) / float(1024.0), 0.1f,
                                      800.0f, Camera::FovType::Vertical);
  scene->GetCamera()->LookAt({0.0f, 0.0f, 0.0f}, {30.0f, 3.0f, -80.0f},
                               {0.0f, -1.0f, 0.0f});

  // This example demonstrates rendering to an image without a window.
  // If you want to render to an image from within a window you should use
  // scene->GetScene()->RenderToImage() instead.

  auto start2 = std::chrono::high_resolution_clock::now();
  
  auto img = app.RenderToImage(*renderer, scene->GetView(), scene->GetScene(),
                                 1280.0, 1024.0);  

  auto end2 = std::chrono::high_resolution_clock::now();

  std::chrono::duration<double> duration2 = end2 - start2;
  std::cout << "Rendering time: " << duration2.count() << " seconds" << std::endl;


  

  std::cout << "Writing file to " << kOutputFilename << std::endl;
  io::WriteImage(kOutputFilename, *img);

  // We manually delete these because Filament requires that things get
  // destructed in the right order.
  delete scene;
  delete renderer;

}


void myPointCloud3(cv::Mat mat) {
  using namespace open3d;
  auto cloud_ptr = std::make_shared<geometry::PointCloud>();
  if (io::ReadPointCloud("/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply", *cloud_ptr)) { 
    utility::LogInfo("Successfully read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
  } else {
    utility::LogWarning("Failed to read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
    return;
  }
  cloud_ptr->NormalizeNormals();
  visualization::DrawGeometries({cloud_ptr}, "PointCloud", 1600, 900);
}




void myPointCloud2(cv::Mat mat) {
  // auto point_cloud = open3d::geometry::PointCloud::CreateFromDepthImage(open3d::utility::AsTensor(depth_map),
  // 									open3d::camera::PinholeCameraIntrinsic(open3d::camera::PinholeCameraIntrinsicParameters::PrimeSenseDefault));

  open3d::geometry::Image img;
  // Allocate data buffer  
  img.Prepare(mat.cols, mat.rows, 3, 4);
  // mat is your cv::Mat depth image
  memcpy(img.data_.data(), mat.data, mat.total() * mat.elemSize());



  auto image_ptr = std::make_shared<open3d::geometry::Image>(img);
  open3d::camera::PinholeCameraIntrinsic camera;
  camera.SetIntrinsics(640, 480, 575.0, 575.0, 319.5, 239.5);

  auto pointcloud_ptr = open3d::geometry::PointCloud::CreateFromDepthImage(*image_ptr, camera);

  open3d::visualization::DrawGeometries({pointcloud_ptr},"TestPCDFileFormat", 1920, 1080);

  // mat is your cv::Mat intrinsic with shape of 3 x 3

  return;
}

void PrintPointCloud(const open3d::geometry::PointCloud &pointcloud) {
    using namespace open3d;

    bool pointcloud_has_normal = pointcloud.HasNormals();
    utility::LogInfo("Pointcloud has %d points.",
                     (int)pointcloud.points_.size());

    Eigen::Vector3d min_bound = pointcloud.GetMinBound();
    Eigen::Vector3d max_bound = pointcloud.GetMaxBound();
    utility::LogInfo(
            "Bounding box is: ({:.4f}, {:.4f}, {:.4f}) - ({:.4f}, {:.4f}, "
            "{:.4f})",
            min_bound(0), min_bound(1), min_bound(2), max_bound(0),
            max_bound(1), max_bound(2));

    for (size_t i = 0; i < pointcloud.points_.size(); i++) {
        if (pointcloud_has_normal) {
            const Eigen::Vector3d &point = pointcloud.points_[i];
            const Eigen::Vector3d &normal = pointcloud.normals_[i];
            utility::LogInfo("{:.6f} {:.6f} {:.6f} {:.6f} {:.6f} {:.6f}",
                             point(0), point(1), point(2), normal(0), normal(1),
                             normal(2));
        } else {
            const Eigen::Vector3d &point = pointcloud.points_[i];
            utility::LogInfo("{:.6f} {:.6f} {:.6f}", point(0), point(1),
                             point(2));
        }
    }
    utility::LogInfo("End of the list.");
}

int main2() {

  dip::testing::Timer timer;
  timer.Reset();
   // auto a = dip::ImageRead("/home/test/Downloads/diplib-3.1.0/build/examples/Ef8ey.jpeg");
  // auto a = dip::ImageRead("/home/test/Downloads/diplib-3.1.0/examples/bdm4.jpeg");
  auto a = dip::ImageRead("/home/test/Downloads/diplib-3.1.0/examples/samples/debug2.jpeg");
  a.ResetPixelSize();

  dip::Image circle;
  
  circle = dip::Image(a.Sizes(), 1, dip::DT_DFLOAT);
  circle.Fill(0);

  dip::DrawBandlimitedBall(circle, 215.0, {501.8,460.1}, {1}, "empty");
  // dip::DrawEllipsoid(circle, {201.1, 199.5}, {559.7,607.1}, {1});
  circle /= dip::Maximum(circle);

  a *= 1 - circle;
  dip::Image my0d({0,255,0});
  a += circle * my0d;


  dip::viewer::Show(a);

  dip::viewer::Spin(); 
  return 0;
  
   // a = a[1];  // Use green channel only, simple way to convert to gray scale

   dip::Gauss(a, a, {2});

   dip::Image b;
   double t = dip::Threshold(a, b);
   std::cout << "Threshold: " << t << '\n';

   b = a < t; // Or: dip::Invert(b,b);
   
   // dip::viewer::Show(EdgeObjectsRemove(b));
   
   b = dip::BinaryAreaOpening( dip::EdgeObjectsRemove( b ), 1000 );

   // dip::viewer::Show(b);

   auto m = dip::Label(b);
   dip::MeasurementTool measurementTool;
   auto msr = measurementTool.Measure(m, {}, { "Center"});
   std::cout << msr << '\n';


   // dip::viewer::Show(-dip::ErfClip(a, t, 30));

   auto c = dip::ContrastStretch(-dip::ErfClip(a, t, 30));

   // dip::viewer::Show(c);

   dip::GrowRegions(m, {}, m, -2, 2);


   msr = measurementTool.Measure(m, c, {"Gravity", "Feret", "P2A"});
   std::cout << msr << '\n';

   // dip::viewer::Show(m);

   // Iterate through the measurement structure:
   auto it = msr["Gravity"].FirstObject();

   while(it) {
     if(it[4] > 190 && it[4] < 215 && it[7] < 1.1) {
       std::cout << "Centroid coordinates = " << it[0] << ", " << it[1] << '\n';
       std::cout << "feret[0] = " << it[2] << " feret[1]" << it[3]<< '\n';
     }
     ++it;
   }

   timer.Stop();
   double time = timer.GetWall();
   std::cout << "time : " << time <<"\n";


   dip::viewer::Spin();
}


int main() {

  dip::testing::Timer timer;
  dip::Image circle;

  timer.Reset();

  //auto a = dip::ImageRead("/home/test/Downloads/diplib-3.1.0/examples/bdm4.jpeg");
  // auto a = dip::ImageRead("./debug1811996578488000.jpeg");
  // auto a = dip::ImageRead("./debug1811996578488000.jpeg");
  auto a = dip::ImageRead("/home/test/strucutreLight/slstudio/example_data/skull_2x3/my4.tiff");
  

  a.ResetPixelSize();


  dip::viewer::Show(a);
  dip::viewer::Spin(); 
  return 0;


  circle = dip::Image(a.Sizes(), 1, dip::DT_DFLOAT);
  circle.Fill(0);

  double low = 50;
  double high = 90;

  a = dip::ErfClip(a , low, high, "both");
  
  dip::Gauss(a, a, {2});

  dip::Image b;
  double t = dip::Threshold(a, b);
  std::cout << "Threshold: " << t << '\n';

  b = a < t; // Or: dip::Invert(b,b);

  b = dip::BinaryAreaOpening( dip::EdgeObjectsRemove( b ), 1000 );

  auto m = dip::Label(b);
  dip::MeasurementTool measurementTool;
  auto c = dip::ContrastStretch(-dip::ErfClip(a, t, 30));

  // dip::viewer::Show(c);

  dip::GrowRegions(m, {}, m, -2, 2);

  // auto msr = measurementTool.Measure(m, c, {"Gravity", "Feret", "GreyDimensionsEllipsoid"});
  // auto msr = measurementTool.Measure(m, c, {"Gravity", "Feret", "GreyMu"});
  auto msr = measurementTool.Measure(m, c, {"GreyMu"});
  std::cout << msr << '\n';
  return 0;

  auto it = msr["Gravity"].FirstObject();

  while(it) {

     std::cout << "time : " << time <<"\n";
     std::cout << "x = " << it[0] << " y = " << it[1] << '\n';
     std::cout << "Feret = " << it[4] << '\n';

     if(it[4] > 190 && it[4] < 230) {
       std::cout << "Centroid coordinates = " << it[0] << ", " << it[1] << '\n';
       std::cout << "feret[0] = " << it[2] << " feret[1]" << it[3]<< '\n';
       dip::DrawBandlimitedBall(circle, it[3], {it[0],it[1]}, {1}, "empty");
       circle /= dip::Maximum(circle);

       a *= 1 - circle;
       dip::Image my0d({255,0,0});
       a += circle * my0d;

       dip::viewer::Show(a);
       dip::viewer::Spin();
     }
     ++it;
   }

  timer.Stop();
  double time = timer.GetWall();

  

  // dip::ImageWriteTIFF(m, "mycat.tiff");
  dip::viewer::Spin();

  return 0;
}

