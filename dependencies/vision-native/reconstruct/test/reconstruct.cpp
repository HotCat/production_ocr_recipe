 
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

#include <iostream>
#include <chrono>

using namespace open3d;

std::tuple<Eigen::Vector4d, std::vector<size_t>> PlaneRegression(const open3d::geometry::PointCloud& point_cloud, double threshold = 0.01, int init_n = 3, int iter = 1000) {
  auto result = point_cloud.SegmentPlane(threshold, init_n, iter);
  return std::make_tuple(std::get<0>(result), std::get<1>(result));
}

std::vector<std::tuple<Eigen::Vector4d, std::vector<size_t>>> DetectMultiPlanes(const open3d::geometry::PointCloud& point_cloud, double min_ratio = 0.05, double threshold = 0.01, int iterations = 1000) {
  using namespace open3d;
  std::vector<std::tuple<Eigen::Vector4d, std::vector<size_t>>> plane_list;
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
    plane_list.push_back(std::make_tuple(plane_eq, inliers));
    temp = *target.SelectByIndex(inliers);
    target = *target.SelectByIndex(inliers, true);

    auto my = std::make_shared<geometry::PointCloud>();
    *my = temp;
    visualization::DrawGeometries({my}, "PointCloud", 1600, 900);
  }
  return plane_list;
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

void myTrim() {
  // Load point cloud
  using namespace open3d;
  auto pcd_ptr = io::CreatePointCloudFromFile("input.ply");

  // Define bounding box
  Eigen::Vector3d min_bound(-1.0, -1.0, -1.0);
  Eigen::Vector3d max_bound(1.0, 1.0, 1.0);

  // Define axis-aligned bounding box
  geometry::AxisAlignedBoundingBox aabb(Eigen::Vector3d(-1.0, -1.0, -1.0),
					Eigen::Vector3d(1.0, 1.0, 1.0));

  // Crop point cloud using axis-aligned bounding box
  auto cropped_pcd_ptr = pcd_ptr->Crop(aabb);
}


// void myRegistration() {
//   auto source_pc = open3d::io::CreatePointCloudFromFile("xxxx.ply");
//   auto target_pc = open3d::io::CreatePointCloudFromFile("xxxx.ply");

//   if(!source_pc || !target_pc) {
//     std::cerr << "Failed to load point clouds" <<std::endl;
//     return;
//   }

//   // Downsample for faster processing (optional)
//   source_pc = source_pc->VoxelDownSample(0.05);
//   target_pc = target_pc->VoxelDownSample(0.05);

//   // Perform ICP registration
//   auto icp_result = open3d::registration::RegistrationICP(*source_pc, *target_pc, 0.02, Eigen::Matrix4d::Identity(), open3d::registration::TransformationEstimationPointToPoint());

//   if(icp_result.transformation_.isIdentity()) {
//     std::cerr << "ICP registration failed." << std::endl;
//     return;
//   }

//   source_pc->Transform(icp_result.transformation_);

//   // Visualize the result
//   open3d::visualization::DrawGeometries({source_pc, target_pc});

// }


void separateByPlane() {
  // Load point cloud
  auto pcd = open3d::io::CreatePointCloudFromFile("xxxx.ply");

  // Define plane equation (e.g., ax + by + cz + d = 0)
  double a = 0.0;
  double b = 0.0;
  double c = 1.0; // Assume the plane is parallel to the z-axis
  double d = 0.0; // Distance from the origin along the z-axis

  // Iterate through each point and determine which side of the plane it lies on
  open3d::geometry::PointCloud positive_side;
  open3d::geometry::PointCloud negative_side;
  for(const auto &point : pcd->points_) {
    // Calculate signed distance from the plane
    double distance = a * point.x() + b * point.y() + c * point.z() + d;

    // Assign point to positive or negative side based on the signed distance
    if(distance > 0) {
      positive_side.points_.push_back(point);
    } else {
      negative_side.points_.push_back(point);
    }
    
  }
  
}


void boundingBox(const geometry::PointCloud &plane_cloud) {
  // Compute the axis-aligned bounding box
  auto aabb = plane_cloud.GetAxisAlignedBoundingBox();
}
  

// Function to fit plane to neighboring points using RANSAC
void FitPlane(const geometry::PointCloud &cloud, const Eigen::Vector3d &initial_normal, double distance_threshold) {
  // Create a KDTree for efficient nearest neighbor search
  geometry::KDTreeFlann kdtree;
  kdtree.SetGeometry(cloud);

  // Define a vector to store inliers
  std::vector<size_t> inliers;

  // Iterate over each point in the cloud
  for(size_t i = 0; i < cloud.points_.size(); ++i) {
    // Find neighboring points within distance_threshold
    std::vector<int> indices;
    std::vector<double> distances;
    kdtree.SearchRadius(cloud.points_[i], distance_threshold, indices, distances);

    // Check if any neighboring points are already in inliers
    bool already_inliers = false;
    for(auto idx : indices) {
      if(std::find(inliers.begin(), inliers.end(), idx) != inliers.end()) {
    	already_inliers = true;
    	break;
      }
    }

    // If the point is not already in inliers, add it to inliers
    if(!already_inliers) {
      inliers.push_back(i);
    }
  }

  // Fit plane to inliers
  auto inlier_cloud = cloud.SelectByIndex(inliers);
  // auto plane_mode = geometry::PlaneModel::CreateFromPoints(inlier_cloud.points_);
  
}


Eigen::Vector3d GenerateRandomColor2() {
  double r = static_cast<double>(rand()) / RAND_MAX;
  double g = static_cast<double>(rand()) / RAND_MAX;
  double b = static_cast<double>(rand()) / RAND_MAX;

  // Increase the brightness by ensuring all components are above 0.5
  if (r<0.5) r += 0.5;
  if (g<0.5) r += 0.5;
  if (b<0.5) r += 0.5;
  return {r,g,b};
}

std::vector<double> GenerateRandomColor() {
  double r = static_cast<double>(rand()) / RAND_MAX;
  double g = static_cast<double>(rand()) / RAND_MAX;
  double b = static_cast<double>(rand()) / RAND_MAX;

  // Increase the brightness by ensuring all components are above 0.5
  if (r<0.5) r += 0.5;
  if (g<0.5) r += 0.5;
  if (b<0.5) r += 0.5;
  return {r,g,b};
}

Eigen::Vector3d ConvertToEigenVector3d(const std::vector<double>& color) {
  return Eigen::Vector3d(color[0], color[1], color[2]);
}

int main() {
  using namespace open3d;
  auto cloud_ptr = std::make_shared<geometry::PointCloud>();

  // Load STL mesh
  geometry::TriangleMesh mesh;
  open3d::io::ReadTriangleMesh("/home/hotcat/Downloads/new3dvision/controller/src/reconstruct/samples/248.stl", mesh);

  // open3d::io::WriteTriangleMesh("/home/test/newDelta/controller/src/samples/my.ply", *mesh, true, true);

  // Convert mesh to point cloud
  cloud_ptr = mesh.SamplePointsUniformly(100000);

  io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/src/reconstruct/samples/Mesh3.ply", *cloud_ptr);

  auto start = std::chrono::high_resolution_clock::now();

  // cloud_ptr->PaintUniformColor({0.0,1.0,0.0});
  // visualization::DrawGeometries({cloud_ptr}, "PointCloud", 1600, 900);
  // return 0;


  // Eigen::Vector3d initial_normal(0.0,0.0,1.0);
  // double distance_threshold = 0.01; // Distance threshold for neighboring points

  // // Fit plane to neighboring points
  // FitPlane(*cloud_ptr, initial_normal, distance_threshold);

  // return 0;

  auto allcloud = std::make_shared<geometry::PointCloud>();
  auto results2 = DetectMultiPlanes2(*cloud_ptr, 0.04, 0.06, 1000);

  auto end = std::chrono::high_resolution_clock::now();
  std::chrono::duration<double> duration = end - start;
  std::cout << "Execution time: " << duration.count() << " seconds" << std::endl;
  for(size_t i = 0; i< results2.size(); ++i) {
    std::cout << "Plane " << i << " equation: " << std::get<0>(results2[i]).transpose() << std::endl;


    auto my = std::make_shared<geometry::PointCloud>();
    *my = std::get<1>(results2[i]);
    my->PaintUniformColor(GenerateRandomColor2());
    // visualization::DrawGeometries({my}, "PointCloud", 1600, 900);
    *allcloud += *my;
  }

  visualization::DrawGeometries({allcloud}, "PointCloud", 1600, 900);
  return 0;









  // cloud_ptr->points_ = mesh.vertices_;
  // cloud_ptr->normals_ = mesh.vertex_normals_;
  // cloud_ptr->colors_.clear();

  visualization::DrawGeometries({cloud_ptr}, "PointCloud", 1600, 900);

  // open3d::io::WritePointCloudToXYZ("/home/test/newDelta/controller/src/samples/my.xyz", *cloud_ptr);
  auto results = DetectMultiPlanes(*cloud_ptr, 0.03, 0.1, 1000);

  // Output plane equations and inlier indices
  for(size_t i = 0; i< results.size(); ++i) {
    std::cout << "Plane " << i << " equation: " << std::get<0>(results[i]).transpose() << std::endl;

    // auto mycloud = (*cloud_ptr).SelectByIndex(std::get<1>(results[i]));
    // visualization::DrawGeometries({mycloud}, "PointCloud", 1600, 900);
  }

  std::vector<Eigen::MatrixXd> planes;
  std::vector<Eigen::MatrixXd> colors;

  for(auto& result : results) {
    double r = static_cast<double>(rand()) / RAND_MAX;
    double g = static_cast<double>(rand()) / RAND_MAX;
    double b = static_cast<double>(rand()) / RAND_MAX;

    auto& plane_eq = std::get<0>(result);
    auto& plane_indices = std::get<1>(result);

    geometry::PointCloud plane_points;
    plane_points.points_.resize(plane_indices.size());
    std::vector<std::vector<double>> plane_colors;
    for(size_t i = 0; i < plane_indices.size(); ++i) {
      auto color = GenerateRandomColor();
      plane_colors.push_back(color);
      plane_points.points_[i] = cloud_ptr->points_[plane_indices[i]];
    }

    // auto my = std::make_shared<geometry::PointCloud>();
    // *my = plane_points;
    // visualization::DrawGeometries({my}, "PointCloud", 1600, 900);
    
  }

  return 0;




  // if (io::ReadPointCloud("/home/test/newDelta/controller/src/samples/my.ply", *cloud_ptr)) {
  // // if (io::ReadPointCloud("/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply", *cloud_ptr)) {
  //   utility::LogInfo("Successfully read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
  // } else {
  //   utility::LogWarning("Failed to read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
  //   return 1;
  // }
  // cloud_ptr->colors_.clear();

  visualization::DrawGeometries({cloud_ptr}, "PointCloud", 1600, 900);


  // Downsample point cloud (optional)
  auto downsampled_point_cloud = cloud_ptr->VoxelDownSample(0.05);

  // Perform DBSCAN clustering
  double eps = 0.9; // DBSCAN epsilon parameter
  int min_points = 10; // Minimum points in a cluster
  auto labels = downsampled_point_cloud->ClusterDBSCAN(eps, min_points);

  // Find the number of clusters
  int num_clusters = *std::max_element(labels.begin(), labels.end()) + 1;

  // Segment planes in each cluster
  for(int cluster_id = 0; cluster_id < num_clusters; ++cluster_id) {
    // Extract points belonging to the current cluster
    std::vector<size_t> cluster_indices;
    for(size_t i = 0; i < labels.size(); ++i) {
      if(labels[i] == cluster_id) {
	cluster_indices.push_back(i);
      }
    }
    
    auto cluster = downsampled_point_cloud->SelectByIndex(cluster_indices);

    // Segment planes within the cluster
    auto result = cluster->SegmentPlane();
    auto plane_model = std::get<0>(result);
    auto inliers = std::get<1>(result);

    std::cout << "inliers size "<< inliers.size();

    // Color points belonging to the segmented plane
    for(size_t i = 0; i< inliers.size(); ++i) {
      size_t point_index = cluster_indices[inliers[i]];
      auto color = ConvertToEigenVector3d(GenerateRandomColor());
      // downsampled_point_cloud->colors_[point_index] = color;
    }
  }

  // Visualize the segmented point cloud
  visualization::DrawGeometries({downsampled_point_cloud}, "PointCloud", 1600, 900);
}


int wrong_SegmentPlane() {
  using namespace open3d;
  auto cloud_ptr = std::make_shared<geometry::PointCloud>();
  if (io::ReadPointCloud("/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply", *cloud_ptr)) {
    utility::LogInfo("Successfully read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
  } else {
    utility::LogWarning("Failed to read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
    return 1;
  }

  // Parameters for plane segmentation
  double distance_threshold = 0.01; // Max distance a point can be from the plane model
  int ransac_n = 3; // Number of initial points to be considered inliers
  int num_iterations = 100; //Number of iterations

  // Perform plane segmentation
  auto result = cloud_ptr->SegmentPlane(distance_threshold, ransac_n, num_iterations);
  auto plane_model = std::get<0>(result);
  auto inliers = std::get<1>(result);

  // Generate random color for each plane
  std::vector<std::vector<double>> plane_colors;
  for(size_t i = 0; i < inliers.size(); ++i) {
    auto color = GenerateRandomColor();
    plane_colors.push_back(color);
  }

  // Color each plane in the point cloud
  for(size_t i = 0; i < inliers.size(); ++i) {
    auto color = ConvertToEigenVector3d(plane_colors[i]);

    // cloud_ptr->colors_[i] = color[inliers];
  }

}




int cluster_segment() {
  using namespace open3d;
  auto cloud_ptr = std::make_shared<geometry::PointCloud>();
  if (io::ReadPointCloud("/home/test/newDelta/controller/src/samples/my.xyz", *cloud_ptr)) {  
  // if (io::ReadPointCloud("/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply", *cloud_ptr)) {
    utility::LogInfo("Successfully read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
  } else {
    utility::LogWarning("Failed to read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
    return 1;
  }

  auto downsampled_point_cloud = cloud_ptr->VoxelDownSample(0.005);

  visualization::DrawGeometries({downsampled_point_cloud}, "PointCloud", 1600, 900);

  cloud_ptr = downsampled_point_cloud;


  // // Load STL mesh
  // auto mesh = open3d::io::CreateMeshFromFile("/home/test/newDelta/controller/src/samples/205.stl");
  // cloud_ptr->points_ = mesh->vertices_;
  // cloud_ptr->normals_ = mesh->vertex_normals_;
  // cloud_ptr->colors_.clear();


  double eps = 1.1;
  double min_points = 100;

  
  // Perform DBSCAN clustering
  auto labels = cloud_ptr->ClusterDBSCAN(eps, min_points);



  // Determine the number of clusters
  long num_clusters = *std::max_element(labels.begin(), labels.end()) + 1;

  std::cout << num_clusters << num_clusters;

  // Determine the size of each cluster
  std::vector<int> cluster_sizes(num_clusters, 0);
  for(size_t i = 0; i < labels.size(); ++i) {
    int cluster_index = labels[i];
    if(cluster_index >= 0) { //Skip noise points (cluster index = -1)
      cluster_sizes[cluster_index]++;
    }
  }

  // Find the index of the largest cluster
  int largest_cluster_index = std::distance(cluster_sizes.begin(), std::max_element(cluster_sizes.begin(), cluster_sizes.end()));




  // Create a new point cloud to store the largest cluster
  auto largest_cluster_point_cloud = std::make_shared<open3d::geometry::PointCloud>();
  largest_cluster_point_cloud->points_.reserve(cluster_sizes[largest_cluster_index]);
  largest_cluster_point_cloud->colors_.reserve(cluster_sizes[largest_cluster_index]);

  // Copy points and colors from the original point cloud to the largest cluster point cloud
  for(size_t i = 0; i < labels.size(); ++i) {
    int cluster_index = labels[i];
    if(cluster_index == largest_cluster_index) {
      largest_cluster_point_cloud->points_.push_back(cloud_ptr->points_[i]);
      largest_cluster_point_cloud->colors_.push_back(cloud_ptr->colors_[i]);
    }
  }


  // Visualize the largest cluster point cloud
  visualization::DrawGeometries({largest_cluster_point_cloud}, "PointCloud", 1600, 900);

  return 0;
}






// int main() {
//   using namespace open3d;
//   auto cloud_ptr = std::make_shared<geometry::PointCloud>();
//   if (io::ReadPointCloud("/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply", *cloud_ptr)) {
//     utility::LogInfo("Successfully read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
//   } else {
//     utility::LogWarning("Failed to read {}", "/home/test/strucutreLight/slstudio/example_data/skull_2x3/pointCloud.ply");
//     return 1;
//   }

//   double eps = 0.9;
//   double min_points = 10;

  
//   // Perform DBSCAN clustering
//   auto labels = cloud_ptr->ClusterDBSCAN(eps, min_points);

//   // Determine the number of clusters
//   long num_clusters = *std::max_element(labels.begin(), labels.end()) + 1;
  
//   std::cout << "number of clusters" << num_clusters;

//   // Generate random colors for clusters
//   std::vector<std::vector<double>> cluster_colors(num_clusters);
//   for (int i = 0; i< num_clusters; ++i) {
//     cluster_colors[i] = GenerateRandomColor();
//   }

//   // Create a copy of the original point cloud for visualization
//   auto colored_point_cloud = std::make_shared<open3d::geometry::PointCloud>();
//   colored_point_cloud->points_ = cloud_ptr->points_;

//   // Assign colors to points based on their cluster labels
//   colored_point_cloud->colors_.resize(cloud_ptr->points_.size());
//   for(size_t i = 0; i< labels.size(); ++i) {
//     int cluster_index = labels[i];
//     if(cluster_index >= 0) { // Skip noise points (cluster index = -1)
//       colored_point_cloud->colors_[i] = ConvertToEigenVector3d(cluster_colors[cluster_index]);
//     }
//   }

//   visualization::DrawGeometries({colored_point_cloud}, "PointCloud", 1600, 900);
//   return 0;
// }







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

// int main2() {

//   dip::testing::Timer timer;
//   timer.Reset();
//    // auto a = dip::ImageRead("/home/test/Downloads/diplib-3.1.0/build/examples/Ef8ey.jpeg");
//   // auto a = dip::ImageRead("/home/test/Downloads/diplib-3.1.0/examples/bdm4.jpeg");
//   auto a = dip::ImageRead("/home/test/Downloads/diplib-3.1.0/examples/samples/debug2.jpeg");
//   a.ResetPixelSize();

//   dip::Image circle;
  
//   circle = dip::Image(a.Sizes(), 1, dip::DT_DFLOAT);
//   circle.Fill(0);

//   dip::DrawBandlimitedBall(circle, 215.0, {501.8,460.1}, {1}, "empty");
//   // dip::DrawEllipsoid(circle, {201.1, 199.5}, {559.7,607.1}, {1});
//   circle /= dip::Maximum(circle);

//   a *= 1 - circle;
//   dip::Image my0d({0,255,0});
//   a += circle * my0d;


//   dip::viewer::Show(a);

//   dip::viewer::Spin(); 
//   return 0;
  
//    // a = a[1];  // Use green channel only, simple way to convert to gray scale

//    dip::Gauss(a, a, {2});

//    dip::Image b;
//    double t = dip::Threshold(a, b);
//    std::cout << "Threshold: " << t << '\n';

//    b = a < t; // Or: dip::Invert(b,b);
   
//    // dip::viewer::Show(EdgeObjectsRemove(b));
   
//    b = dip::BinaryAreaOpening( dip::EdgeObjectsRemove( b ), 1000 );

//    // dip::viewer::Show(b);

//    auto m = dip::Label(b);
//    dip::MeasurementTool measurementTool;
//    auto msr = measurementTool.Measure(m, {}, { "Center"});
//    std::cout << msr << '\n';


//    // dip::viewer::Show(-dip::ErfClip(a, t, 30));

//    auto c = dip::ContrastStretch(-dip::ErfClip(a, t, 30));

//    // dip::viewer::Show(c);

//    dip::GrowRegions(m, {}, m, -2, 2);


//    msr = measurementTool.Measure(m, c, {"Gravity", "Feret", "P2A"});
//    std::cout << msr << '\n';

//    // dip::viewer::Show(m);

//    // Iterate through the measurement structure:
//    auto it = msr["Gravity"].FirstObject();

//    while(it) {
//      if(it[4] > 190 && it[4] < 215 && it[7] < 1.1) {
//        std::cout << "Centroid coordinates = " << it[0] << ", " << it[1] << '\n';
//        std::cout << "feret[0] = " << it[2] << " feret[1]" << it[3]<< '\n';
//      }
//      ++it;
//    }

//    timer.Stop();
//    double time = timer.GetWall();
//    std::cout << "time : " << time <<"\n";


//    dip::viewer::Spin();
// }


int main3() {

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

