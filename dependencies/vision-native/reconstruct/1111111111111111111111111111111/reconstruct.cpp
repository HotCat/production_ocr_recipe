
#include "reconstruct.h"

// Generate a circle pointcloud in model coordinates (XY plane)
std::vector<Eigen::Vector3d> generateCirclePoints(float canonicalRadius, int numPoints) {
  std::vector<Eigen::Vector3d> points;
    points.reserve(numPoints);
    for (int i = 0; i < numPoints; ++i) {
        float theta = (2.0f * M_PI * i) / static_cast<float>(numPoints);
        float x = canonicalRadius * std::cos(theta);
        float y = canonicalRadius * std::sin(theta);
        points.push_back(Eigen::Vector3d(x, y, 0.0f)); // z = 0 for points in the XY plane
    }
    return points;
}

std::map<std::string, Value> buildParams(std::string input) {
  std::istringstream iss(input);
  std::string token;
  std::map<std::string, Value> myMap;

  while (std::getline(iss, token, ';')) {
    std::istringstream token_ss(token);
    std::string key;
    std::getline(token_ss, key, ',');
    key.erase(0, key.find_first_not_of(" \t\r\n"));
    key.erase(key.find_last_not_of(" \t\r\n") + 1);

    if (!key.empty()) {
      std::string value_str;
      std::getline(token_ss, value_str);
      value_str.erase(0, value_str.find_first_not_of(" \t\r\n"));
      value_str.erase(value_str.find_last_not_of(" \t\r\n") + 1);

      if (!value_str.empty()) {
        Value value;
        if (value_str[0] == '\"' && value_str.back() == '\"') {
          value = value_str.substr(1, value_str.size() - 2);
        } else {
          try {
            size_t pos;
	    int int_val = std::stoi(value_str, &pos);
            if (pos == value_str.size()) {
              value = int_val;
            } else {
              double double_val = std::stod(value_str, &pos);
              if (pos == value_str.size()) {
                value = double_val;
              }
            }
          } catch (const std::exception& e) {
            // Parsing error
            continue;
          }
        }

        myMap[key] = value;
      }
    }
  }
  return myMap;
}


Eigen::Vector2d CalibrateNozzleCenter(const open3d::geometry::PointCloud& pointcloud, double resolution, double distance) {

    cv::Mat depth_map;
    cv::Mat flattened_image;

    if (pointcloud.IsEmpty()) {
        throw std::runtime_error("Point cloud is empty.");
    }

    auto pcd = &pointcloud;
    pcd->RemoveStatisticalOutliers(15, 1.0);

    std::vector<size_t> inliers;
    Eigen::Vector4d plane_model;
    double distance_threshold = distance; // Adjust this value based on your needs
    int ransac_n = 3;
    int num_iterations = 1000;
    std::tie(plane_model, inliers) = pointcloud.SegmentPlane(distance_threshold, ransac_n, num_iterations);

    auto plane_points = pointcloud.SelectByIndex(inliers);

    // Get bounding box of the point cloud
    auto bbox = plane_points->GetAxisAlignedBoundingBox();
    Eigen::Vector3d min_bound = bbox.min_bound_;
    Eigen::Vector3d max_bound = bbox.max_bound_;

    // Calculate dimensions of the output images
    int width = static_cast<int>((max_bound[0] - min_bound[0]) / resolution) + 1;
    int height = static_cast<int>((max_bound[1] - min_bound[1]) / resolution) + 1;

    // Initialize arrays for depth map and flattened image
    depth_map = cv::Mat::zeros(height, width, CV_32FC1); // Depth map as float
    flattened_image = cv::Mat::zeros(height, width, CV_8UC1); // Flattened binary image

    // Fill the depth map and flattened image
    for (const auto& point : plane_points->points_) {
        int x_idx = static_cast<int>((point[0] - min_bound[0]) / resolution);
        int y_idx = static_cast<int>((point[1] - min_bound[1]) / resolution);

        // Update depth map with Z value
        depth_map.at<float>(y_idx, x_idx) = static_cast<float>(point[2]);

	// Flattened image marks the presence of a point
        flattened_image.at<uchar>(y_idx, x_idx) = 255;
    }

    std::cout << "in step1 ..." << std::endl;

    dip::Image dipImage = dip_opencv::MatToDip(flattened_image);
    dip::Image dipImage2;

    dipImage2 = dipImage.Copy();

    // Thresholding
    dipImage2 = dipImage2 > 0;

    std::cout << "in step2 ..." << std::endl;

    dipImage2.Convert(dip::DT_BIN);

    std::cout << "in step3 ... " << std::endl;

    dipImage2 = dip::FillHoles(dipImage2);

    std::cout << "in step4 ... " << std::endl;
    
    // Morphological Opening
    dipImage2 = dip::Opening(dip::Closing(dipImage2, 5), 5);

    std::cout << "in step5 ... " << std::endl;

    // inverse images
    dipImage2 = dipImage2 < 1;

    // Remove edge objects
    dipImage2 = dip::EdgeObjectsRemove(dipImage2);

    std::cout << "in step6 ... " << std::endl;

    // Labeling connected regions
    dipImage2 = dip::Label(dipImage2, 0, 30000);

    std::cout << "in step7 ... " << std::endl;

    // Measure the convex hull and compute the center point using DIPlib
    dip::MeasurementTool msrTool;
    auto measurements = msrTool.Measure(dipImage2, {}, {"Center"}, {}, 1);

    std::cout << "in step8 ... " << std::endl;

    if (!measurements.FirstObject()) {
        throw std::runtime_error("No regions found in the binary image for measurement.");
    }

    // Extract the first region's center point
    auto centerDip = measurements[1]["Center"];
    Eigen::Vector2d center(centerDip[0], centerDip[1]);

    std::cout << "in step8 ... " << std::endl;

    // Convert center back to 3D coordinates
    Eigen::Vector3d center_3d;
    center_3d[0] = min_bound[0] + center(0) * resolution;
    center_3d[1] = min_bound[1] + center(1) * resolution;

    center_3d[2] = 0.0; // Assume Z is 0 since we're working with a flattened image

    Eigen::Vector2d center_2d(center_3d[0],center_3d[1]);
    
    return center_2d;
}


std::tuple<Eigen::Vector2d, double, double, double> LabelCenterAndOrientation(const open3d::geometry::PointCloud& pointcloud, double resolution) {

    cv::Mat depth_map;
    cv::Mat flattened_image;

    if (pointcloud.IsEmpty()) {
        throw std::runtime_error("Point cloud is empty.");
    }

    auto pcd = &pointcloud;
    pcd->RemoveStatisticalOutliers(6, 1.0);
    // pcd->RemoveStatisticalOutliers(15, 1.0);

    // Get bounding box of the point cloud
    auto bbox = pointcloud.GetAxisAlignedBoundingBox();
    Eigen::Vector3d min_bound = bbox.min_bound_;
    Eigen::Vector3d max_bound = bbox.max_bound_;

    // Calculate dimensions of the output images
    int width = static_cast<int>((max_bound[0] - min_bound[0]) / resolution) + 1;
    int height = static_cast<int>((max_bound[1] - min_bound[1]) / resolution) + 1;

    // Initialize arrays for depth map and flattened image
    depth_map = cv::Mat::zeros(height, width, CV_32FC1); // Depth map as float
    flattened_image = cv::Mat::zeros(height, width, CV_8UC1); // Flattened binary image

    // Fill the depth map and flattened image
    for (const auto& point : pointcloud.points_) {
        int x_idx = static_cast<int>((point[0] - min_bound[0]) / resolution);
        int y_idx = static_cast<int>((point[1] - min_bound[1]) / resolution);

        // Update depth map with Z value
        depth_map.at<float>(y_idx, x_idx) = static_cast<float>(point[2]);

	// Flattened image marks the presence of a point
        flattened_image.at<uchar>(y_idx, x_idx) = 255;
    }

    std::cout << "in step1 ..." << std::endl;

    dip::Image dipImage = dip_opencv::MatToDip(flattened_image);
    dip::Image dipImage2;

    dipImage2 = dipImage.Copy();

    // Thresholding
    dipImage2 = dipImage2 > 0;

    std::cout << "in step2 ..." << std::endl;

    dipImage2.Convert(dip::DT_BIN);

    std::cout << "in step3 ... " << std::endl;

    dipImage2 = dip::FillHoles(dipImage2);

    std::cout << "in step4 ... " << std::endl;
    
    // Morphological Opening
    dipImage2 = dip::Opening(dip::Closing(dipImage2, 5), 5);

    std::cout << "in step5 ... " << std::endl;

    // Labeling connected regions
    dipImage2 = dip::Label(dipImage2, 0, 30000);

    // Make regions convex
    dipImage2 = dip::MakeRegionsConvex2D(dipImage2);

    std::cout << "in step6 ... " << std::endl;

    // Measure the convex hull and compute the center point using DIPlib
    dip::MeasurementTool msrTool;
    auto measurements = msrTool.Measure(dipImage2, {}, {"Center"}, {}, 1);

    std::cout << "in step7 ... " << std::endl;

    if (!measurements.FirstObject()) {
        throw std::runtime_error("No regions found in the binary image for measurement.");
    }

    // Extract the first region's center point
    auto centerDip = measurements[1]["Center"];
    Eigen::Vector2d center(centerDip[0], centerDip[1]);

    std::cout << "in step8 ... " << std::endl;

    // Find contours in the binary image using OpenCV
    std::vector<std::vector<cv::Point>> contours;

    dipImage2.Convert(dip::DT_UINT8);
    dipImage2.At(dipImage2 > 0) = 255;
    cv::findContours(dip_opencv::CopyDipToMat(dipImage2), contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    if (contours.empty()) {
        throw std::runtime_error("No contours found in the binary image.");
    }

    // Find the largest contour
    size_t largestContourIdx = 0;
    double maxArea = 0.0;
    for (size_t i = 0; i < contours.size(); ++i) {
        double area = cv::contourArea(contours[i]);
        if (area > maxArea) {
            maxArea = area;
            largestContourIdx = i;
        }
    }

    const auto& largestContour = contours[largestContourIdx];

    // Compute convex hull
    std::vector<cv::Point> hull;
    cv::convexHull(largestContour, hull);

    // Compute the minimum area rectangle
    cv::RotatedRect minAreaRect = cv::minAreaRect(hull);

    double w = minAreaRect.size.width;
    double h = minAreaRect.size.height;

    std::cout << "minAreaRect.size.width: " << w << std::endl;
    std::cout << "minAreaRect.size.height: " << h << std::endl;

    // Extract the orientation angle of the rectangle
    double angle = minAreaRect.angle;
    if (angle < -45.0) {
        angle += 90.0; // Normalize angle to [-45, 45] range
    }

    // Convert center back to 3D coordinates
    Eigen::Vector3d center_3d;
    center_3d[0] = min_bound[0] + center(0) * resolution;
    center_3d[1] = min_bound[1] + center(1) * resolution;

    center_3d[2] = 0.0; // Assume Z is 0 since we're working with a flattened image

    Eigen::Vector2d center_2d(center_3d[0],center_3d[1]);
    
    return std::make_tuple(center_2d, angle, w, h);
}


std::tuple<Eigen::Vector2d, double> ProductCenterAndOrientation(const open3d::geometry::PointCloud& pointcloud, double resolution, double distance) {

    cv::Mat depth_map;
    cv::Mat flattened_image;

    if (pointcloud.IsEmpty()) {
        throw std::runtime_error("Point cloud is empty.");
    }

    std::vector<size_t> inliers;
    Eigen::Vector4d plane_model;
    double distance_threshold = distance; // Adjust this value based on your needs
    int ransac_n = 3;
    int num_iterations = 1000;
    std::tie(plane_model, inliers) = pointcloud.SegmentPlane(distance_threshold, ransac_n, num_iterations);

    auto plane_points = pointcloud.SelectByIndex(inliers);

    io::WritePointCloudToPLY("/home/hotcat/Downloads/dipexp/label/debug.ply", *plane_points, true);

    // Get bounding box of the point cloud
    auto bbox = plane_points->GetAxisAlignedBoundingBox();
    Eigen::Vector3d min_bound = bbox.min_bound_;
    Eigen::Vector3d max_bound = bbox.max_bound_;

    // Calculate dimensions of the output images
    int width = static_cast<int>((max_bound[0] - min_bound[0]) / resolution) + 1;
    int height = static_cast<int>((max_bound[1] - min_bound[1]) / resolution) + 1;

    // Initialize arrays for depth map and flattened image
    depth_map = cv::Mat::zeros(height, width, CV_32FC1); // Depth map as float
    flattened_image = cv::Mat::zeros(height, width, CV_8UC1); // Flattened binary image

    // Fill the depth map and flattened image
    for (const auto& point : plane_points->points_) {
        int x_idx = static_cast<int>((point[0] - min_bound[0]) / resolution);
        int y_idx = static_cast<int>((point[1] - min_bound[1]) / resolution);

        // Update depth map with Z value
        depth_map.at<float>(y_idx, x_idx) = static_cast<float>(point[2]);

	// Flattened image marks the presence of a point
        flattened_image.at<uchar>(y_idx, x_idx) = 255;
    }

    std::cout << "in step1 ..." << std::endl;

    dip::Image dipImage = dip_opencv::MatToDip(depth_map);
    dip::Image dipImage2;

    dipImage2 = dipImage.Copy();

    // Thresholding
    dipImage2 = dipImage2 < 1;

    std::cout << "in step2 ..." << std::endl;

    dipImage2.Convert(dip::DT_BIN);

    // // Remove edge objects
    // dipImage2 = dip::EdgeObjectsRemove(dipImage2);

    std::cout << "in step3 ... " << std::endl;
    
    // Morphological Opening
    dipImage2 = dip::Opening(dipImage2, 50);

    std::cout << "in step4 ... " << std::endl;

    // Labeling connected regions
    dipImage2 = dip::Label(dipImage2, 0, 40000);

    std::cout << "in step5 ... " << std::endl;

    dipImage2.Convert(dip::DT_BIN);
    dipImage2 = dip::EdgeObjectsRemove(dipImage2);

    std::cout << "in step6 ... " << std::endl;

    // Make regions convex
    dipImage2 = dip::MakeRegionsConvex2D(dipImage2);

    // Labeling connected regions
    dipImage2 = dip::Label(dipImage2, 0, 40000);

    // Measure the convex hull and compute the center point using DIPlib
    dip::MeasurementTool msrTool;
    auto measurements = msrTool.Measure(dipImage2, {}, {"Center"}, {}, 1);

    std::cout << "in step7 ... " << std::endl;

    if (!measurements.FirstObject()) {
        throw std::runtime_error("No regions found in the binary image for measurement.");
    }

    // Extract the first region's center point
    auto centerDip = measurements[1]["Center"];
    Eigen::Vector2d center(centerDip[0], centerDip[1]);

    std::cout << "in step8 ... " << std::endl;

    // Find contours in the binary image using OpenCV
    std::vector<std::vector<cv::Point>> contours;

    dipImage2.Convert(dip::DT_UINT8);
    dipImage2.At(dipImage2 > 0) = 255;
    cv::findContours(dip_opencv::CopyDipToMat(dipImage2), contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    if (contours.empty()) {
        throw std::runtime_error("No contours found in the binary image.");
    }

    // Find the largest contour
    size_t largestContourIdx = 0;
    double maxArea = 0.0;
    for (size_t i = 0; i < contours.size(); ++i) {
        double area = cv::contourArea(contours[i]);
        if (area > maxArea) {
            maxArea = area;
            largestContourIdx = i;
        }
    }

    const auto& largestContour = contours[largestContourIdx];

    // Compute convex hull
    std::vector<cv::Point> hull;
    cv::convexHull(largestContour, hull);

    // Compute the minimum area rectangle
    cv::RotatedRect minAreaRect = cv::minAreaRect(hull);

    // Extract the orientation angle of the rectangle
    double angle = minAreaRect.angle;
    if (angle < -45.0) {
        angle += 90.0; // Normalize angle to [-45, 45] range
    }

    // Convert center back to 3D coordinates
    Eigen::Vector3d center_3d;
    center_3d[0] = min_bound[0] + center(0) * resolution;
    center_3d[1] = min_bound[1] + center(1) * resolution;
    center_3d[2] = 0.0; // Assume Z is 0 since we're working with a flattened image

    Eigen::Vector2d center_2d(center_3d[0],center_3d[1]);
    
    return std::make_tuple(center_2d, angle);
}


void ConvertPointCloudTo2D(const std::string &ply_file, const std::string &depth_map_file, const std::string &flattened_image_file, float resolution = 0.1) {
    // Load the point cloud
    auto pointcloud = std::make_shared<open3d::geometry::PointCloud>();
    if (!open3d::io::ReadPointCloud(ply_file, *pointcloud)) {
        std::cerr << "Failed to read point cloud from " << ply_file << std::endl;
        return;
    }

    // Find the bounds of the point cloud
    auto bbox = pointcloud->GetAxisAlignedBoundingBox();
    Eigen::Vector3d min_bound = bbox.min_bound_;
    Eigen::Vector3d max_bound = bbox.max_bound_;

    // Calculate the dimensions of the output images
    int width = static_cast<int>((max_bound[0] - min_bound[0]) / resolution) + 1;
    int height = static_cast<int>((max_bound[1] - min_bound[1]) / resolution) + 1;

    // Initialize depth map and flattened image
    cv::Mat depth_map = cv::Mat::zeros(height, width, CV_32F);
    cv::Mat flattened_image = cv::Mat::zeros(height, width, CV_8U);

    // Fill the depth map and flattened image
    for (const auto &point : pointcloud->points_) {
        int x_idx = static_cast<int>((point[0] - min_bound[0]) / resolution);
        int y_idx = static_cast<int>((point[1] - min_bound[1]) / resolution);
        float z_value = static_cast<float>(point[2]);

        // Update depth map with Z value
        depth_map.at<float>(y_idx, x_idx) = z_value;

        // Flattened image ignores Z
        flattened_image.at<uchar>(y_idx, x_idx) = 255; // Mark presence
    }

    // Save the depth map
    // cv::Mat depth_map_8u;
    // depth_map.convertTo(depth_map_8u, CV_8U, 255.0 / (max_bound[2] - min_bound[2])); // Normalize for visualization
    // cv::imwrite(depth_map_file, depth_map_8u);

    dip::Image dip_image = dip_opencv::MatToDip(depth_map);
    dip::ImageWriteICS(dip_image, depth_map_file);

    // cv::imwrite(depth_map_file, depth_map);

    // Save the flattened image
    cv::imwrite(flattened_image_file, flattened_image);

    std::cout << "Depth map saved to " << depth_map_file << std::endl;
    std::cout << "Flattened image saved to " << flattened_image_file << std::endl;
}

Reconstruct::Reconstruct() {
  calib.load("/home/hotcat/Downloads/new3dvision/controller/1/calibration.xml");
  triangulator = new Triangulator(calib);

  open3d::geometry::PointCloud cloud;
  // if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/Multiple_Planes_Detection/1/trans5.ply", cloud)) {
  // if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/1/decoder/research6.ply", cloud)) {
  // if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/dipexp/label/my5.ply", cloud)) {
  if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/1/decoder/my.ply", cloud)) {
    std::cout << "Successfully read point cloud." << std::endl;
  } else {
    std::cerr << "Failed to read point cloud" << std::endl;
    CV_Assert(false);
  }

  matSequence.clear();
  transiPC.clear();

  pointCloud = cloud;

  for(auto& point : cloud.points_) {
    point(1) = -point(1);
    point(2) = -point(2);
  }

  for (size_t i = 0; i < cloud.points_.size(); ++i) {
    const auto& point = cloud.points_[i];
    const auto& color = cloud.colors_[i];

    transiPC.push_back(static_cast<float>(point(0)));
    transiPC.push_back(static_cast<float>(-point(1)));
    transiPC.push_back(static_cast<float>(-point(2)));

    transiPC.push_back(static_cast<float>(color(0)));
    transiPC.push_back(static_cast<float>(color(1)));
    transiPC.push_back(static_cast<float>(color(2)));
    transiPC.push_back(static_cast<float>(1.0));
  }

  plane_a = 0;
  plane_b = 0;
  plane_c = 1;
  plane_d = 0;

  profiloBlend = 1.0;

  labelPC.Clear();
  labelTempPC.Clear();
  productPC.Clear();
  productTempPC.Clear();
  convPlanePC.Clear();

  transiLabel.clear();
  transiLabelTemp.clear();
  transiProduct.clear();
  transiProductTemp.clear();
  transiConvPlane.clear();

  altTransform = Eigen::Matrix4d::Zero();

  if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/1/decoder/labelTempPC.ply", labelTempPC)) {
    std::cout << "Successfully read labelTempPC." << std::endl;
  } else {
    std::cerr << "Failed to read labelTempPC" << std::endl;
    CV_Assert(false);
  }

  if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/1/decoder/productTempPC.ply", productTempPC)) {
    std::cout << "Successfully read productTempPC." << std::endl;
  } else {
    std::cerr << "Failed to read productTempPC" << std::endl;
    CV_Assert(false);
  }

  calibSequence = -100;
  labelResolution = 0.07;
  productResolution = 0.07;
  distanceThreshold = 0.09;

  std::string ply_file = "/home/hotcat/Downloads/new3dvision/controller/1/decoder/labelTempPC.ply";
  std::string depth_map_file = "/dev/shm/depth_map.ics";
  std::string flattened_image_file = "/dev/shm/flattened_image.png";
  ConvertPointCloudTo2D(ply_file, depth_map_file, flattened_image_file, 0.05);

  // Parameters for the circle
  float canonicalRadius = 1.0f; // Unit circle in model coordinates
  int numPoints = 10000;          // Adjust for desired granularity

  // Generate circle points
  std::vector<Eigen::Vector3d> circlePoints = generateCirclePoints(canonicalRadius, numPoints);

  // Create an Open3D point cloud and add the generated points
  open3d::geometry::PointCloud circlePC;
  for (const auto& pt : circlePoints) {
    // Convert glm::vec3 to Eigen::Vector3d
    circlePC.points_.push_back(pt);
  }

  // Optionally, you can assign colors to the points
  // Here we assign a uniform red color to all points
  circlePC.colors_.resize(circlePC.points_.size(), Eigen::Vector3d(1.0, 0.0, 0.0));

  // Save the point cloud to a PLY file using Open3D
  bool success = open3d::io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/decoder/circle.ply", circlePC, true);
  if (success) {
    std::cout << "Circle pointcloud saved successfully to circle.ply" << std::endl;
  } else {
    std::cerr << "Failed to save pointcloud." << std::endl;
  }

}


Reconstruct::~Reconstruct() {
}


int Reconstruct::addFrame(const cv::Mat& mat, int thresh) {
  if(matSequence.size() < 6) {
    std::vector<cv::Mat> channels;
    cv::split(mat, channels);
    matSequence.push_back(channels[0]);
  } else CV_Assert(false);

  // Check if we have collected 6 Mat objects
  if(matSequence.size() == 6) {
    convertToPointCloud(matSequence, thresh);
    matSequence.clear();
    return 1;
  }
  return 0;
}


std::vector<float> Reconstruct::exportPC(int index) {
  switch (index) {
    case 0:
      return transiLabel;
    case 1:
      return transiProduct;
    case 2:
      return transiLabelTemp;
    case 3:
      return transiProductTemp;
    case 4:
      return transiPC;
    case 5:
      return transiConvPlane;
  }
}


void Reconstruct::findPlane() {
  auto pcd = std::make_shared<open3d::geometry::PointCloud>();
  // if (!open3d::io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/1/decoder/my2.ply", *pcd)) {
  if (!open3d::io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/1/decoder/convPlanePC.ply", *pcd)) {
    std::cerr << "Failed to read point cloud" << std::endl;
    CV_Assert(false);
  }

  // Segment plane
  std::vector<size_t> inliers;
  Eigen::Vector4d plane_model;
  double distance_threshold = 0.01; // Adjust this value based on your needs
  int ransac_n = 3;
  int num_iterations = 1000;

  std::tie(plane_model, inliers) = pcd->SegmentPlane(
						     distance_threshold, ransac_n, num_iterations);

  std::cout << "Plane equation: " << plane_model(0) << "x + " << plane_model(1) 
            << "y + " << plane_model(2) << "z + " << plane_model(3) << " = 0" << std::endl;

  plane_a = plane_model(0);
  plane_b = plane_model(1);
  plane_c = plane_model(2);
  plane_d = plane_model(3);
  return;
}


geometry::PointCloud Reconstruct::convertToPointCloud(const std::vector<cv::Mat>& mats, int thresh) {
  unsigned int screenResX, screenResY;

  screenResX = calib.screenResX;
  screenResY = calib.screenResY;

  std::cout << "decoder: " << screenResX << '\n' << screenResY << '\n';

  const std::string codecName = "PhaseShift2x3";
  std::unique_ptr<Decoder> decoder;
  decoder = DecoderFactory::NewDecoder(Codecs.at(codecName), screenResX, screenResY, CodecDirHorizontal);

  for (size_t i = 0; i < 6; ++i) {
    decoder->setFrame(i, mats[i]);
  }

  cv::Mat mask(mats[0].size(), cv::DataType<bool>::type);
  cv::Mat shading(mats[0].size(), CV_8U);

  cv::Mat up, vp;
  up.create(mats[0].size(), CV_32FC1);

  decoder->decodeFrames(up, vp, mask, shading);

  mask = shading > thresh;

  cv::imwrite("/home/hotcat/Downloads/new3dvision/controller/1/decoder/up.tiff", up);
  cv::imwrite("/home/hotcat/Downloads/new3dvision/controller/1/decoder/mask.png", mask);
  cv::imwrite("/home/hotcat/Downloads/new3dvision/controller/1/decoder/shading.png", shading);

  cv::Mat deepMat;
  triangulator->triangulate(up, vp, mask, shading, deepMat);

  // Create an empty PointCloud
  // geometry::PointCloud pointCloud;
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

  if(profiloBlend != 0.0) {
    alignGrid(pointCloud);
    computePitchAngle();
  }

  // NormalizePC(pointCloud);

  transiPC.clear();

  for(auto& point : pointCloud.points_) {
    point(1) = -point(1);
    point(2) = -point(2);
  }

  for (size_t i = 0; i < pointCloud.points_.size(); ++i) {
    const auto& point = pointCloud.points_[i];
    const auto& color = pointCloud.colors_[i];

    transiPC.push_back(static_cast<float>(point(0)));
    transiPC.push_back(static_cast<float>(point(1)));
    transiPC.push_back(static_cast<float>(point(2)));

    transiPC.push_back(static_cast<float>(color(0)));
    transiPC.push_back(static_cast<float>(color(1)));
    transiPC.push_back(static_cast<float>(color(2)));
    transiPC.push_back(static_cast<float>(profiloBlend));
  }

  std::cout << "point cloud size: " << pointCloud.points_.size() << '\n';
  std::cout << "transiPC size: " << transiPC.size() << '\n';

  io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/my.ply", pointCloud, true);

  return pointCloud;
}


std::shared_ptr<open3d::geometry::OrientedBoundingBox> CreateClippingBox(const std::vector<Eigen::Vector3f>& vertices) {
  // Convert Eigen::Vector3f points to Eigen::Vector3d
  std::vector<Eigen::Vector3d> points(vertices.size());
  for(size_t i = 0; i < vertices.size(); ++i) {
    points[i] = vertices[i].cast<double>();
  }

  // Create OrientedBoundingBox from points
  auto obb = open3d::geometry::OrientedBoundingBox::CreateFromPoints(points);
  return std::make_shared<open3d::geometry::OrientedBoundingBox>(obb);
}


double Reconstruct::computePitchAngle() {

  // Assume a, b, c, d are the parameters of the plane and theta is the rotation angle
  double a = plane_a, b = plane_b, c = plane_c, d = plane_d;

  // Normal vector of the plane
  Eigen::Vector3d normal(a, b, c);

  // Z-axis vector (normal to the XY plane)
  Eigen::Vector3d z_axis(0, 0, 1);

  // Compute the magnitude of the normal vector
  double normal_magnitude = normal.norm();

  // Compute the cosine of the angle between the normal vector and the Z-axis
  double cos_theta = c / normal_magnitude;

  // Compute the angle between the normal vector and the Z-axis
  double angle_with_xy_plane = std::acos(cos_theta);

  // Convert the angle from radians to degrees
  double angle_in_degrees = angle_with_xy_plane * 180.0 / M_PI;

  std::cout << "Angle between the rotation axis and the XY plane: " << angle_in_degrees << " degrees" << std::endl;

  return angle_in_degrees;
}


int Reconstruct::alignGrid(open3d::geometry::PointCloud& pointCloud) {
  // Read the point cloud
  // auto pcd = std::make_shared<open3d::geometry::PointCloud>(pointCloud);
  auto& pcd = pointCloud; // Reference to the original point cloud

  // Define plane parameters (replace these with your actual values)
  double a = plane_a;
  double b = plane_b;
  double c = plane_c;
  double d = plane_d;

  std::cout << "a:" << a << " b:" << b << " c:" << c << " d:" << d << std::endl;

  // Translate plane to coordinate center
  Eigen::Vector3d translation(0, 0, d / c);
  pcd.Translate(translation, true);

  // Calculate the angle between plane normal and z-axis
  double cos_theta = c / std::sqrt(a * a + b * b + c * c);
  double sin_theta = std::sqrt(1 - cos_theta * cos_theta);
  double theta = std::acos(cos_theta);

  // Calculate rotation axis
  Eigen::Vector3d rotation_axis(b / std::sqrt(a * a + b * b), -a / std::sqrt(a * a + b * b), 0);

  // Generate rotation matrix
  Eigen::Matrix3d R = open3d::geometry::Geometry3D::GetRotationMatrixFromAxisAngle(rotation_axis * theta);

  // Rotate the point cloud
  pcd.Rotate(R, Eigen::Vector3d(0, 0, 0));

  // Save the transformed point cloud
  if (!open3d::io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/transformed.ply", pcd, true)) {
    std::cerr << "Failed to write transformed point cloud!" << std::endl;
    return -1;
  }

  return 0;
}


void Reconstruct::NormalizePC(open3d::geometry::PointCloud& pointcloud) {
  // Find the maximum distance from the origin (norm of the points)
  double max_distance = 0.0;
  for (const auto& point : pointcloud.points_) {
    double distance = point.norm();
    if (distance > max_distance) {
      max_distance = distance;
    }
  }

  // Scale the points so that the maximum distance is 1 (unit sphere)
  for (auto& point : pointcloud.points_) {
    point /= max_distance;
  }
}


// Helper function for debugging
void PrintVector(const std::vector<Eigen::Vector3d>& vec, const std::string& label) {
    std::cout << label << ": [";
    for (const auto& v : vec) {
        std::cout << "(" << v.x() << ", " << v.y() << ", " << v.z() << "), ";
    }
    std::cout << "]" << std::endl;
}


std::shared_ptr<geometry::OrientedBoundingBox> Reconstruct::CreateOrientedBoundingBox(const Eigen::Matrix4f& model_matrix, const std::array<float, 6>& local_bounds) {
    // Step 1: Define the 8 corners of the local bounding box (unit cube in this case)
    std::vector<Eigen::Vector3d> corners = {
        {local_bounds[0], local_bounds[1], local_bounds[2]},  // (-0.5, -0.5, -0.5)
        {local_bounds[3], local_bounds[1], local_bounds[2]},  // (0.5, -0.5, -0.5)
        {local_bounds[3], local_bounds[4], local_bounds[2]},  // (0.5, 0.5, -0.5)
        {local_bounds[0], local_bounds[4], local_bounds[2]},  // (-0.5, 0.5, -0.5)
        {local_bounds[0], local_bounds[1], local_bounds[5]},  // (-0.5, -0.5, 0.5)
        {local_bounds[3], local_bounds[1], local_bounds[5]},  // (0.5, -0.5, 0.5)
        {local_bounds[3], local_bounds[4], local_bounds[5]},  // (0.5, 0.5, 0.5)
        {local_bounds[0], local_bounds[4], local_bounds[5]}   // (-0.5, 0.5, 0.5)
    };

    // Step 2: Transform corners using the model matrix to world coordinates
    std::vector<Eigen::Vector3d> transformed_corners;
    for (const auto& corner : corners) {
        Eigen::Vector4f homogenous_corner(corner.x(), corner.y(), corner.z(), 1.0f);  // Convert to homogeneous coordinates
        Eigen::Vector4f transformed_corner = model_matrix * homogenous_corner;        // Apply transformation

        // Step 3: Scale the transformed corners by a factor of 10
        Eigen::Vector3d scaled_corner = (transformed_corner.head<3>() * 10.0f).cast<double>(); // Scale and cast to double
        transformed_corners.push_back(scaled_corner);   // Add scaled corner to the list
    }

    // Step 4: Extract rotation matrix and translation (center) from model_matrix
    Eigen::Matrix3d R = model_matrix.block<3, 3>(0, 0).cast<double>();
    Eigen::Vector3d world_center = model_matrix.block<3, 1>(0, 3).cast<double>() * 10.0;

    // Step 5: Compute extent in the local coordinate system of the OBB
    // Transform the corners to the OBB's local coordinate system
    Eigen::Matrix3d R_inv = R.transpose(); // Inverse of rotation matrix is its transpose
    std::vector<Eigen::Vector3d> local_corners;
    for (const auto& corner : transformed_corners) {
        local_corners.push_back(R_inv * (corner - world_center));
    }

    // Step 6: Find min and max in the OBB's local coordinates to compute extent
    Eigen::Vector3d min_corner = local_corners[0];
    Eigen::Vector3d max_corner = local_corners[0];
    for (const auto& corner : local_corners) {
        min_corner = min_corner.cwiseMin(corner);
        max_corner = max_corner.cwiseMax(corner);
    }

    // The extent is the difference between max and min in each local direction
    Eigen::Vector3d extent = max_corner - min_corner;

    // Step 7: Create the Oriented Bounding Box with the calculated center, rotation, and extent
    auto obb = std::make_shared<geometry::OrientedBoundingBox>();
    obb->center_ = world_center;
    obb->R_ = R;
    obb->extent_ = extent;

    return obb;
}


void Reconstruct::applyTransform(Eigen::Matrix4f & matrix, int index) {
  Eigen::Matrix4d matrix4d = matrix.cast<double>();
  std::vector<float>* myPC;
  open3d::geometry::PointCloud* cloud;

  switch(index) {
    case 0:
      labelPC.Transform(matrix4d);
      myPC = &transiLabel;
      cloud = &labelPC;
      io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/labelPC.ply", labelPC, true);
      break;

    case 1:
      productPC.Transform(matrix4d);
      myPC = &transiProduct;
      cloud = &productPC;
      io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/productPC.ply", productPC, true);
      break;

    case 2:
      labelTempPC.Transform(matrix4d);
      myPC = &transiLabelTemp;
      cloud = &labelTempPC;
      io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/labelTempPC.ply", labelTempPC, true);
      break;

    case 3:
      productTempPC.Transform(matrix4d);
      myPC = &transiProductTemp;
      cloud = &productTempPC;
      io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/productTempPC.ply", productTempPC, true);
      break;

    case 5:
      convPlanePC.Transform(matrix4d);
      myPC = &transiConvPlane;
      cloud = &convPlanePC;
      break;

    default:
      return;
  }

  myPC->clear();

  for (size_t i = 0; i < (*cloud).points_.size(); ++i) {
    const auto& point = (*cloud).points_[i];
    const auto& color = (*cloud).colors_[i];

    myPC->push_back(static_cast<float>(point(0)));
    myPC->push_back(static_cast<float>(point(1)));
    myPC->push_back(static_cast<float>(point(2)));

    myPC->push_back(static_cast<float>(color(0)));
    myPC->push_back(static_cast<float>(color(1)));
    myPC->push_back(static_cast<float>(color(2)));
    myPC->push_back(static_cast<float>(1.0));
  }
}



void saveTransformationToFile(const Eigen::Matrix4d& transformation, const std::string& filename) {
    std::ofstream file(filename);
    if (!file) {
        std::cerr << "Error opening file for writing: " << filename << std::endl;
        return;
    }

    // Save the matrix row by row
    for (int i = 0; i < transformation.rows(); ++i) {
        for (int j = 0; j < transformation.cols(); ++j) {
            file << transformation(i, j);
            if (j < transformation.cols() - 1) {
                file << " "; // Space between elements
            }
        }
        file << "\n"; // Newline after each row
    }

    file.close();
    std::cout << "Transformation saved to " << filename << std::endl;
}


Eigen::Matrix4d loadTransformationFromFile(const std::string& filename) {
    std::ifstream file(filename);
    if (!file) {
        throw std::runtime_error("Error opening file for reading: " + filename);
    }

    Eigen::Matrix4d transformation;
    for (int i = 0; i < transformation.rows(); ++i) {
        for (int j = 0; j < transformation.cols(); ++j) {
            file >> transformation(i, j);
        }
    }

    file.close();
    std::cout << "Transformation loaded from " << filename << std::endl;
    return transformation;
}


// Cost function for Ceres optimization
struct RotationCenterResidual {
    RotationCenterResidual(const Eigen::Matrix3d& R, const Eigen::Vector3d& t)
        : R_(R), t_(t) {}

    template <typename T>
    bool operator()(const T* const center, T* residual) const {
        Eigen::Matrix<T, 3, 1> c(center[0], center[1], center[2]);
        Eigen::Matrix<T, 3, 1> predicted_t = (Eigen::Matrix<T, 3, 3>::Identity() - R_.cast<T>()) * c;
        Eigen::Matrix<T, 3, 1> diff = t_.cast<T>() - predicted_t;

        residual[0] = diff[0];
        residual[1] = diff[1];
        residual[2] = diff[2];

        return true;
    }

private:
    const Eigen::Matrix3d R_;
    const Eigen::Vector3d t_;
};


Eigen::Vector3d refineRotationCenterWithNonlinearOptimization(
    const std::vector<Eigen::Matrix3d>& rotations,
    const std::vector<Eigen::Vector3d>& translations) {
    
    // Initial guess for the rotation center
    Eigen::Vector3d initial_center(0.0, 0.0, 0.0);

    // Set up the Ceres problem
    ceres::Problem problem;

    for (size_t i = 0; i < rotations.size(); ++i) {
        problem.AddResidualBlock(
            new ceres::AutoDiffCostFunction<RotationCenterResidual, 3, 3>(
                new RotationCenterResidual(rotations[i], translations[i])),
            nullptr, // Loss function (nullptr means no robust kernel)
            initial_center.data());
    }

    // Configure the solver
    ceres::Solver::Options options;
    options.linear_solver_type = ceres::DENSE_QR;
    options.minimizer_progress_to_stdout = true;

    ceres::Solver::Summary summary;
    ceres::Solve(options, &problem, &summary);

    // Output the optimization details
    std::cout << summary.BriefReport() << std::endl;

    return initial_center;
}


// Eigen::Vector3d computeRotationPoint(const Eigen::Matrix3d& R, const Eigen::Vector3d& t) {
//     // Step 1: Construct the matrix I - R
//     Eigen::Matrix3d I_minus_R = Eigen::Matrix3d::Identity() - R;

//     // Step 2: Add regularization to handle small rotation angles
//     Eigen::Matrix3d regularization = 1e-5 * Eigen::Matrix3d::Identity();
//     Eigen::Matrix3d stabilized_matrix = I_minus_R + regularization;

//     // Step 3: Compute the pseudo-inverse using Full SVD
//     Eigen::JacobiSVD<Eigen::Matrix3d> svd(stabilized_matrix, Eigen::ComputeFullU | Eigen::ComputeFullV);
//     Eigen::Vector3d singular_values = svd.singularValues();
//     for (int i = 0; i < 3; ++i) {
//         if (singular_values(i) > 1e-6) {
//             singular_values(i) = 1.0 / singular_values(i);
//         } else {
//             singular_values(i) = 0.0;
//         }
//     }
//     Eigen::Matrix3d pseudo_inverse = svd.matrixV() * singular_values.asDiagonal() * svd.matrixU().transpose();

//     // Step 4: Compute the rotation point
//     Eigen::Vector3d rotation_point = pseudo_inverse * t;

//     return rotation_point;
// }

Eigen::Vector3d computeRotationPoint(const Eigen::Matrix3d& R, const Eigen::Vector3d& t) {
    // Step 1: Construct the matrix I - R
    Eigen::Matrix3d I_minus_R = Eigen::Matrix3d::Identity() - R;

    // Step 2: Compute the pseudo-inverse of I - R using Full SVD
    Eigen::JacobiSVD<Eigen::Matrix3d> svd(I_minus_R, Eigen::ComputeFullU | Eigen::ComputeFullV);
    
    // Handle near-zero singular values for stability
    Eigen::Vector3d singular_values = svd.singularValues();
    for (int i = 0; i < 3; ++i) {
        if (singular_values(i) > 1e-6) {  // Threshold to avoid division by very small values
            singular_values(i) = 1.0 / singular_values(i);
        } else {
            singular_values(i) = 0.0;  // Treat very small values as zero
        }
    }

    // Compute the pseudo-inverse
    Eigen::Matrix3d I_minus_R_pseudo_inverse = svd.matrixV() * singular_values.asDiagonal() * svd.matrixU().transpose();

    // Step 3: Compute the rotation point using the pseudo-inverse
    Eigen::Vector3d rotation_point = I_minus_R_pseudo_inverse * t;

    return rotation_point;
}


std::shared_ptr<geometry::PointCloud> GetOutsideOBB(const geometry::PointCloud& point_cloud, const geometry::OrientedBoundingBox& obb) {

    // Get the indices of points inside the OBB
    std::vector<size_t> inside_indices = obb.GetPointIndicesWithinBoundingBox(point_cloud.points_);

    // Use a set for fast lookup of inside indices
    std::unordered_set<size_t> inside_set(inside_indices.begin(), inside_indices.end());

    // Create new point cloud for remaining points
    auto remaining_cloud = std::make_shared<geometry::PointCloud>();

    for (size_t i = 0; i < point_cloud.points_.size(); ++i) {
        // Keep points that are NOT inside the OBB
        if (inside_set.find(i) == inside_set.end()) {
            remaining_cloud->points_.push_back(point_cloud.points_[i]);

            // Preserve color if available
            if (!point_cloud.colors_.empty()) {
                remaining_cloud->colors_.push_back(point_cloud.colors_[i]);
            }

            // Preserve normals if available
            if (!point_cloud.normals_.empty()) {
                remaining_cloud->normals_.push_back(point_cloud.normals_[i]);
            }
        }
    }

    return remaining_cloud;
}


// This function aligns the gizmo transformation based on the label¡¯s center and orientation.
// The new transformation matrix sets the translation (XY) to the label center and rotates
// the gizmo about the Z axis by the label angle. The original Z value is maintained.
Eigen::Matrix4f alignGizmoToLabel(const Eigen::Vector3d& label_center, double label_angle_degrees)
{
    // Create a new 4x4 matrix based on the original one.
    Eigen::Matrix4f gizmo_matrix = Eigen::Matrix4f::Identity();

    // Set the translation: update X and Y to the label center.
    // (Assume Z remains unchanged; if needed, you can update Z as well.)
    gizmo_matrix(0,3) = static_cast<float>(label_center(0));
    gizmo_matrix(1,3) = static_cast<float>(label_center(1));
    gizmo_matrix(2,3) = static_cast<float>(label_center(2));

    // Compute rotation about the Z axis using label_angle (convert degrees to radians)
    double angle_rad = label_angle_degrees * M_PI / 180.0;
    Eigen::Matrix3f R;
    R << static_cast<float>(std::cos(angle_rad)), static_cast<float>(-std::sin(angle_rad)), 0,
         static_cast<float>(std::sin(angle_rad)), static_cast<float>( std::cos(angle_rad)), 0,
         0,                                    0,                                   1;

    // Update the rotation portion of the gizmo matrix.
    gizmo_matrix.block<3,3>(0,0) = R;

    return gizmo_matrix;
}

// Rewritten function to compute the final gizmo model matrix.
// alignedMatrix: already aligned (center and rotation) gizmo matrix (4x4)
// canonical_bounds: the canonical dimensions of your gizmo in model space,
//                   e.g., { -w0/2, -h0/2, -t0/2, w0/2, h0/2, t0/2 }.
// desiredWidth, desiredHeight, desiredThickness: measured desired extents 
//                   (for example from your convex hull/minAreaRect) in world units.
Eigen::Matrix4f CreateGizmoModelMatrix(const Eigen::Matrix4f& alignedMatrix,
                                       float desiredWidth,
                                       float desiredHeight,
                                       float desiredThickness) {

    std::array<float,6> canonical_bounds = {-0.5f, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f };
    // Step 1: Compute the canonical gizmo¡¯s center and size from canonical_bounds.
    // For example, if your canonical gizmo is a unit box:
    float canonicalCenterX = (canonical_bounds[0] + canonical_bounds[3]) / 2.0f;
    float canonicalCenterY = (canonical_bounds[1] + canonical_bounds[4]) / 2.0f;
    float canonicalCenterZ = (canonical_bounds[2] + canonical_bounds[5]) / 2.0f;
    Eigen::Vector3f canonicalCenter(canonicalCenterX, canonicalCenterY, canonicalCenterZ);

    float canonicalWidth  = canonical_bounds[3] - canonical_bounds[0];
    float canonicalHeight = canonical_bounds[4] - canonical_bounds[1];
    float canonicalDepth  = canonical_bounds[5] - canonical_bounds[2];
    Eigen::Vector3f canonicalSize(canonicalWidth, canonicalHeight, canonicalDepth);

    // Step 2: Form the desired size vector (from your measured extents).
    Eigen::Vector3f desiredSize(desiredWidth, desiredHeight, desiredThickness);

    // Step 3: Compute the scaling factors per axis.
    Eigen::Vector3f scaleFactors = desiredSize.cwiseQuotient(canonicalSize);

    // Step 4: Build a scaling matrix (4x4).
    Eigen::Matrix4f S = Eigen::Matrix4f::Identity();
    S(0,0) = scaleFactors.x();
    S(1,1) = scaleFactors.y();
    S(2,2) = scaleFactors.z();

    // Step 5: Build a translation matrix to move the canonical gizmo¡¯s center to the origin.
    Eigen::Matrix4f T_canonical = Eigen::Matrix4f::Identity();
    T_canonical(0,3) = -canonicalCenter.x();
    T_canonical(1,3) = -canonicalCenter.y();
    T_canonical(2,3) = -canonicalCenter.z();

    // Step 6: The alignedMatrix already has the desired rotation and center.
    // Extract its translation (world center) and rotation.
    Eigen::Vector3f worldCenter = alignedMatrix.block<3,1>(0,3);
    Eigen::Matrix4f T_world = Eigen::Matrix4f::Identity();
    T_world(0,3) = worldCenter.x();
    T_world(1,3) = worldCenter.y();
    T_world(2,3) = worldCenter.z();

    // The rotation part:
    Eigen::Matrix4f R = Eigen::Matrix4f::Identity();
    R.block<3,3>(0,0) = alignedMatrix.block<3,3>(0,0);

    // Step 7: Compose the final model matrix.
    // The order here is: first translate the canonical box so its center is at the origin,
    // then scale it to the desired dimensions, then apply the rotation,
    // and finally translate it to the world center.
    Eigen::Matrix4f finalMatrix = T_world * R * S * T_canonical;

    return finalMatrix;
}

void Reconstruct::setWrapModel(Eigen::Matrix4f model_matrix) {
  wrapBoxModel = model_matrix;
}


Eigen::Matrix4f Reconstruct::getWrapModel() {
  return wrapBoxModel;
}

void Reconstruct::clipPointCloud(Eigen::Matrix4f & model_matrix, int index) {

  float delta_z = 0.0;

  // Define the local bounds for the bounding box (unit cube)
  std::array<float,6> local_bounds = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5};

  // Create Oriented Bounding Box (OBB)
  auto obb = CreateOrientedBoundingBox(model_matrix, local_bounds);

  // Clip the point cloud with the defined OBB
  auto cropped_cloud = pointCloud.Crop(*obb);

  std::cout << "cropped size: " << cropped_cloud->points_.size() << std::endl;

  if(cropped_cloud->points_.size() == 0) return;

  int seq = getCalibSequence();
  if(seq == -3) {
    double voxel_size = 0.08;
    double max_correspondence_distance_coarse = voxel_size * 25;
    double max_correspondence_distance_fine = voxel_size * 1.0;

    // Load your point clouds
    auto pcds_down = LoadPointClouds(originCloud, *cropped_cloud, voxel_size, true);

    // Perform pairwise registration
    auto [transformation_icp, information_icp] = PairwiseRegistration(pcds_down[0], pcds_down[1], max_correspondence_distance_coarse, max_correspondence_distance_fine);

    std::cout << "Transformation ICP Matrix: " << std::endl;
    std::cout << transformation_icp << std::endl;
 
    double angle = getRotationAngleXY(transformation_icp);
    std::cout << "Rotation angle in XY plane: " << angle << " degrees" << std::endl;

    productPC = originCloud;
    productPC.Transform(transformation_icp);

    transiProduct.clear();
    for (size_t i = 0; i < productPC.points_.size(); ++i) {
      const auto& point = productPC.points_[i];
      const auto& color = productPC.colors_[i];

      transiProduct.push_back(static_cast<float>(point(0)));
      transiProduct.push_back(static_cast<float>(point(1)));
      transiProduct.push_back(static_cast<float>(point(2)));

      transiProduct.push_back(static_cast<float>(color(0)));
      transiProduct.push_back(static_cast<float>(color(1)));
      transiProduct.push_back(static_cast<float>(color(2)));
      transiProduct.push_back(static_cast<float>(1.0));
    }

    Eigen::Matrix3d R = transformation_icp.block<3, 3>(0, 0);  // 3x3 rotation matrix
    Eigen::Vector3d t = transformation_icp.block<3, 1>(0, 3);  // 3x1 translation vector
    Eigen::Vector3d rotation_point = computeRotationPoint(R, t);
    setTargetTranslation(rotation_point);
  }

  if(seq == -2) {
    originCloud = *cropped_cloud;
  }

  if(seq == -5) {
    // Segment plane
    std::vector<size_t> inliers;
    Eigen::Vector4d plane_model;
    double distance_threshold = 0.01; // Adjust this value based on your needs
    int ransac_n = 3;
    int num_iterations = 1000;

    std::tie(plane_model, inliers) = cropped_cloud->SegmentPlane(
							     distance_threshold, ransac_n, num_iterations);

    std::cout << "label Plane equation: " << plane_model(0) << "x + " << plane_model(1) 
	      << "y + " << plane_model(2) << "z + " << plane_model(3) << " = 0" << std::endl;

    try {
      auto [label_center, label_angle, w, h] = LabelCenterAndOrientation(*cropped_cloud, labelResolution);
      std::cout << "label angle: " << label_angle << " degrees" << std::endl;
      std::cout << "x: " << label_center[0] << std::endl;
      std::cout << "y: " << label_center[1] << std::endl;

      double x0 = label_center[0];
      double y0 = label_center[1];

      double z_plane = (-plane_model(3) - plane_model(0) * x0 - plane_model(1) * y0) / plane_model(2);
      std::cout << "test z_plane: " << z_plane << std::endl;

      Eigen::Matrix4f gizmo;
      gizmo = alignGizmoToLabel({label_center(0)/10.0, label_center(1)/10.0, z_plane/10.0}, label_angle);
      w > h ? setWrapModel(CreateGizmoModelMatrix(gizmo, w*labelResolution/10.0, h*labelResolution/10.0, 0.1f)):setWrapModel(CreateGizmoModelMatrix(gizmo, h*labelResolution/10.0, w*labelResolution/10.0, 0.1f));

      setTargetTranslation({label_center(0), label_center(1), 0.0});
      
    } catch (const std::exception& e) {
      std::cerr << "Error: " << e.what() << std::endl;
    }

  }

  if(seq == -6) {
    // Segment plane
    std::vector<size_t> inliers;
    Eigen::Vector4d plane_model;
    double distance_threshold = 0.09; // Adjust this value based on your needs
    int ransac_n = 3;
    int num_iterations = 10000;

    std::tie(plane_model, inliers) = cropped_cloud->SegmentPlane(
								 distance_threshold, ransac_n, num_iterations);

    std::cout << "label Plane equation: " << plane_model(0) << "x + " << plane_model(1) 
	      << "y + " << plane_model(2) << "z + " << plane_model(3) << " = 0" << std::endl;

    try {
      auto nozzle_center = CalibrateNozzleCenter(*cropped_cloud, labelResolution, 0.04);
      std::cout << "nozzle x: " << nozzle_center[0] << std::endl;
      std::cout << "nozzle y: " << nozzle_center[1] << std::endl;

      setTargetTranslation({nozzle_center(0), nozzle_center(1), 0.0});
      
    } catch (const std::exception& e) {
      std::cerr << "Error: " << e.what() << std::endl;
    }

  }
    
  

  if(seq >= 0) {
    double voxel_size = 0.08;
    double max_correspondence_distance_coarse = voxel_size * 25;
    double max_correspondence_distance_fine = voxel_size * 1.0;

    // Load your point clouds
    auto pcds_down = LoadPointClouds(originCloud, *cropped_cloud, voxel_size, true);

    // Perform pairwise registration
    auto [transformation_icp, information_icp] = PairwiseRegistration(pcds_down[0], pcds_down[1], max_correspondence_distance_coarse, max_correspondence_distance_fine);

    std::cout << "Transformation ICP Matrix: " << std::endl;
    std::cout << transformation_icp << std::endl;
 
    double angle = getRotationAngleXY(transformation_icp);
    std::cout << "Rotation angle in XY plane: " << angle << " degrees" << std::endl;

    productPC = originCloud;
    productPC.Transform(transformation_icp);

    transiProduct.clear();
    for (size_t i = 0; i < productPC.points_.size(); ++i) {
      const auto& point = productPC.points_[i];
      const auto& color = productPC.colors_[i];

      transiProduct.push_back(static_cast<float>(point(0)));
      transiProduct.push_back(static_cast<float>(point(1)));
      transiProduct.push_back(static_cast<float>(point(2)));

      transiProduct.push_back(static_cast<float>(color(0)));
      transiProduct.push_back(static_cast<float>(color(1)));
      transiProduct.push_back(static_cast<float>(color(2)));
      transiProduct.push_back(static_cast<float>(1.0));
    }

    setTargetTranslation(transformation_icp.block<3, 1>(0, 3));
  }

  std::vector<float>* myPC;
  geometry::PointCloud unwrappedPointCloud;
  std::vector<Eigen::Vector3d> unwrapped;

  switch(index) {
    case 0:
      labelPC = *cropped_cloud;
      myPC = &transiLabel;

      // unwrapPointCloud(labelPC.points_);
      // unwrapped = unwrapPointCloud(labelPC.points_);
      // unwrappedPointCloud.points_ = unwrapped;

      // io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/labelPC.ply", unwrappedPointCloud, true);

      delta_z = 0.01;
      break;

    case 1:
      productPC = *cropped_cloud;
      myPC = &transiProduct;
      delta_z = 0.01;
      break;

    case 2:
      labelTempPC = *cropped_cloud;
      myPC = &transiLabelTemp;
      io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/labelTempPC.ply", labelTempPC, true);
      delta_z = 0.01;
      break;

    case 3:
      productTempPC = *cropped_cloud;
      myPC = &transiProductTemp;
      io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/productTempPC.ply", productTempPC, true);
      delta_z = 0.01;
      break;

    case 5:
      convPlanePC = *cropped_cloud;
      for(auto& point : convPlanePC.points_) {
	point(1) = -point(1);
	point(2) = -point(2);
      }
      myPC = &transiConvPlane;
      io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/convPlanePC.ply", convPlanePC, true);
      findPlane();
      delta_z = 0.01;
      break;

    default:
      break;
  }

  myPC->clear();

  for (size_t i = 0; i < (*cropped_cloud).points_.size(); ++i) {
    const auto& point = (*cropped_cloud).points_[i];
    const auto& color = (*cropped_cloud).colors_[i];

    myPC->push_back(static_cast<float>(point(0)));
    myPC->push_back(static_cast<float>(point(1)));
    myPC->push_back(static_cast<float>(point(2)+delta_z));

    myPC->push_back(static_cast<float>(color(0)));
    myPC->push_back(static_cast<float>(color(1)));
    myPC->push_back(static_cast<float>(color(2)));
    myPC->push_back(static_cast<float>(1.0));
  }
}

// Function to perform pairwise registration using Point-to-Plane ICP
std::pair<Eigen::Matrix4d, Eigen::Matrix6d> Reconstruct::PairwiseRegistration(
    const std::shared_ptr<open3d::geometry::PointCloud> &source,
    const std::shared_ptr<open3d::geometry::PointCloud> &target,
    double max_correspondence_distance_coarse,
    double max_correspondence_distance_fine,
    bool robust) {

    using namespace open3d;
    using namespace std;

    double sigma = 0.5;

    // Create TukeyLoss for robust loss
    auto loss = std::make_shared<pipelines::registration::TukeyLoss>(sigma);
    pipelines::registration::TransformationEstimationPointToPlane p21(loss);

    cout << "Apply point-to-plane ICP" << endl;

    auto icp_coarse = pipelines::registration::RegistrationICP(
        *source, *target, max_correspondence_distance_coarse, Eigen::Matrix4d::Identity(),
        pipelines::registration::TransformationEstimationPointToPlane());

    auto icp_fine = pipelines::registration::RegistrationICP(*source, *target, max_correspondence_distance_fine, icp_coarse.transformation_, robust?p21:pipelines::registration::TransformationEstimationPointToPlane());


    // auto icp_fine2 = pipelines::registration::RegistrationICP(
    //     *source, *target, max_correspondence_distance_fine, icp_fine.transformation_,
    //     pipelines::registration::TransformationEstimationPointToPoint());

    auto transformation_icp = icp_fine.transformation_;
    auto information_icp = pipelines::registration::GetInformationMatrixFromPointClouds(
        *source, *target, max_correspondence_distance_fine, icp_fine.transformation_);

    return {transformation_icp, information_icp};
}



std::pair<Eigen::Matrix4d, Eigen::Matrix6d> Reconstruct::FullRegistration(
    const std::shared_ptr<open3d::geometry::PointCloud> &source,
    const std::shared_ptr<open3d::geometry::PointCloud> &target,
    double voxel_size,
    double max_correspondence_distance_coarse,
    double max_correspondence_distance_fine) {

    using namespace open3d;
    using namespace std;

    bool mutual_filter = false;

    double sigma = 0.2;

    // Create TukeyLoss for robust loss
    auto loss = std::make_shared<pipelines::registration::TukeyLoss>(sigma);
    pipelines::registration::TransformationEstimationPointToPlane p21(loss);

    auto source_fpfh = pipelines::registration::ComputeFPFHFeature(
								   *source, geometry::KDTreeSearchParamHybrid(5 * voxel_size, 50));

    auto target_fpfh = pipelines::registration::ComputeFPFHFeature(
								   *target, geometry::KDTreeSearchParamHybrid(5 * voxel_size, 50));

    cout << "Performing RANSAC-based global registration..." << endl;

    // Prepare checkers
    std::vector<std::reference_wrapper<
            const pipelines::registration::CorrespondenceChecker>>
            correspondence_checker;
    auto correspondence_checker_edge_length =
            pipelines::registration::CorrespondenceCheckerBasedOnEdgeLength(
                    0.9);
    auto correspondence_checker_distance =
            pipelines::registration::CorrespondenceCheckerBasedOnDistance(
                    max_correspondence_distance_coarse);
    correspondence_checker.push_back(correspondence_checker_edge_length);
    correspondence_checker.push_back(correspondence_checker_distance);

    // RANSAC-based global registration
    auto result_ransac = pipelines::registration::RegistrationRANSACBasedOnFeatureMatching(
	*source, *target, *source_fpfh, *target_fpfh, mutual_filter,
        max_correspondence_distance_coarse,
        pipelines::registration::TransformationEstimationPointToPoint(false), 3,
        correspondence_checker,
        pipelines::registration::RANSACConvergenceCriteria(1000000, 0.999));

    cout << "RANSAC result transformation:" << endl;
    cout << result_ransac.transformation_ << endl;

    cout << "Refining registration with point-to-plane ICP..." << endl;

    auto icp_coarse = pipelines::registration::RegistrationICP(
        *source, *target, max_correspondence_distance_coarse, result_ransac.transformation_,
        pipelines::registration::TransformationEstimationPointToPlane());

    auto icp_fine = pipelines::registration::RegistrationICP(*source, *target, max_correspondence_distance_fine, icp_coarse.transformation_, pipelines::registration::TransformationEstimationPointToPlane());
    // auto icp_fine = pipelines::registration::RegistrationICP(*source, *target, max_correspondence_distance_fine, icp_coarse.transformation_, p21);


    auto transformation_icp = icp_fine.transformation_;
    auto information_icp = pipelines::registration::GetInformationMatrixFromPointClouds(
        *source, *target, max_correspondence_distance_fine, icp_fine.transformation_);

    return {transformation_icp, information_icp};
}



// Function to load point clouds and downsample them
std::vector<std::shared_ptr<open3d::geometry::PointCloud>> Reconstruct::LoadPointClouds(open3d::geometry::PointCloud& source, open3d::geometry::PointCloud& dest, double voxel_size, bool project) {
    using namespace open3d;
    using namespace std;

    vector<shared_ptr<geometry::PointCloud>> pcds;
    shared_ptr<geometry::PointCloud> static_denoise;
    shared_ptr<geometry::PointCloud> static_denoise2;
    std::vector<size_t> inlier_indices;
    double mean_k = 6;
    double std_dev_multiplier = 1.0;

    // auto pcd1 = io::CreatePointCloudFromFile("2/multiway9.ply");
    auto pcd1 = &source;

    if(project) {
      // std::tie(static_denoise, inlier_indices) = pcd1->RemoveStatisticalOutliers(mean_k, std_dev_multiplier);
      std::tie(static_denoise2, inlier_indices) = pcd1->RemoveRadiusOutliers(6, 0.09);

      auto pcd_down1 = static_denoise2->VoxelDownSample(voxel_size);
      pcd_down1->EstimateNormals(geometry::KDTreeSearchParamHybrid(voxel_size*2, 20));
      cout << "Detect " << pcd_down1->points_.size() << " points in point cloud 1" << endl;
      pcds.push_back(pcd_down1);
    } else {
      auto pcd_down1 = pcd1->VoxelDownSample(voxel_size);
      pcd_down1->EstimateNormals(geometry::KDTreeSearchParamHybrid(voxel_size*2, 20));
      cout << "Detect " << pcd_down1->points_.size() << " points in point cloud 1" << endl;
      pcds.push_back(pcd_down1);
    }

    // auto pcd2 = io::CreatePointCloudFromFile("2/multiway10.ply");
    auto pcd2 = &dest;

    if(!project) {
      // std::tie(static_denoise, inlier_indices) = pcd2->RemoveStatisticalOutliers(mean_k, std_dev_multiplier);
      // std::tie(static_denoise2, inlier_indices) = pcd2->RemoveRadiusOutliers(3, 0.09);

      auto pcd_down2 = pcd2->VoxelDownSample(voxel_size);
      pcd_down2->EstimateNormals(geometry::KDTreeSearchParamHybrid(voxel_size*2, 20));
      cout << "Detect " << pcd_down2->points_.size() << " points in point cloud 2" << endl;
      pcds.push_back(pcd_down2);

    } else {
      auto pcd_down2 = pcd2->VoxelDownSample(voxel_size);
      pcd_down2->EstimateNormals(geometry::KDTreeSearchParamHybrid(voxel_size*2, 20));
      cout << "Detect " << pcd_down2->points_.size() << " points in point cloud 2" << endl;
      pcds.push_back(pcd_down2);
    }

    return pcds;
}


// double getAxisAngle(const Eigen::Matrix4d& transformation) {
//     // Extract the 3x3 rotation matrix from the 4x4 transformation matrix
//     Eigen::Matrix3d rotation_matrix = transformation.block<3, 3>(0, 0);

//     // Calculate the trace of the matrix
//     double trace = rotation_matrix.trace();

//     // Calculate the rotation angle in radians
//     double rotation_angle_radians = std::acos((trace -1) / 2);

//     // Convert radians to degrees
//     double rotation_angle_degrees = rotation_angle_radians * (180.0 / M_PI);

//     std::cout << "Rotation angle: " << rotation_angle_degrees << " degrees" << std::endl;
//     return 0;
// }


void PrintRegistrationResult(
    const open3d::geometry::PointCloud &source,
    const open3d::geometry::PointCloud &target,
    const Eigen::Matrix4d &transformation,
    double max_correspondence_distance) {
    
    // Transform the source point cloud with the computed transformation
    auto transformed_source = source;
    transformed_source.Transform(transformation);

    // Find correspondences
    auto correspondences = open3d::pipelines::registration::EvaluateRegistration(
        transformed_source, target, max_correspondence_distance);

    // Metrics
    double fitness = correspondences.fitness_;
    double inlier_rmse = correspondences.inlier_rmse_;
    size_t correspondence_set_size = correspondences.correspondence_set_.size();

    // Print results
    std::cout << "Registration Result:" << std::endl;
    std::cout << "  Fitness: " << fitness << std::endl;
    std::cout << "  Inlier RMSE: " << inlier_rmse << std::endl;
    std::cout << "  Correspondence Set Size: " << correspondence_set_size << std::endl;
}

Eigen::Matrix4d Reconstruct::estimateTransform(open3d::geometry::PointCloud& source, open3d::geometry::PointCloud& dest, bool project) {
  double voxel_size = 0.05;
  double max_correspondence_distance_coarse = voxel_size * 25;
  double max_correspondence_distance_fine = voxel_size * 1.0;

  // Load your point clouds
  auto pcds_down = LoadPointClouds(source, dest, voxel_size, project);

  if(project) {
    for(auto& point : (*pcds_down[0]).points_) {
      point(2) = 0.0;
    }

    for(auto& point : (*pcds_down[1]).points_) {
      point(2) = 0.0;
    }
  }

  if(true) {
    auto [transformation_icp, information_icp] = PairwiseRegistration(pcds_down[0], pcds_down[1], max_correspondence_distance_coarse, max_correspondence_distance_fine, true);
    // PrintRegistrationResult(source, dest, transformation_icp, 0.12);
    return transformation_icp;
  } else {
    auto [transformation_icp, information_icp] = FullRegistration(pcds_down[0], pcds_down[1], voxel_size, max_correspondence_distance_coarse, max_correspondence_distance_fine);
    return transformation_icp;
  }
}


std::tuple<double, double, double> Reconstruct::getMotionRevise() {
  return motionRevise;
}

void Reconstruct::setMotionRevise(double angle, double dx, double dy) {
  motionRevise = std::make_tuple(angle, dx, dy);
}


void Reconstruct::setLabelResolution(double value) {
  labelResolution = value;
}


void Reconstruct::setProductResolution(double value) {
  productResolution = value;
}


void Reconstruct::setDistanceThreshold(double value) {
  distanceThreshold = value;
}


Eigen::Matrix4d estimateTransform2(const Eigen::Vector2d& source_center,
                                  double source_angle,
                                  const Eigen::Vector2d& template_center,
                                  double template_angle) {
    // Convert the 2D centers to 3D (z = 0)
    Eigen::Vector3d source_center_3d(source_center.x(), source_center.y(), 0.0);
    Eigen::Vector3d template_center_3d(template_center.x(), template_center.y(), 0.0);

    // Calculate the rotation angle difference
    double angle_diff = template_angle - source_angle;

    // Create the rotation matrix around the Z-axis
    Eigen::Matrix3d rotation_matrix;
    rotation_matrix = Eigen::AngleAxisd(angle_diff * M_PI / 180.0, Eigen::Vector3d::UnitZ());

    // Calculate the new center of the source after rotation
    Eigen::Vector3d rotated_source_center = rotation_matrix * source_center_3d;

    // Calculate the correct translation vector
    Eigen::Vector3d translation_vector = template_center_3d - rotated_source_center;

    // Construct the final transformation matrix
    Eigen::Matrix4d transformation_matrix = Eigen::Matrix4d::Identity();
    transformation_matrix.block<3, 3>(0, 0) = rotation_matrix;
    transformation_matrix.block<3, 1>(0, 3) = translation_vector;

    return transformation_matrix;
}


std::tuple<Eigen::Vector2d, double> ProcessPointCloudTo2D(const open3d::geometry::PointCloud& point_cloud, double resolution) {
    // Step 1: Flatten the point cloud into a 2D image
    auto min_bound = point_cloud.GetMinBound();
    auto max_bound = point_cloud.GetMaxBound();
    
    int width = static_cast<int>((max_bound[0] - min_bound[0]) / resolution) + 1;
    int height = static_cast<int>((max_bound[1] - min_bound[1]) / resolution) + 1;

    cv::Mat image = cv::Mat::zeros(height, width, CV_8UC1);

    for (const auto& point : point_cloud.points_) {
        int x = static_cast<int>((point(0) - min_bound[0]) / resolution);
        int y = static_cast<int>((point(1) - min_bound[1]) / resolution);
        image.at<uchar>(y, x) = 255;  // Set the pixel value to white
    }

    // Step 2: Threshold the image to create a binary image
    cv::Mat binary, blurred;
    cv::threshold(image, binary, 1, 255, cv::THRESH_BINARY);
    // cv::GaussianBlur(image, blurred, cv::Size(5, 5), 0);
    // cv::threshold(blurred, binary, 127, 255, cv::THRESH_BINARY);

    // Step 3: Find contours
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(binary, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
    // cv::findContours(binary, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_TC89_L1);

    if (contours.empty()) {
        std::cerr << "No contours found." << std::endl;
        throw std::runtime_error("No contours found in the flattened point cloud");
    }

    // Step 4: Find the largest contour
    auto largest_contour = *std::max_element(contours.begin(), contours.end(), 
                                             [](const std::vector<cv::Point>& a, const std::vector<cv::Point>& b) {
                                                 return cv::contourArea(a) < cv::contourArea(b);
                                             });

    // Step 5: Compute the convex hull
    std::vector<cv::Point> hull;
    cv::convexHull(largest_contour, hull);

    // Step 6: Fit a minimum area rectangle
    cv::RotatedRect min_area_rect = cv::minAreaRect(hull);
    cv::Point2f box_points[4];
    min_area_rect.points(box_points);

    // Extract center and angle
    cv::Point2f center = min_area_rect.center;
    float angle = min_area_rect.angle;
    if (angle < -45) {
        angle += 90;
    }

    // Convert center back to 3D coordinates
    Eigen::Vector3d center_3d;
    center_3d[0] = min_bound[0] + center.x * resolution;
    center_3d[1] = min_bound[1] + center.y * resolution;
    center_3d[2] = 0.0; // Assume Z is 0 since we're working with a flattened image

    // Output the results
    std::cout << "Center (2D): (" << center.x << ", " << center.y << ")" << std::endl;
    std::cout << "Center (3D): (" << center_3d[0] << ", " << center_3d[1] << ", " << center_3d[2] << ")" << std::endl;
    std::cout << "Rotation Angle: " << angle << " degrees" << std::endl;

    // Step 7: Visualize the results
    cv::Mat color_image;
    cv::cvtColor(image, color_image, cv::COLOR_GRAY2BGR);
    for (int i = 0; i < 4; i++) {
        cv::line(color_image, box_points[i], box_points[(i + 1) % 4], cv::Scalar(255, 0, 0), 2);
    }
    cv::drawContours(color_image, std::vector<std::vector<cv::Point>>{hull}, -1, cv::Scalar(0, 255, 0), 2);
    cv::circle(color_image, center, 5, cv::Scalar(0, 0, 255), -1);

    cv::imwrite("/dev/shm/labelPC.png", color_image);

    Eigen::Vector2d center_2d(center_3d[0],center_3d[1]);

    return std::make_tuple(center_2d, angle);
}


// int Reconstruct::syntheticAlign(Eigen::Matrix4f& label, Eigen::Matrix4f& product, Eigen::Vector3d axis) {
//   using namespace open3d;
//   using namespace std;

//   // Define the local bounds for the bounding box (unit cube)
//   std::array<float,6> local_bounds = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5};

//   // Create Oriented Bounding Box (OBB)
//   auto obb = CreateOrientedBoundingBox(label, local_bounds);
//   auto obb2 = CreateOrientedBoundingBox(product, local_bounds);

//   // Clip the point cloud with the defined OBB
//   labelPC = *pointCloud.Crop(*obb);
//   productPC = *pointCloud.Crop(*obb2);

//   if(labelPC.points_.size() == 0 || productPC.points_.size() == 0
//      || labelTempPC.points_.size() == 0 || productTempPC.points_.size() == 0) return 0;


//   // Save the aligned point clouds
//   io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/labelPC.ply", labelPC, true);
//   io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productPC.ply", productPC, true);

//   try {
//     auto [product_center, product_angle] = ProductCenterAndOrientation(productPC, 0.05);
//     std::cout << "product angle: " << product_angle << " degrees" << std::endl;
//     std::cout << "x: " << product_center[0] << std::endl;
//     std::cout << "y: " << product_center[1] << std::endl;
    
//     auto [label_center, label_angle, w, h] = LabelCenterAndOrientation(labelPC, 0.05);
//     std::cout << "label angle: " << label_angle << " degrees" << std::endl;
//     std::cout << "x: " << label_center[0] << std::endl;
//     std::cout << "y: " << label_center[1] << std::endl;
    
//     auto trans1 = estimateTransform2(label_center, label_angle, product_center, product_angle);
//     std::cout << "trans1 Matrix: " << std::endl;
//     std::cout << trans1 << std::endl;
    
//     double angle = product_angle - label_angle;
//     std::cout << "Rotation angle in XY plane: " << angle << " degrees" << std::endl;
    
//     Eigen::Vector3d rotation_center = axis;
//     Eigen::Matrix3d rotation_matrix = trans1.block<3, 3>(0, 0);
//     Eigen::Vector3d translation_vector = trans1.block<3, 1>(0, 3);
    
//     // Adjust translation for the correct rotation center
//     Eigen::Vector3d adjusted_translation = translation_vector - (Eigen::Matrix3d::Identity() - rotation_matrix) * rotation_center;
//     std::cout << "translation vector: " << translation_vector << std::endl;
//     std::cout << "adjusted translation: " << adjusted_translation << std::endl;
//     std::cout << "raw translation: " << (Eigen::Matrix3d::Identity() - rotation_matrix) * rotation_center << std::endl;
    
//     // Translate the point cloud to the origin (subtract the rotation center)
//     for (auto &point : labelPC.points_) {
//       point -= rotation_center;
//     }
    
//     // Apply the rotation
//     for (auto &point : labelPC.points_) {
//       Eigen::Vector3d rotated_point = rotation_matrix * Eigen::Vector3d(point.x(), point.y(), point.z());
//       point = rotated_point;
//     }
    
//     // Translate the point cloud back to the original position (add the rotation center)
//     for (auto &point : labelPC.points_) {
//       point += rotation_center;
//     }
    
//     for (auto &point : labelPC.points_) {
//       point += adjusted_translation;
//     }
    
//     setMotionRevise(angle, adjusted_translation(0), adjusted_translation(1));
    
//     transiLabel.clear();
    
//     for (size_t i = 0; i < labelPC.points_.size(); ++i) {
//       const auto& point = labelPC.points_[i];
//       const auto& color = labelPC.colors_[i];
    
//       transiLabel.push_back(static_cast<float>(point(0)));
//       transiLabel.push_back(static_cast<float>(point(1)));
//       transiLabel.push_back(static_cast<float>(point(2)));
    
//       transiLabel.push_back(static_cast<float>(color(0)));
//       transiLabel.push_back(static_cast<float>(color(1)));
//       transiLabel.push_back(static_cast<float>(color(2)));
//       transiLabel.push_back(static_cast<float>(1.0));
//     }

//   } catch (const std::exception& e) {
//       std::cerr << "Error: " << e.what() << std::endl;
//   }

//   return 0;
// }



int Reconstruct::syntheticAlign(Eigen::Matrix4f& label, Eigen::Matrix4f& product, Eigen::Vector3d axis) {
  using namespace open3d;
  using namespace std;

  // Define the local bounds for the bounding box (unit cube)
  std::array<float,6> local_bounds = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5};

  // Create Oriented Bounding Box (OBB)
  auto obb = CreateOrientedBoundingBox(label, local_bounds);
  auto obb2 = CreateOrientedBoundingBox(product, local_bounds);

  // Clip the point cloud with the defined OBB
  labelPC = *pointCloud.Crop(*obb);
  productPC = *pointCloud.Crop(*obb2);

  if(labelPC.points_.size() == 0 || productPC.points_.size() == 0
     || labelTempPC.points_.size() == 0 || productTempPC.points_.size() == 0) return 0;


  // Save the aligned point clouds
  io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/labelPC.ply", labelPC, true);
  io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productPC.ply", productPC, true);

  try {
    auto [product_center, product_angle] = ProductCenterAndOrientation(productPC, 0.05, 0.09);
    std::cout << "product angle: " << product_angle << " degrees" << std::endl;
    std::cout << "x: " << product_center[0] << std::endl;
    std::cout << "y: " << product_center[1] << std::endl;
    
    auto [label_center, label_angle, w, h] = LabelCenterAndOrientation(labelPC, 0.05);
    std::cout << "label angle: " << label_angle << " degrees" << std::endl;
    std::cout << "x: " << label_center[0] << std::endl;
    std::cout << "y: " << label_center[1] << std::endl;
    
    auto trans1 = estimateTransform2(label_center, label_angle, product_center, product_angle);
    std::cout << "trans1 Matrix: " << std::endl;
    std::cout << trans1 << std::endl;
    
    double angle = product_angle - label_angle;
    std::cout << "Rotation angle in XY plane: " << angle << " degrees" << std::endl;

    cv::Point2d originalPoint(label_center(0), label_center(1));
    cv::Point2d center(axis(0), axis(1));
    cv::Mat rotationMatrix = cv::getRotationMatrix2D(center, -angle, 1.0);

    std::vector<cv::Point2d> transformedPoints;
    std::vector<cv::Point2d> inputPoints;
    inputPoints.push_back(originalPoint);
    cv::transform(inputPoints, transformedPoints, rotationMatrix);

    cv::Point2d product_center2(product_center(0), product_center(1));
    cv::Point2d rotated_label_center(transformedPoints[0].x, transformedPoints[0].y);
    cv::Point2d adjusted_translation = product_center2 - rotated_label_center;


    // Eigen::Vector3d rotation_center = axis;
    // Eigen::Matrix3d rotation_matrix = trans1.block<3, 3>(0, 0);
    // Eigen::Vector3d translation_vector = trans1.block<3, 1>(0, 3);
    
    // // Adjust translation for the correct rotation center
    // Eigen::Vector3d adjusted_translation = translation_vector - (Eigen::Matrix3d::Identity() - rotation_matrix) * rotation_center;
    // std::cout << "translation vector: " << translation_vector << std::endl;
    // std::cout << "adjusted translation: " << adjusted_translation << std::endl;
    // std::cout << "raw translation: " << (Eigen::Matrix3d::Identity() - rotation_matrix) * rotation_center << std::endl;
    
    // // Translate the point cloud to the origin (subtract the rotation center)
    // for (auto &point : labelPC.points_) {
    //   point -= rotation_center;
    // }
    
    // // Apply the rotation
    // for (auto &point : labelPC.points_) {
    //   Eigen::Vector3d rotated_point = rotation_matrix * Eigen::Vector3d(point.x(), point.y(), point.z());
    //   point = rotated_point;
    // }
    
    // // Translate the point cloud back to the original position (add the rotation center)
    // for (auto &point : labelPC.points_) {
    //   point += rotation_center;
    // }
    
    // for (auto &point : labelPC.points_) {
    //   point += adjusted_translation;
    // }
    
    setMotionRevise(angle, adjusted_translation.x, adjusted_translation.y);
    
    transiLabel.clear();
    
    for (size_t i = 0; i < labelPC.points_.size(); ++i) {
      const auto& point = labelPC.points_[i];
      const auto& color = labelPC.colors_[i];
    
      transiLabel.push_back(static_cast<float>(point(0)));
      transiLabel.push_back(static_cast<float>(point(1)));
      transiLabel.push_back(static_cast<float>(point(2)));
    
      transiLabel.push_back(static_cast<float>(color(0)));
      transiLabel.push_back(static_cast<float>(color(1)));
      transiLabel.push_back(static_cast<float>(color(2)));
      transiLabel.push_back(static_cast<float>(1.0));
    }

  } catch (const std::exception& e) {
      std::cerr << "Error: " << e.what() << std::endl;
  }

  return 0;
}



void AlignPointCloud(
    open3d::geometry::PointCloud& source,
    const Eigen::Vector2d& source_center,
    double source_angle,
    const Eigen::Vector2d& target_center,
    double target_angle) {

    // Step 1: Compute the relative rotation angle
    double relative_angle = target_angle - source_angle;

    // Step 2: Convert the 2D rotation angle to a 3D rotation matrix
    Eigen::Matrix3d rotation_matrix = Eigen::Matrix3d::Identity();
    double cos_theta = std::cos(relative_angle * M_PI / 180.0);
    double sin_theta = std::sin(relative_angle * M_PI / 180.0);

    rotation_matrix(0, 0) = cos_theta;
    rotation_matrix(0, 1) = -sin_theta;
    rotation_matrix(1, 0) = sin_theta;
    rotation_matrix(1, 1) = cos_theta;

    // Step 3: Translate source point cloud to align its center with the origin
    Eigen::Vector3d source_center_3d(source_center.x(), source_center.y(), 0.0);
    source.Translate(-source_center_3d);

    // Step 4: Apply the rotation
    Eigen::Vector3d rotation_center = Eigen::Vector3d::Zero();
    source.Rotate(rotation_matrix, rotation_center);

    // Step 5: Translate source point cloud to align its center with the target's center
    Eigen::Vector3d target_center_3d(target_center.x(), target_center.y(), 0.0);
    source.Translate(target_center_3d);
}


int Reconstruct::labelAlign() {
    using namespace open3d;
    using namespace std;

    shared_ptr<geometry::PointCloud> static_denoise, static_denoise2;
    std::vector<size_t> inlier_indices;
    std::tie(static_denoise, inlier_indices) = labelPC.RemoveStatisticalOutliers(15, 1.5);
    std::tie(static_denoise2, inlier_indices) = labelTempPC.RemoveStatisticalOutliers(15, 1.5);

    std::cout << "labelResolution: " << labelResolution << std::endl;
    std::cout << "productResolution: " << productResolution << std::endl;
    std::cout << "distanceThreshold: " << distanceThreshold << std::endl;

    try {

      auto [product_center, product_angle] = ProductCenterAndOrientation(productPC, productResolution, distanceThreshold);
      std::cout << "product angle: " << product_angle << " degrees" << std::endl;
      std::cout << "x: " << product_center[0] << std::endl;
      std::cout << "y: " << product_center[1] << std::endl;

      auto [label_center, label_angle, w, h] = LabelCenterAndOrientation(labelPC, labelResolution);
      std::cout << "label angle: " << label_angle << " degrees" << std::endl;
      std::cout << "x: " << label_center[0] << std::endl;
      std::cout << "y: " << label_center[1] << std::endl;

      // AlignPointCloud(labelPC, label_center, label_angle, product_center, product_angle);
      auto trans1 = estimateTransform2(label_center, label_angle, product_center, product_angle);

      // auto [source_center, source_angle] = ProcessPointCloudTo2D(*static_denoise, 0.05);
      // auto [template_center, template_angle] = ProcessPointCloudTo2D(*static_denoise2, 0.05);
      // AlignPointCloud(*static_denoise, source_center, source_angle, template_center, template_angle);
      // auto trans1 = estimateTransform2(source_center, source_angle, template_center, template_angle);

      // labelPC = *static_denoise;


      // labelPC.Transform(trans1);
      
      double angle = product_angle - label_angle;
      cv::Point2d originalPoint(label_center(0), label_center(1));
      cv::Point2d center(7.71, -18.73);
      cv::Mat rotationMatrix = cv::getRotationMatrix2D(center, -angle, 1.0);
      
      std::vector<cv::Point2d> transformedPoints;
      std::vector<cv::Point2d> inputPoints;
      inputPoints.push_back(originalPoint);
      cv::transform(inputPoints, transformedPoints, rotationMatrix);
      
      cv::Point2d product_center2(product_center(0), product_center(1));
      cv::Point2d rotated_label_center(transformedPoints[0].x, transformedPoints[0].y);
      cv::Point2d adjusted_translation = product_center2 - rotated_label_center;
      Eigen::Vector3d adjusted_translation2 = {adjusted_translation.x, adjusted_translation.y, 0};

      Eigen::Matrix3d rotation_matrix = trans1.block<3, 3>(0, 0);
      Eigen::Vector3d translation_vector = trans1.block<3, 1>(0, 3);

      saveTransformationToFile(trans1, "/home/hotcat/Downloads/new3dvision/controller/1/transform.txt");


      Eigen::Matrix4d mytrans1, mytrans2, mytrans3, mytrans4, mytrans5;
      mytrans1 = loadTransformationFromFile("/home/hotcat/Downloads/new3dvision/controller/1/transform1.txt");
      mytrans2 = loadTransformationFromFile("/home/hotcat/Downloads/new3dvision/controller/1/transform2.txt");
      mytrans3 = loadTransformationFromFile("/home/hotcat/Downloads/new3dvision/controller/1/transform3.txt");
      mytrans4 = loadTransformationFromFile("/home/hotcat/Downloads/new3dvision/controller/1/transform4.txt");
      mytrans5 = loadTransformationFromFile("/home/hotcat/Downloads/new3dvision/controller/1/transform5.txt");

      // Eigen::Vector3d rotation_point = computeRotationPoint(rotation_matrix, translation_vector);
      Eigen::Vector3d rotation_point = refineRotationCenterWithNonlinearOptimization({mytrans1.block<3,3>(0,0),mytrans2.block<3,3>(0,0), mytrans3.block<3,3>(0,0), mytrans4.block<3,3>(0,0), mytrans5.block<3,3>(0,0)}, {mytrans1.block<3,1>(0,3), mytrans2.block<3,1>(0,3), mytrans3.block<3,1>(0,3), mytrans4.block<3,1>(0,3), mytrans5.block<3,1>(0,3)});
      std::cout << "== rotation_point == : " << rotation_point << std::endl;


      Eigen::Vector3d rotation_center = {7.71, -18.73, 0};

      // Translate the point cloud to the origin (subtract the rotation center)
      for (auto &point : labelPC.points_) {
        point -= rotation_center;
      }
      
      // Apply the rotation
      for (auto &point : labelPC.points_) {
        Eigen::Vector3d rotated_point = rotation_matrix * Eigen::Vector3d(point.x(), point.y(), point.z());
        point = rotated_point;
      }
      
      // Translate the point cloud back to the original position (add the rotation center)
      for (auto &point : labelPC.points_) {
        point += rotation_center;
      }
      
      for (auto &point : labelPC.points_) {
        point += adjusted_translation2;
      }

      // Save the aligned point clouds
      // io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/labelPC.ply", *static_denoise, true);
      // io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/labelTempPC.ply", *static_denoise2, true);
      io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/labelPC.ply", labelPC, true);
      io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/labelTempPC.ply", productPC, true);

      transiLabel.clear();
      transiLabelTemp.clear();

      for (size_t i = 0; i < labelPC.points_.size(); ++i) {
	const auto& point = labelPC.points_[i];
	const auto& color = labelPC.colors_[i];

	transiLabel.push_back(static_cast<float>(point(0)));
	transiLabel.push_back(static_cast<float>(point(1)));
	transiLabel.push_back(static_cast<float>(point(2)));

	transiLabel.push_back(static_cast<float>(color(0)));
	transiLabel.push_back(static_cast<float>(color(1)));
	transiLabel.push_back(static_cast<float>(color(2)));
	transiLabel.push_back(static_cast<float>(1.0));
      }


      for (size_t i = 0; i < labelTempPC.points_.size(); ++i) {
	const auto& point = labelTempPC.points_[i];
	const auto& color = labelTempPC.colors_[i];

	transiLabelTemp.push_back(static_cast<float>(point(0)));
	transiLabelTemp.push_back(static_cast<float>(point(1)));
	transiLabelTemp.push_back(static_cast<float>(point(2)));

	transiLabelTemp.push_back(static_cast<float>(color(0)));
	transiLabelTemp.push_back(static_cast<float>(color(1)));
	transiLabelTemp.push_back(static_cast<float>(color(2)));
	transiLabelTemp.push_back(static_cast<float>(1.0));
      }

    } catch (const std::exception& e) {
      std::cerr << "Error: " << e.what() << std::endl;
    }

    return 0;
}


int Reconstruct::productAlign() {
    using namespace open3d;
    using namespace std;

    double voxel_size = 0.08;
    double max_correspondence_distance_coarse = voxel_size * 25;
    double max_correspondence_distance_fine = voxel_size * 1.0;

    // Load your point clouds
    auto pcds_down = LoadPointClouds(productTempPC, productPC, voxel_size, false);

    // Perform pairwise registration
    auto [transformation_icp, information_icp] = PairwiseRegistration(pcds_down[0], pcds_down[1], max_correspondence_distance_coarse, max_correspondence_distance_fine);

    std::cout << "Transformation ICP Matrix: " << std::endl;
    std::cout << transformation_icp << std::endl;

    double angle = getRotationAngleXY(transformation_icp);
    std::cout << "Rotation angle in XY plane: " << angle << " degrees" << std::endl;

    // Apply the transformation to the source point cloud
    pcds_down[0]->Transform(transformation_icp);

    productTempPC = *pcds_down[0];

    // Save the aligned point clouds
    io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productTempPC.ply", *pcds_down[0], true);
    io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productPC.ply", *pcds_down[1], true);

    transiProduct.clear();
    transiProductTemp.clear();

    for (size_t i = 0; i < productPC.points_.size(); ++i) {
      const auto& point = productPC.points_[i];
      const auto& color = productPC.colors_[i];

      transiProduct.push_back(static_cast<float>(point(0)));
      transiProduct.push_back(static_cast<float>(point(1)));
      transiProduct.push_back(static_cast<float>(point(2)));

      transiProduct.push_back(static_cast<float>(color(0)));
      transiProduct.push_back(static_cast<float>(color(1)));
      transiProduct.push_back(static_cast<float>(color(2)));
      transiProduct.push_back(static_cast<float>(1.0));
    }


    for (size_t i = 0; i < productTempPC.points_.size(); ++i) {
      const auto& point = productTempPC.points_[i];
      const auto& color = productTempPC.colors_[i];

      transiProductTemp.push_back(static_cast<float>(point(0)));
      transiProductTemp.push_back(static_cast<float>(point(1)));
      transiProductTemp.push_back(static_cast<float>(point(2)));

      transiProductTemp.push_back(static_cast<float>(color(0)));
      transiProductTemp.push_back(static_cast<float>(color(1)));
      transiProductTemp.push_back(static_cast<float>(color(2)));
      transiProductTemp.push_back(static_cast<float>(1.0));
    }


    std::string ply_file = "/home/hotcat/Downloads/new3dvision/controller/1/decoder/research2.ply";
    std::string depth_map_file = "/dev/shm/depth_map.ics";
    std::string flattened_image_file = "/dev/shm/flattened_image.png";
    ConvertPointCloudTo2D(ply_file, depth_map_file, flattened_image_file, 0.05);

    return 0;
}


int Reconstruct::syncPointcloud() {

  transiLabelTemp.clear();
  transiProductTemp.clear();

  if(labelTempPC.points_.size() == 0 || productTempPC.points_.size() == 0) return 0;

  for (size_t i = 0; i < labelTempPC.points_.size(); ++i) {
    const auto& point = labelTempPC.points_[i];
    const auto& color = labelTempPC.colors_[i];

    transiLabelTemp.push_back(static_cast<float>(point(0)));
    transiLabelTemp.push_back(static_cast<float>(point(1)));
    transiLabelTemp.push_back(static_cast<float>(point(2)));

    transiLabelTemp.push_back(static_cast<float>(color(0)));
    transiLabelTemp.push_back(static_cast<float>(color(1)));
    transiLabelTemp.push_back(static_cast<float>(color(2)));
    transiLabelTemp.push_back(static_cast<float>(1.0));
  }

  for (size_t i = 0; i < productTempPC.points_.size(); ++i) {
    const auto& point = productTempPC.points_[i];
    const auto& color = productTempPC.colors_[i];

    transiProductTemp.push_back(static_cast<float>(point(0)));
    transiProductTemp.push_back(static_cast<float>(point(1)));
    transiProductTemp.push_back(static_cast<float>(point(2)));

    transiProductTemp.push_back(static_cast<float>(color(0)));
    transiProductTemp.push_back(static_cast<float>(color(1)));
    transiProductTemp.push_back(static_cast<float>(color(2)));
    transiProductTemp.push_back(static_cast<float>(1.0));
  }

  return 0;
}


Eigen::Matrix4f constructTransformation(const Eigen::Vector3f& rotationPoint, 
                                        const Eigen::Matrix3f& rotationMatrix, 
                                        const Eigen::Vector3f& translationVector) {
    // Pre-translate to the rotation point
    Eigen::Matrix4f T_pre = Eigen::Matrix4f::Identity();
    T_pre.block<3, 1>(0, 3) = -rotationPoint;  // Translate to rotation point

    // Apply the rotation matrix
    Eigen::Matrix4f R = Eigen::Matrix4f::Identity();
    R.block<3, 3>(0, 0) = rotationMatrix;      // Set rotation part

    // Post-translate back from the rotation point
    Eigen::Matrix4f T_post = Eigen::Matrix4f::Identity();
    T_post.block<3, 1>(0, 3) = rotationPoint;  // Translate back

    // Apply final translation to align with target point cloud
    Eigen::Matrix4f T_align = Eigen::Matrix4f::Identity();
    T_align.block<3, 1>(0, 3) = translationVector;  // Final translation

    // Combine the transformations
    Eigen::Matrix4f M_total = T_align * T_post * R * T_pre;

    return M_total;
}



double Reconstruct::getRotationAngleXY(const Eigen::Matrix4d& transformation) {
    // Extract the 3x3 rotation matrix from the 4x4 transformation matrix
    Eigen::Matrix3d rotation_matrix = transformation.block<3, 3>(0, 0);

    // Calculate the rotation angle in the XY plane
    double angle_xy = atan2(rotation_matrix(1, 0), rotation_matrix(0, 0));

    // Convert the angle from radians to degrees if needed
    double angle_xy_degrees = angle_xy * (180.0f / M_PI);

    return angle_xy_degrees;
}





// Function to combine two transformations and apply rotation around a specific point
// Eigen::Matrix4d Reconstruct::combineTransformationsWithRotationPoint(const Eigen::Matrix4d& firstTransform,
//                                                         const Eigen::Matrix4d& secondTransform,
//                                                         const Eigen::Vector3d& rotationPoint) {
//     // Extract rotation matrices from both transformations
//     Eigen::Matrix3d firstRotation = firstTransform.block<3, 3>(0, 0);
//     Eigen::Matrix3d secondRotation = secondTransform.block<3, 3>(0, 0);

//     // Combined rotation matrix
//     Eigen::Matrix3d combinedRotation = secondRotation * firstRotation;

//     // Extract translations from the transformations
//     Eigen::Vector3d translationFirst = firstTransform.block<3, 1>(0, 3);
//     Eigen::Vector3d translationSecond = secondTransform.block<3, 1>(0, 3);

//     // Translate to the rotation point, apply the combined rotation, and translate back
//     Eigen::Matrix4d translationToRotationPoint = Eigen::Matrix4d::Identity();
//     translationToRotationPoint.block<3, 1>(0, 3) = -rotationPoint;

//     Eigen::Matrix4d translationBack = Eigen::Matrix4d::Identity();
//     translationBack.block<3, 1>(0, 3) = rotationPoint;

//     // Apply translation -> rotation -> translation back
//     Eigen::Matrix4d rotationMatrix = Eigen::Matrix4d::Identity();
//     rotationMatrix.block<3, 3>(0, 0) = combinedRotation;

//     // Final transformation matrix
//     Eigen::Matrix4d finalTransform = translationBack * rotationMatrix * translationToRotationPoint;

//     // Add the combined translation after the rotation
//     finalTransform.block<3, 1>(0, 3) += translationFirst + translationSecond;

//     return finalTransform;
// }




// Function to combine two transformations and apply rotation around a specific point
Eigen::Matrix4d Reconstruct::combineTransformationsWithRotationPoint(const Eigen::Matrix4d& firstTransform,
                                                        const Eigen::Matrix4d& secondTransform,
                                                        const Eigen::Vector3d& rotationPoint) {

  Eigen::Matrix4d transformation_matrix;

  transformation_matrix = firstTransform;

  Eigen::Vector3d axis_of_rotation(0.0, 0.0, 1.0); // Z-axis

  // Extract rotation and translation components
  // Eigen::Matrix3d rotation_matrix = transformation_matrix.block<3, 3>(0, 0);
  Eigen::Matrix3d rotation_matrix = Eigen::AngleAxisd(getRotationAngleXY(transformation_matrix) * (M_PI / 180.0), axis_of_rotation).toRotationMatrix();
  Eigen::Vector3d translation_vector = transformation_matrix.block<3, 1>(0, 3);

  Eigen::Vector3d rotation_center = rotationPoint;

  // Adjust translation for the correct rotation center
  Eigen::Vector3d adjusted_translation = translation_vector + (Eigen::Matrix3d::Identity() - rotation_matrix) * rotation_center;

  // Scale the translation by 1/10 to convert back to OpenGL coordinates
  // adjusted_translation /= 10.0;

  std::cout <<"Adjusted translation vector: " << adjusted_translation.transpose() << std::endl;

  // Create the new 4x4 transformation matrix
  Eigen::Matrix4d new_transformation_matrix = Eigen::Matrix4d::Identity(); // Initialize asidentity
  new_transformation_matrix.block<3, 3>(0, 0) = rotation_matrix; // Set rotation Part
  new_transformation_matrix.block<3, 1>(0, 3) = adjusted_translation; // Set adjusted translation

  std::cout << "New transformation matrix: \n" << new_transformation_matrix << std::endl;
  return new_transformation_matrix;
}



Eigen::Vector3d Reconstruct::findRealRotationPoint(const Eigen::Matrix4d& transform) {
    // Extract the rotation matrix (upper-left 3x3 part of the 4x4 matrix)
    Eigen::Matrix3d R = transform.block<3, 3>(0, 0);
    
    // Extract the translation vector (upper-right 3x1 part of the 4x4 matrix)
    Eigen::Vector3d t = transform.block<3, 1>(0, 3);
    
    // Create an identity matrix I (3x3)
    Eigen::Matrix3d I = Eigen::Matrix3d::Identity();
    
    // Compute I - R
    Eigen::Matrix3d I_minus_R = I - R;

    // Solve for the rotation point: rotation_point = (I - R)^(-1) * t
    Eigen::Vector3d rotation_point;
    if (I_minus_R.determinant() != 0) {
        rotation_point = I_minus_R.inverse() * t;
    } else {
        // Handle the case when I - R is singular (non-invertible)
        throw std::runtime_error("Cannot compute rotation point, matrix is non-invertible.");
    }

    return rotation_point;
}


// Function to blend colors with a weighted average
Eigen::Vector3d Reconstruct::BlendColors(const Eigen::Vector3d& color1, const Eigen::Vector3d& color2, double weight1 = 0.5, double weight2 = 0.5) {
    return (color1 * weight1 + color2 * weight2) / (weight1 + weight2);
}



// Function to combine and blend multiple point clouds from the same source
open3d::geometry::PointCloud Reconstruct::CombinePointCloudsFromSameSource(
    const std::vector<open3d::geometry::PointCloud>& cropped_pcds) {

    open3d::geometry::PointCloud blended_pcd;

    // Create a map to store unique points and their blended color
    std::unordered_map<Eigen::Vector3d, Eigen::Vector3d, Vector3dHash> point_color_map;

    // Iterate through each cropped point cloud
    for (const auto& pcd : cropped_pcds) {
        for (size_t i = 0; i < pcd.points_.size(); ++i) {
            const Eigen::Vector3d& point = pcd.points_[i];
            const Eigen::Vector3d& color = pcd.colors_[i];

            if (point_color_map.find(point) != point_color_map.end()) {
                // Overlapping point, blend the colors
                point_color_map[point] = BlendColors(point_color_map[point], color);
            } else {
                // New point, add to the map
                point_color_map[point] = color;
            }
        }
    }

    // Populate the blended point cloud
    for (const auto& [point, color] : point_color_map) {
        blended_pcd.points_.push_back(point);
        blended_pcd.colors_.push_back(color);
    }

    return blended_pcd;
}


Eigen::Matrix4f Reconstruct::gizmoAlign(Eigen::Matrix4f& gizmo_matrix) {
    // Extract translation (gizmo position) from gizmo_matrix, scaled to the original point cloud
    Eigen::Vector3f gizmo_position = gizmo_matrix.block<3, 1>(0, 3) * 10.0f;  // Scale up by 10

    // Extract and reverse the direction of the Z axis from the gizmo_matrix
    Eigen::Vector3f ray_direction = -gizmo_matrix.block<3, 1>(0, 2);  // Reverse direction (0, 0, -1)

    // Set up the ray and search for intersections with the point cloud
    std::vector<Eigen::Vector3f> intersections;
    for (const auto& point : pointCloud.points_) {
        Eigen::Vector3f point_f = point.cast<float>();  // Convert Eigen::Vector3d to Eigen::Vector3f
        Eigen::Vector3f dir_to_point = point_f - gizmo_position;
        float projection = dir_to_point.dot(ray_direction);

        // Search along the reversed ray direction for points near the ray
        if (projection > 0) {
            float distance_to_ray = (dir_to_point - projection * ray_direction).norm();
            if (distance_to_ray < 0.5) {  // Adjust this threshold for proximity
                intersections.push_back(point_f);
            }
        }
    }

    std::cout << "intersections.size()" << intersections.size() << std::endl;

    // Check if enough points are found to form a plane
    if (intersections.size() < 100) {
        std::cerr << "Not enough points found to form a plane" << std::endl;
        return gizmo_matrix;  // Return original matrix if not enough points
    }

    // Convert Eigen::Vector3f back to Eigen::Vector3d using cast<double>()
    std::vector<Eigen::Vector3d> intersections_d;
    for (const auto& point_f : intersections) {
        intersections_d.push_back(point_f.cast<double>());  // Explicit cast to Eigen::Vector3d
    }

    // Perform plane regression using Open3D's SegmentPlane (RANSAC)
    auto inliers_plane = open3d::geometry::PointCloud();
    inliers_plane.points_ = intersections_d;  // Assign the double precision points
    Eigen::Vector4d plane_model;
    std::tie(plane_model, std::ignore) = inliers_plane.SegmentPlane(0.01, 3, 1000);  // Plane equation: ax + by + cz + d = 0

    // Align gizmo matrix to the plane (modify translation and rotation)
    Eigen::Matrix4f aligned_matrix = gizmo_matrix;

    // Align to XY plane of the found plane
    double a = plane_model(0), b = plane_model(1), c = plane_model(2), d = plane_model(3);
    Eigen::Vector3f normal = Eigen::Vector3f(a, b, c).normalized();

    // Calculate rotation from current Z axis to plane normal
    Eigen::Vector3f current_z_axis = aligned_matrix.block<3, 1>(0, 2);  // Z-axis from current matrix
    Eigen::Vector3f rotation_axis = current_z_axis.cross(normal);
    float angle = std::acos(current_z_axis.dot(normal));
    Eigen::Matrix3f rotation_matrix = Eigen::AngleAxisf(angle, rotation_axis.normalized()).toRotationMatrix();

    // Update gizmo's rotation with the new matrix aligned to the plane
    aligned_matrix.block<3, 3>(0, 0) = rotation_matrix * aligned_matrix.block<3, 3>(0, 0);

    // Set the new translation to the intersection point on the plane, scaled down by 1/10 to fit OpenGL coordinates
    aligned_matrix.block<3, 1>(0, 3) = intersections[0] * 0.1f;  // Scale down by 1/10

    return aligned_matrix;  // Return the new aligned matrix
}


Eigen::Matrix4f Reconstruct::gizmoRotationAxle(Eigen::Matrix4f &gizmoMatrix, float scaleFactor) {
    // Step 1: Extract the rotation (R) and translation (t) components from the 4x4 matrix
    Eigen::Matrix3d R = altTransform.block<3, 3>(0, 0);  // 3x3 rotation matrix
    Eigen::Vector3d t = altTransform.block<3, 1>(0, 3);  // 3x1 translation vector

    std::cout << "computeRotationPoint: " << computeRotationPoint(R, t) << std::endl;

    // Step 2: Solve for the fixed rotation point
    Eigen::Vector3d rotation_point = computeRotationPoint(R, t);

    // Step 3: Compute the rotation axis using Eigenvalue decomposition
    Eigen::EigenSolver<Eigen::Matrix3d> es(R);
    Eigen::Vector3d rotation_axis;
    bool foundAxis = false;
    for (int i = 0; i < 3; ++i) {
        if (std::abs(es.eigenvalues()[i].real() - 1.0) < 1e-6) {
            // The eigenvalue corresponding to the rotation axis should be close to 1
            rotation_axis = es.eigenvectors().col(i).real();
            rotation_axis.normalize();
            foundAxis = true;
            break;
        }
    }

    if (!foundAxis) {
        std::cerr << "Error: Rotation axis could not be determined." << std::endl;
        return gizmoMatrix;  // Return unchanged if error
    }

    // Step 4: Adjust for scale factor (OpenGL scale mismatch)
    // The real rotation point is in the original scale, so we must scale it to OpenGL's coordinate system
    // If pairwise registration matrix already includes the real point cloud scale, we don't need to divide by scaleFactor.
    rotation_point /= scaleFactor;

    // Step 5: Construct a new transformation matrix to align the Gizmo
    Eigen::Matrix4f newGizmoMatrix = Eigen::Matrix4f::Identity();

    // Set the origin (translation component) to the scaled rotation point
    newGizmoMatrix.block<3, 1>(0, 3) = rotation_point.cast<float>();

    // Align the Gizmo's Z-axis with the rotation axis
    // We assume the original Gizmo's local Z-axis is along (0, 0, 1)
    Eigen::Vector3f z_axis(0.0f, 0.0f, 1.0f);  // Original Z-axis in Gizmo's local frame
    Eigen::Quaternionf rotation_align = Eigen::Quaternionf::FromTwoVectors(z_axis, rotation_axis.cast<float>());

    // Convert the quaternion to a 3x3 rotation matrix and set it in the new Gizmo matrix
    newGizmoMatrix.block<3, 3>(0, 0) = rotation_align.toRotationMatrix();

    // Step 6: Return the new Gizmo matrix
    return newGizmoMatrix;
}


void Reconstruct::setProfiloBlend(float blend) {
  profiloBlend = blend;
}


void Reconstruct::setCalibSequence(int sequence) {
  calibSequence = sequence;
}


int Reconstruct::getCalibSequence() {
  return calibSequence;
}

void Reconstruct::setTargetTranslation(Eigen::Vector3d translation) {
  targetTranslation = translation;
}

Eigen::Vector3d Reconstruct::getTargetTranslation() {
  std::cout << "getTargetTranslation: " << targetTranslation << std::endl;
  return targetTranslation;
}

void Reconstruct::setCustomColorBlend(Vec4& color, float blend, int index) {
  if(index > 9) return;
  customColor[index] = color;
  blendFactor[index] = blend;
}


// Mix function to blend two colors based on a blend factor
Vec4 Reconstruct::mix(const Vec4& color1, const Vec4& color2, float factor) {
    return {
        color1[0] * (1 - factor) + color2[0] * factor,  // Red
        color1[1] * (1 - factor) + color2[1] * factor,  // Green
        color1[2] * (1 - factor) + color2[2] * factor,  // Blue
        color1[3] * (1 - factor) + color2[3] * factor   // Alpha
    };
}


double rbfKernel(double r) {
    return r * r * log(r * r); // Thin Plate Splines kernel function
}

Eigen::MatrixXd buildTPSMatrix(const std::vector<Eigen::Vector3d>& points) {
    size_t N = points.size();
    Eigen::MatrixXd A(N + 3, N + 3); // Including the affine part
    A.setZero();
    
    // Fill the matrix A based on the TPS kernel
    for (size_t i = 0; i < N; ++i) {
        for (size_t j = 0; j < N; ++j) {
            double r = (points[i] - points[j]).norm();
            A(i, j) = rbfKernel(r);
        }
    }

    // Add the affine terms
    for (size_t i = 0; i < N; ++i) {
        A(i, N) = A(N, i) = 1;
        A(i, N + 1) = A(N + 1, i) = points[i].x();
        A(i, N + 2) = A(N + 2, i) = points[i].y();
    }

    A(N, N) = A(N + 1, N + 1) = A(N + 2, N + 2) = 0;

    return A;
}

Eigen::VectorXd solveTPS(const std::vector<Eigen::Vector3d>& points, const std::vector<Eigen::Vector3d>& values) {
    size_t N = points.size();
    
    // Construct the matrix based on TPS formulation
    Eigen::MatrixXd A = buildTPSMatrix(points);
    Eigen::MatrixXd B(N + 3, 1);
    
    for (size_t i = 0; i < N; ++i) {
        B(i) = values[i].x();
    }
    
    // Solve the system A * weights = B
    Eigen::VectorXd weights = A.ldlt().solve(B);
    return weights;
}

Eigen::Vector3d applyTPS(const Eigen::Vector3d& point, const std::vector<Eigen::Vector3d>& points, const std::vector<Eigen::Vector3d>& values, const Eigen::VectorXd& weights) {
    size_t N = points.size();
    Eigen::Vector3d result = Eigen::Vector3d::Zero();

    // Sum the terms
    for (size_t i = 0; i < N; ++i) {
        double r = (point - points[i]).norm();
        result += weights(i) * rbfKernel(r) * values[i];
    }

    return result;
}


std::vector<Eigen::Vector3d> Reconstruct::unwrapPointCloud(std::vector<Eigen::Vector3d>& pointCloud) {
  std::vector<Eigen::Vector3d> unwrappedPointCloud;

  std::vector<Eigen::Vector3d> points = pointCloud;
  std::vector<Eigen::Vector3d> values = pointCloud;

  // Eigen::VectorXd weights = solveTPS(points, values);

  // For each point in the cloud, apply the TPS transformation
  // for (const auto& point : pointCloud) {
  //   Eigen::Vector3d unwrappedPoint = applyTPS(point, points, values, weights);
  //   unwrappedPointCloud.push_back(unwrappedPoint);
  // }

  return unwrappedPointCloud;
}




