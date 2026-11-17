
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


std::shared_ptr<open3d::geometry::PointCloud>
VoxelLargestComponentFilter(
        const open3d::geometry::PointCloud &pcd,
        double voxelSize);

Eigen::Vector2d CalibrateNozzleCenter(const open3d::geometry::PointCloud& pointcloud, double resolution, double distance, int index) {

    cv::Mat depth_map;
    cv::Mat flattened_image;

    if (pointcloud.IsEmpty()) {
        throw std::runtime_error("Point cloud is empty.");
    }

    io::WritePointCloudToPLY("/dev/shm/debug.ply", pointcloud, true);

    auto result = pointcloud.RemoveStatisticalOutliers(15, 1.0);
    auto filtered_pointcloud = std::get<0>(result);

    std::vector<size_t> inliers;
    Eigen::Vector4d plane_model;
    double distance_threshold = distance; // Adjust this value based on your needs
    int ransac_n = 4;
    int num_iterations = 10000;
    std::tie(plane_model, inliers) = filtered_pointcloud->SegmentPlane(distance_threshold, ransac_n, num_iterations);

    auto plane_points = filtered_pointcloud->SelectByIndex(inliers);

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
    dipImage2 = dip::Label(dipImage2, 0, 20000);

    std::cout << "in step7 ... " << std::endl;

    // Measure the convex hull and compute the center point using DIPlib
    dip::MeasurementTool msrTool;
    auto measurements = msrTool.Measure(dipImage2, {}, {"Center", "Radius"}, {}, 1);

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

    dip::Image dipImage3, circle;
    dipImage3 = dipImage.Copy();
    circle = dip::Image(dipImage3.Sizes(), 1, dip::DT_DFLOAT);
    circle.Fill(0);
    dip::DrawBandlimitedBall(circle, measurements[1]["Radius"][1]*2, {measurements[1]["Center"][0],measurements[1]["Center"][1]}, {1}, "empty");

    circle /= dip::Maximum(circle);
    dipImage3 *= 1 - circle;
    dip::Image my0d({0,255,0});
    dipImage3 += circle * my0d;

    cv::Size targetSize(1920, 1200);
    cv::Mat resizedImage;

    cv::resize(dip_opencv::CopyDipToMat(dipImage3), resizedImage, targetSize, 0, 0, cv::INTER_LINEAR);
    char name[256];
    snprintf(name, 256, "/home/hotcat/Downloads/new3dvision/controller/1/nozzlefitting%02d.png", index);
    cv::imwrite(name, resizedImage);

    return center_2d;
}


// Function to perform pairwise registration using Point-to-Plane ICP
std::pair<Eigen::Matrix4d, Eigen::Matrix6d> PairwiseRegistration(
    const std::shared_ptr<open3d::geometry::PointCloud> &source,
    const std::shared_ptr<open3d::geometry::PointCloud> &target,
    double max_correspondence_distance_coarse,
    double max_correspondence_distance_fine,
    bool robust = false) {

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


std::tuple<Eigen::Vector2d, double, double, double> LabelCenterAndOrientation(const open3d::geometry::PointCloud& pointcloud, double resolution, double morphology, Eigen::Vector2d adjustOffset, Eigen::Vector2d labelDenoise) {

    cv::Mat depth_map;
    cv::Mat flattened_image;

    if (pointcloud.IsEmpty()) {
        throw std::runtime_error("Point cloud is empty.");
    }

    // auto result = pointcloud.RemoveStatisticalOutliers(labelDenoise(0), labelDenoise(1));
    // auto result = pointcloud.RemoveRadiusOutliers(labelDenoise(0), labelDenoise(1));
    // auto filtered_pointcloud = std::get<0>(result);
    // auto filtered_pointcloud = &pointcloud;

    auto filtered_pointcloud = VoxelLargestComponentFilter(pointcloud, 0.05);

    // Get bounding box of the point cloud
    auto bbox = filtered_pointcloud->GetAxisAlignedBoundingBox();
    Eigen::Vector3d min_bound = bbox.min_bound_;
    Eigen::Vector3d max_bound = bbox.max_bound_;

    // Calculate dimensions of the output images
    int width = static_cast<int>((max_bound[0] - min_bound[0]) / resolution) + 1;
    int height = static_cast<int>((max_bound[1] - min_bound[1]) / resolution) + 1;

    // Initialize arrays for depth map and flattened image
    depth_map = cv::Mat::zeros(height, width, CV_32FC1); // Depth map as float
    flattened_image = cv::Mat::zeros(height, width, CV_8UC1); // Flattened binary image

    // Fill the depth map and flattened image
    for (const auto& point : filtered_pointcloud->points_) {
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
    dipImage2 = dip::Opening(dip::Closing(dipImage2, morphology), morphology);

    std::cout << "in step5 ... " << std::endl;

    // Labeling connected regions
    dipImage2 = dip::Label(dipImage2, 0, 25000);

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

    dip::Image dipImage3;
    dipImage2.Convert(dip::DT_BIN);
    dipImage3 = dip::Overlay(dipImage.Copy(), dipImage2-dip::BinaryErosion(dipImage2,1,1));

    cv::imwrite("/dev/shm/label_contour.png", dip_opencv::CopyDipToMat(dipImage3));

    std::cout << "in step8 ... " << std::endl;

    // Find contours in the binary image using OpenCV
    std::vector<std::vector<cv::Point>> contours;

    dipImage2.Convert(dip::DT_UINT8);
    dipImage2.At(dipImage2 > 0) = 255;
    cv::findContours(dip_opencv::CopyDipToMat(dipImage2), contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_TC89_L1);

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

    // dipImage2.Convert(dip::DT_BIN);
    // dip::ChainCodeArray ccs2 = dip::GetImageChainCodes(dip::Label(dipImage2), dip::UnsignedArray{});
    // double angle2 = ccs2[0].Polygon().Simplify(2).ConvexHull().Feret().minAngle;
    // angle2 = angle2 * 180.0 / CV_PI;
    // std::cout << angle2 << std::endl;

    // if (angle2 > 180) {
    //   angle2 -= 270;
    // } else if (angle2 > 90) {
    //   angle2 -= 180;
    // } else {
    //   angle2 -= 90;
    // }

    return std::make_tuple(center_2d, angle, w, h);
}


std::shared_ptr<geometry::PointCloud> DBSCANFilter(
    const std::shared_ptr<geometry::PointCloud>& pcd,
    double eps_scale = 2.0,  // multiplier for mean neighbor distance
    int min_points = 10) {

    // --- Compute mean nearest-neighbor distance ---
    std::vector<double> nn_dists = pcd->ComputeNearestNeighborDistance();
    double mean_dist = std::accumulate(nn_dists.begin(), nn_dists.end(), 0.0) / nn_dists.size();
    double eps = eps_scale * mean_dist;

    std::cout << "Mean NN distance: " << mean_dist << "  -> eps = " << eps << std::endl;

    // --- Run DBSCAN clustering ---
    std::vector<int> labels = pcd->ClusterDBSCAN(eps, min_points, false);
    int max_label = *std::max_element(labels.begin(), labels.end());
    std::cout << "DBSCAN detected " << max_label + 1 << " clusters" << std::endl;

    // --- Keep only clustered (non-noise) points ---
    std::vector<size_t> inlier_indices;
    for (size_t i = 0; i < labels.size(); ++i) {
        if (labels[i] >= 0)  // -1 means noise
            inlier_indices.push_back(i);
    }

    auto clean = pcd->SelectByIndex(inlier_indices);
    std::cout << "Filtered points: " << clean->points_.size()
              << " / " << pcd->points_.size() << std::endl;

    return clean;
}


std::shared_ptr<open3d::geometry::PointCloud>
VoxelLargestComponentFilter(
        const open3d::geometry::PointCloud &pcd,
        double voxelSize)
{
    // 1. Downsample
    auto down = pcd.VoxelDownSample(voxelSize);

    // 2. Prepare adjacency & BFS
    open3d::geometry::KDTreeFlann kdtree(*down);
    int n = down->points_.size();

    std::vector<bool> visited(n, false);
    std::vector<int> comp_id(n, -1);
    std::vector<int> comp_sizes;

    double radius = voxelSize * 2.5;

    int compIndex = 0;

    for (int i = 0; i < n; ++i) {
        if (visited[i]) continue;

        std::queue<int> q;
        q.push(i);

        visited[i] = true;
        comp_id[i] = compIndex;
        int count = 1;

        while (!q.empty()) {
            int cur = q.front(); q.pop();

            std::vector<int> idx;
            std::vector<double> dist2;
            kdtree.SearchRadius(down->points_[cur], radius, idx, dist2);

            for (int nb : idx) {
                if (!visited[nb]) {
                    visited[nb] = true;
                    comp_id[nb] = compIndex;
                    q.push(nb);
                    count++;
                }
            }
        }

        comp_sizes.push_back(count);
        compIndex++;
    }

    // 3. Find dominant component
    int largestComp = std::distance(
        comp_sizes.begin(),
        std::max_element(comp_sizes.begin(), comp_sizes.end())
    );

    // 4. Filter out other components
    auto filtered = std::make_shared<open3d::geometry::PointCloud>();
    for (int i = 0; i < n; ++i)
        if (comp_id[i] == largestComp)
            filtered->points_.push_back(down->points_[i]);

    return filtered;
}


// std::tuple<Eigen::Vector3d, double, Eigen::Vector3d> LabelCenterAndOrientation3d(const open3d::geometry::PointCloud& pointcloud, double resolution, double morphology, Eigen::Vector2d adjustOffset, Eigen::Vector2d labelDenoise) {
//   using Kernel = CGAL::Simple_cartesian<double>;
//   using Point2 = Kernel::Point_2;
//   cv::Mat depth_map;
//   cv::Mat flattened_image;
//   cv::Mat color_image;

//   if (pointcloud.IsEmpty()) {
//     throw std::runtime_error("Point cloud is empty.");
//   }

//   auto result = pointcloud.RemoveStatisticalOutliers(labelDenoise(0), labelDenoise(1));
//   auto filtered_pointcloud = std::get<0>(result);

//   // auto filtered_pointcloud = DBSCANFilter(std::make_shared<geometry::PointCloud>(pointcloud), labelDenoise(1), labelDenoise(0));

//   // Get bounding box of the point cloud
//   auto bbox = filtered_pointcloud->GetAxisAlignedBoundingBox();
//   Eigen::Vector3d min_bound = bbox.min_bound_;
//   Eigen::Vector3d max_bound = bbox.max_bound_;

//   // --- Add padding to avoid clipping the bounding box ---
//   double padding = resolution * 10.0; // you can tune this (10 pixels worth of margin)
//   min_bound.array() -= padding;
//   max_bound.array() += padding;

//   {
//     // Calculate dimensions of the output images
//     int width = static_cast<int>((max_bound[0] - min_bound[0]) / resolution) + 1;
//     int height = static_cast<int>((max_bound[1] - min_bound[1]) / resolution) + 1;

//     // Initialize arrays for depth map and flattened image
//     depth_map = cv::Mat::zeros(height, width, CV_32FC1); // Depth map as float
//     flattened_image = cv::Mat::zeros(height, width, CV_8UC1); // Flattened binary image

//     // Fill the depth map and flattened image
//     for (const auto& point : filtered_pointcloud->points_) {
//       int x_idx = static_cast<int>((point[0] - min_bound[0]) / resolution);
//       int y_idx = static_cast<int>((point[1] - min_bound[1]) / resolution);

//       // Update depth map with Z value
//       depth_map.at<float>(y_idx, x_idx) = static_cast<float>(point[2]);

//       // Flattened image marks the presence of a point
//       flattened_image.at<uchar>(y_idx, x_idx) = 255;
//     }

//     cv::cvtColor(flattened_image, color_image, cv::COLOR_GRAY2BGR);
//   }

//   // 1. Load point cloud (aligned XY)
//   open3d::geometry::PointCloud pcd;
//   // open3d::io::ReadPointCloud("partial.ply", pcd);
//   pcd = *filtered_pointcloud;

//   // 2. Build 2D points & Z extents
//   std::vector<Point2> pts2d;
//   double zmin = 1e9, zmax = -1e9;
//   for(auto& p : pcd.points_){
//     pts2d.emplace_back(p(0), p(1));
//     zmin = std::min(zmin, p(2));
//     zmax = std::max(zmax, p(2));
//   }

//   // 3. Convex hull
//   std::vector<Point2> hull;
//   CGAL::convex_hull_2(pts2d.begin(), pts2d.end(),
//                       std::back_inserter(hull));

//   // 4. Rotating calipers ¡ú OBB rectangle
//   std::vector<Point2> rect2d;
//   CGAL::min_rectangle_2(hull.begin(), hull.end(),
//                         std::back_inserter(rect2d));

//   // 5. Compute center & angle
//   double cx=0, cy=0;
//   for(auto& q: rect2d){ cx+=q.x(); cy+=q.y(); }
//   cx/=4; cy/=4;
//   double dx = rect2d[1].x()-rect2d[0].x();
//   double dy = rect2d[1].y()-rect2d[0].y();
//   double angle_deg = std::atan2(dy, dx)*180.0/M_PI;
//   double cz = 0.5*(zmin+zmax);

//   // 6. Output
//   std::cout<<"Center: ("<<cx<<","<<cy<<","<<cz<<")\n";
//   std::cout<<"Rotation about Z: "<<angle_deg<<" deg\n";

//   Eigen::Vector2d center_2d(cx, cy);

//   // width = distance between corner 0 and 1
//   double width = std::hypot(dx, dy);
//   // height = distance between corner 1 and 2 (adjacent edge)
//   double hdx = rect2d[2].x() - rect2d[1].x();
//   double hdy = rect2d[2].y() - rect2d[1].y();
//   double height = std::hypot(hdx, hdy);
//   // depth (thinkness) in Z
//   double depth = zmax - zmin;

//   Eigen::Vector3d extent(width, height, depth);

//   // Convert 3D center to pixel coordinates
//   Eigen::Vector2d center_px(
//       (center_2d(0) - min_bound[0]) / resolution,
//       (center_2d(1) - min_bound[1]) / resolution
//   );
  
//   // Convert extent to pixel size
//   float width_px  = extent(0) / resolution;
//   float height_px = extent(1) / resolution;
  
//   // Build the 2D rotated rectangle for visualization
//   cv::RotatedRect rect(
//       cv::Point2f(center_px(0), center_px(1)),
//       cv::Size2f(width_px, height_px),
//       static_cast<float>(angle_deg)
//   );
  
//   // Draw rectangle edges
//   cv::Point2f vertices[4];
//   rect.points(vertices);
//   for (int i = 0; i < 4; ++i) {
//       cv::line(color_image, vertices[i], vertices[(i + 1) % 4],
//                cv::Scalar(0, 255, 0), 1, cv::LINE_AA);
//   }

//   std::vector<cv::Point> contour;
//   for(int i = 0; i < 4; ++i)
//     contour.emplace_back(vertices[i]);

//   // --- Call minAreaRect to recover angle ---
//   cv::RotatedRect recovered = cv::minAreaRect(contour);
//   double angle = recovered.angle;
//   if (angle < -45.0) {
//         angle += 90.0; // Normalize angle to [-45, 45] range
//   }

//   Eigen::Vector3d adjusted_center(center_2d(0), center_2d(1), cz);

//   cv::imwrite("/dev/shm/label_contour.png", color_image);
  
//   return std::make_tuple(adjusted_center, angle, extent);
// }



std::tuple<Eigen::Vector3d, double, Eigen::Vector3d>
LabelCenterAndOrientation3d(const open3d::geometry::PointCloud& pointcloud,
                            double resolution, double morphology,
                            Eigen::Vector2d adjustOffset,
                            Eigen::Vector2d labelDenoise) {
  using Kernel = CGAL::Simple_cartesian<double>;
  using Point2 = Kernel::Point_2;
  cv::Mat depth_map, flattened_image, color_image;

  if (pointcloud.IsEmpty()) {
    throw std::runtime_error("Point cloud is empty.");
  }

  auto filtered_pointcloud = VoxelLargestComponentFilter(pointcloud, 0.05);

  // auto result = pointcloud.RemoveStatisticalOutliers(labelDenoise(0), labelDenoise(1));
  // auto filtered_pointcloud = std::get<0>(result);

  // auto filtered_pointcloud = DBSCANFilter(std::make_shared<geometry::PointCloud>(pointcloud), labelDenoise(1), labelDenoise(0));

  // Get bounding box of the point cloud
  auto bbox = filtered_pointcloud->GetAxisAlignedBoundingBox();
  Eigen::Vector3d min_bound = bbox.min_bound_;
  Eigen::Vector3d max_bound = bbox.max_bound_;

  // --- Initial padding to avoid clipping the raw cloud ---
  double padding = resolution * 10.0;
  min_bound.array() -= padding;
  max_bound.array() += padding;

  // Calculate image size
  int width  = static_cast<int>((max_bound[0] - min_bound[0]) / resolution) + 1;
  int height = static_cast<int>((max_bound[1] - min_bound[1]) / resolution) + 1;

  // Initialize arrays
  depth_map = cv::Mat::zeros(height, width, CV_32FC1);
  flattened_image = cv::Mat::zeros(height, width, CV_8UC1);

  // Fill images
  for (const auto& point : filtered_pointcloud->points_) {
    int x_idx = static_cast<int>((point[0] - min_bound[0]) / resolution);
    int y_idx = static_cast<int>((point[1] - min_bound[1]) / resolution);

    if (x_idx >= 0 && x_idx < width && y_idx >= 0 && y_idx < height) {
      depth_map.at<float>(y_idx, x_idx) = static_cast<float>(point[2]);
      flattened_image.at<uchar>(y_idx, x_idx) = 255;
    }
  }

  cv::cvtColor(flattened_image, color_image, cv::COLOR_GRAY2BGR);

  // --- Compute geometric properties ---
  open3d::geometry::PointCloud pcd = *filtered_pointcloud;

  std::vector<Point2> pts2d;
  double zmin = 1e9, zmax = -1e9;
  for (auto& p : pcd.points_) {
    pts2d.emplace_back(p(0), p(1));
    zmin = std::min(zmin, p(2));
    zmax = std::max(zmax, p(2));
  }

  std::vector<Point2> hull;
  CGAL::convex_hull_2(pts2d.begin(), pts2d.end(), std::back_inserter(hull));

  std::vector<Point2> rect2d;
  CGAL::min_rectangle_2(hull.begin(), hull.end(), std::back_inserter(rect2d));

  // --- Compute center and rotation ---
  double cx = 0, cy = 0;
  for (auto& q : rect2d) { cx += q.x(); cy += q.y(); }
  cx /= 4; cy /= 4;
  double dx = rect2d[1].x() - rect2d[0].x();
  double dy = rect2d[1].y() - rect2d[0].y();
  double angle_deg = std::atan2(dy, dx) * 180.0 / M_PI;
  double cz = 0.5 * (zmin + zmax);

  Eigen::Vector2d center_2d(cx, cy);
  double width_world = std::hypot(dx, dy);
  double hdx = rect2d[2].x() - rect2d[1].x();
  double hdy = rect2d[2].y() - rect2d[1].y();
  double height_world = std::hypot(hdx, hdy);
  double depth = zmax - zmin;

  Eigen::Vector3d extent(width_world, height_world, depth);

  // --- Convert to pixel coordinates ---
  Eigen::Vector2d center_px(
      (center_2d(0) - min_bound[0]) / resolution,
      (center_2d(1) - min_bound[1]) / resolution
  );
  float width_px  = extent(0) / resolution;
  float height_px = extent(1) / resolution;

  cv::RotatedRect rect(cv::Point2f(center_px(0), center_px(1)),
                       cv::Size2f(width_px, height_px),
                       static_cast<float>(angle_deg));

  // --- Ensure full rectangle fits into the image ---
  cv::Point2f vertices[4];
  rect.points(vertices);

  float xmin = std::numeric_limits<float>::max();
  float ymin = std::numeric_limits<float>::max();
  float xmax = std::numeric_limits<float>::lowest();
  float ymax = std::numeric_limits<float>::lowest();
  for (int i = 0; i < 4; ++i) {
    xmin = std::min(xmin, vertices[i].x);
    ymin = std::min(ymin, vertices[i].y);
    xmax = std::max(xmax, vertices[i].x);
    ymax = std::max(ymax, vertices[i].y);
  }

  // Check if it goes out of bounds
  int extra_left   = std::max(0, static_cast<int>(-xmin + 10));
  int extra_top    = std::max(0, static_cast<int>(-ymin + 10));
  int extra_right  = std::max(0, static_cast<int>(xmax - color_image.cols + 10));
  int extra_bottom = std::max(0, static_cast<int>(ymax - color_image.rows + 10));

  if (extra_left > 0 || extra_top > 0 || extra_right > 0 || extra_bottom > 0) {
    cv::copyMakeBorder(color_image, color_image,
                       extra_top, extra_bottom, extra_left, extra_right,
                       cv::BORDER_CONSTANT, cv::Scalar(0, 0, 0));

    // Shift vertices accordingly
    for (auto& v : vertices) {
      v.x += extra_left;
      v.y += extra_top;
    }
  }

  // --- Draw rectangle on extended image ---
  for (int i = 0; i < 4; ++i) {
    cv::line(color_image, vertices[i], vertices[(i + 1) % 4],
             cv::Scalar(0, 255, 0), 1, cv::LINE_AA);
  }

  cv::imwrite("/dev/shm/label_contour.png", color_image);

  std::vector<cv::Point> contour;
  for(int i = 0; i < 4; ++i)
    contour.emplace_back(vertices[i]);

  // --- Call minAreaRect to recover angle ---
  cv::RotatedRect recovered = cv::minAreaRect(contour);
  double angle = recovered.angle;
  if (angle < -45.0) {
        angle += 90.0; // Normalize angle to [-45, 45] range
  }

  Eigen::Vector3d adjusted_center(center_2d(0), center_2d(1), cz);
  return std::make_tuple(adjusted_center, angle, extent);
}


std::tuple<Eigen::Vector3d, double, Eigen::Vector3d> Reconstruct::getPointCloud3dWrap(int index) {
  using Kernel = CGAL::Simple_cartesian<double>;
  using Point2 = Kernel::Point_2;
  cv::Mat depth_map;
  cv::Mat flattened_image;
  cv::Mat color_image;

  double resolution = (index == 0 || index == 2)?labelResolution:productResolution;
  Eigen::Vector2d denoise = (index == 0 || index == 2)?labelDenoise:productDenoise;
  bool partial = (index == 0 && (configIndex == 1 || configIndex == 2));
  bool setlabelExtent = (index == 2) && (configIndex == 1 || configIndex == 2);
  const open3d::geometry::PointCloud& pointcloud = i2PC(index);

  if (pointcloud.IsEmpty()) {
    throw std::runtime_error("Point cloud is empty.");
  }

  // auto result = pointcloud.RemoveStatisticalOutliers(denoise(0), denoise(1));
  // // auto result = pointcloud.RemoveRadiusOutliers(denoise(0), denoise(1));
  // auto filtered_pointcloud = std::get<0>(result);

  // auto filtered_pointcloud = DBSCANFilter(std::make_shared<geometry::PointCloud>(pointcloud), denoise(1), denoise(0));


  auto filtered_pointcloud = VoxelLargestComponentFilter(pointcloud, 0.05);

  // Get bounding box of the point cloud
  auto bbox = filtered_pointcloud->GetAxisAlignedBoundingBox();
  Eigen::Vector3d min_bound = bbox.min_bound_;
  Eigen::Vector3d max_bound = bbox.max_bound_;

  // --- Initial padding to avoid clipping the raw cloud ---
  double padding = resolution * 10.0;
  min_bound.array() -= padding;
  max_bound.array() += padding;

  // Calculate image size
  int width  = static_cast<int>((max_bound[0] - min_bound[0]) / resolution) + 1;
  int height = static_cast<int>((max_bound[1] - min_bound[1]) / resolution) + 1;

  // Initialize arrays
  depth_map = cv::Mat::zeros(height, width, CV_32FC1);
  flattened_image = cv::Mat::zeros(height, width, CV_8UC1);

  // Fill images
  for (const auto& point : filtered_pointcloud->points_) {
    int x_idx = static_cast<int>((point[0] - min_bound[0]) / resolution);
    int y_idx = static_cast<int>((point[1] - min_bound[1]) / resolution);

    if (x_idx >= 0 && x_idx < width && y_idx >= 0 && y_idx < height) {
      depth_map.at<float>(y_idx, x_idx) = static_cast<float>(point[2]);
      flattened_image.at<uchar>(y_idx, x_idx) = 255;
    }
  }

  cv::cvtColor(flattened_image, color_image, cv::COLOR_GRAY2BGR);

  // --- Compute geometric properties ---
  open3d::geometry::PointCloud pcd = *filtered_pointcloud;

  std::vector<Point2> pts2d;
  double zmin = 1e9, zmax = -1e9;
  for (auto& p : pcd.points_) {
    pts2d.emplace_back(p(0), p(1));
    zmin = std::min(zmin, p(2));
    zmax = std::max(zmax, p(2));
  }

  std::vector<Point2> hull;
  CGAL::convex_hull_2(pts2d.begin(), pts2d.end(), std::back_inserter(hull));

  std::vector<Point2> rect2d;
  CGAL::min_rectangle_2(hull.begin(), hull.end(), std::back_inserter(rect2d));

  // --- Compute center and rotation ---
  double cx = 0, cy = 0;
  for (auto& q : rect2d) { cx += q.x(); cy += q.y(); }
  cx /= 4; cy /= 4;
  double dx = rect2d[1].x() - rect2d[0].x();
  double dy = rect2d[1].y() - rect2d[0].y();
  double angle_deg = std::atan2(dy, dx) * 180.0 / M_PI;
  double cz = 0.5 * (zmin + zmax);

  Eigen::Vector2d center_2d(cx, cy);
  double width_world = std::hypot(dx, dy);
  double hdx = rect2d[2].x() - rect2d[1].x();
  double hdy = rect2d[2].y() - rect2d[1].y();
  double height_world = std::hypot(hdx, hdy);
  double depth = zmax - zmin;

  Eigen::Vector3d extent(width_world, height_world, depth);

  // --- Convert to pixel coordinates ---
  Eigen::Vector2d center_px(
      (center_2d(0) - min_bound[0]) / resolution,
      (center_2d(1) - min_bound[1]) / resolution
  );
  float width_px  = extent(0) / resolution;
  float height_px = extent(1) / resolution;

  cv::RotatedRect rect(cv::Point2f(center_px(0), center_px(1)),
                       cv::Size2f(width_px, height_px),
                       static_cast<float>(angle_deg));

  // --- Ensure full rectangle fits into the image ---
  cv::Point2f vertices[4];
  rect.points(vertices);

  float xmin = std::numeric_limits<float>::max();
  float ymin = std::numeric_limits<float>::max();
  float xmax = std::numeric_limits<float>::lowest();
  float ymax = std::numeric_limits<float>::lowest();
  for (int i = 0; i < 4; ++i) {
    xmin = std::min(xmin, vertices[i].x);
    ymin = std::min(ymin, vertices[i].y);
    xmax = std::max(xmax, vertices[i].x);
    ymax = std::max(ymax, vertices[i].y);
  }

  // Check if it goes out of bounds
  int extra_left   = std::max(0, static_cast<int>(-xmin + 10));
  int extra_top    = std::max(0, static_cast<int>(-ymin + 10));
  int extra_right  = std::max(0, static_cast<int>(xmax - color_image.cols + 10));
  int extra_bottom = std::max(0, static_cast<int>(ymax - color_image.rows + 10));

  if (extra_left > 0 || extra_top > 0 || extra_right > 0 || extra_bottom > 0) {
    cv::copyMakeBorder(color_image, color_image,
                       extra_top, extra_bottom, extra_left, extra_right,
                       cv::BORDER_CONSTANT, cv::Scalar(0, 0, 0));

    // Shift vertices accordingly
    for (auto& v : vertices) {
      v.x += extra_left;
      v.y += extra_top;
    }
  }

  // --- Draw rectangle on extended image ---
  for (int i = 0; i < 4; ++i) {
    cv::line(color_image, vertices[i], vertices[(i + 1) % 4],
             cv::Scalar(0, 255, 0), 1, cv::LINE_AA);
  }

  switch (index) {
    case 0:
      cv::imwrite("/dev/shm/label_contour.png", color_image);
      break;

    case 2:
      cv::imwrite("/dev/shm/label_centric.png", color_image);
      
    case 3:
      cv::imwrite("/dev/shm/product_centric.png", color_image);
      break;

    default:
      break;
  }

  std::vector<cv::Point> contour;
  for(int i = 0; i < 4; ++i)
    contour.emplace_back(vertices[i]);

  // --- Call minAreaRect to recover angle ---
  cv::RotatedRect recovered = cv::minAreaRect(contour);
  double angle = recovered.angle;
  if (angle < -45.0) {
        angle += 90.0; // Normalize angle to [-45, 45] range
  }

  Eigen::Vector3d adjusted_center;

  adjusted_center = {center_2d(0), center_2d(1), cz};

  double rad = angle * M_PI /180.0;

  // Construct the 2x2 rotation matrix
  Eigen::Matrix2d R;
  R << std::cos(rad), -std::sin(rad),
    std::sin(rad),  std::cos(rad);

  // Compute the adjusted center:
  Eigen::Vector2d c = center_2d + R * (Eigen::Vector2d{0.0, (labelExtent(1) - ((angle > 0)?width_world:height_world))/2.0});
  Eigen::Vector3d adjusted_center2(c(0), c(1), cz);

  if(setlabelExtent) {
    labelExtent(0) = min(extent(0), extent(1));
    labelExtent(1) = max(extent(0), extent(1));
  }

  if(partial) {
    Eigen::Vector3d extent2(labelExtent(0), labelExtent(1), depth);
    return std::make_tuple(adjusted_center2, angle, extent2);
  } else {
    return std::make_tuple(adjusted_center, angle_deg, extent);
  }
}


std::tuple<Eigen::Vector3d, double, Eigen::Vector3d> LabelCenterAndOrientation3dPartial(const open3d::geometry::PointCloud& pointcloud, double resolution, double morphology, Eigen::Vector2d adjustOffset, Eigen::Vector2d labelDenoise, Eigen::Vector2d labelExtent) {
  using Kernel = CGAL::Simple_cartesian<double>;
  using Point2 = Kernel::Point_2;
  cv::Mat depth_map;
  cv::Mat flattened_image;
  cv::Mat color_image;

  if (pointcloud.IsEmpty()) {
    throw std::runtime_error("Point cloud is empty.");
  }

  auto result = pointcloud.RemoveStatisticalOutliers(labelDenoise(0), labelDenoise(1));
  auto filtered_pointcloud = std::get<0>(result);

  // auto filtered_pointcloud = DBSCANFilter(std::make_shared<geometry::PointCloud>(pointcloud), labelDenoise(1), labelDenoise(0));

  // Get bounding box of the point cloud
  auto bbox = filtered_pointcloud->GetAxisAlignedBoundingBox();
  Eigen::Vector3d min_bound = bbox.min_bound_;
  Eigen::Vector3d max_bound = bbox.max_bound_;

  // --- Add padding to avoid clipping the bounding box ---
  double padding = resolution * 10.0; // you can tune this (10 pixels worth of margin)
  min_bound.array() -= padding;
  max_bound.array() += padding;
  
  {

    // Calculate dimensions of the output images
    int width = static_cast<int>((max_bound[0] - min_bound[0]) / resolution) + 1;
    int height = static_cast<int>((max_bound[1] - min_bound[1]) / resolution) + 1;

    // Initialize arrays for depth map and flattened image
    depth_map = cv::Mat::zeros(height, width, CV_32FC1); // Depth map as float
    flattened_image = cv::Mat::zeros(height, width, CV_8UC1); // Flattened binary image

    // Fill the depth map and flattened image
    for (const auto& point : filtered_pointcloud->points_) {
      int x_idx = static_cast<int>((point[0] - min_bound[0]) / resolution);
      int y_idx = static_cast<int>((point[1] - min_bound[1]) / resolution);

      // Update depth map with Z value
      depth_map.at<float>(y_idx, x_idx) = static_cast<float>(point[2]);

      // Flattened image marks the presence of a point
      flattened_image.at<uchar>(y_idx, x_idx) = 255;
    }

    cv::cvtColor(flattened_image, color_image, cv::COLOR_GRAY2BGR);
  }

  // 1. Load point cloud (aligned XY)
  open3d::geometry::PointCloud pcd;
  // open3d::io::ReadPointCloud("partial.ply", pcd);
  pcd = *filtered_pointcloud;

  // 2. Build 2D points & Z extents
  std::vector<Point2> pts2d;
  double zmin = 1e9, zmax = -1e9;
  for(auto& p : pcd.points_){
    pts2d.emplace_back(p(0), p(1));
    zmin = std::min(zmin, p(2));
    zmax = std::max(zmax, p(2));
  }

  // 3. Convex hull
  std::vector<Point2> hull;
  CGAL::convex_hull_2(pts2d.begin(), pts2d.end(),
                      std::back_inserter(hull));

  // 4. Rotating calipers ¡ú OBB rectangle
  std::vector<Point2> rect2d;
  CGAL::min_rectangle_2(hull.begin(), hull.end(),
                        std::back_inserter(rect2d));

  // 5. Compute center & angle
  double cx=0, cy=0;
  for(auto& q: rect2d){ cx+=q.x(); cy+=q.y(); }
  cx/=4; cy/=4;
  double dx = rect2d[1].x()-rect2d[0].x();
  double dy = rect2d[1].y()-rect2d[0].y();
  double angle_deg = std::atan2(dy, dx)*180.0/M_PI;
  double cz = 0.5*(zmin+zmax);

  // 6. Output
  std::cout<<"Center: ("<<cx<<","<<cy<<","<<cz<<")\n";
  std::cout<<"Rotation about Z: "<<angle_deg<<" deg\n";

  Eigen::Vector2d center_2d(cx, cy);

  // width = distance between corner 0 and 1
  double width = std::hypot(dx, dy);
  // height = distance between corner 1 and 2 (adjacent edge)
  double hdx = rect2d[2].x() - rect2d[1].x();
  double hdy = rect2d[2].y() - rect2d[1].y();
  double height = std::hypot(hdx, hdy);
  // depth (thinkness) in Z
  double depth = zmax - zmin;

  // Eigen::Vector3d extent(width, height, depth);
  Eigen::Vector3d extent(labelExtent(0), labelExtent(1), depth);


  // Convert 3D center to pixel coordinates
  Eigen::Vector2d center_px(
      (center_2d(0) - min_bound[0]) / resolution,
      (center_2d(1) - min_bound[1]) / resolution
  );
  
  // Convert extent to pixel size
  float width_px  = extent(0) / resolution;
  float height_px = extent(1) / resolution;
  
  // Build the 2D rotated rectangle for visualization
  cv::RotatedRect rect(
      cv::Point2f(center_px(0), center_px(1)),
      cv::Size2f(width_px, height_px),
      static_cast<float>(angle_deg)
  );
  
  // Draw rectangle edges
  cv::Point2f vertices[4];
  rect.points(vertices);
  for (int i = 0; i < 4; ++i) {
      cv::line(color_image, vertices[i], vertices[(i + 1) % 4],
               cv::Scalar(0, 255, 0), 1, cv::LINE_AA);
  }

  std::vector<cv::Point> contour;
  for(int i = 0; i < 4; ++i)
    contour.emplace_back(vertices[i]);

  // --- Call minAreaRect to recover angle ---
  cv::RotatedRect recovered = cv::minAreaRect(contour);
  double angle = recovered.angle;
  if (angle < -45.0) {
        angle += 90.0; // Normalize angle to [-45, 45] range
  }

  double rad = angle * M_PI /180.0;

  // Construct the 2x2 rotation matrix
  Eigen::Matrix2d R;
  R << std::cos(rad), -std::sin(rad),
    std::sin(rad),  std::cos(rad);

  // Compute the adjusted center:
  // Eigen::Vector2d adjusted_center = center_2d + R * (Eigen::Vector2d{0.0, (angle > 0)?(extent(1) - width)/2.0:(extent(1) - height)/2.0});
  Eigen::Vector2d adjusted_center = center_2d + R * (Eigen::Vector2d{0.0, (extent(1) - ((angle > 0)?width:height))/2.0});
  Eigen::Vector3d adjusted_center2(adjusted_center(0), adjusted_center(1), cz);

  return std::make_tuple(adjusted_center2, angle, extent);
}



std::tuple<Eigen::Vector2d, double> ProductCenterAndOrientation(const open3d::geometry::PointCloud& pointcloud, double resolution, double distance, double morphology, Eigen::Vector2d productDenoise) {

    cv::Mat depth_map;
    cv::Mat flattened_image;

    if (pointcloud.IsEmpty()) {
        throw std::runtime_error("Point cloud is empty.");
    }

    auto result = pointcloud.RemoveStatisticalOutliers(productDenoise(0), productDenoise(1));
    // auto result = pointcloud.RemoveRadiusOutliers(productDenoise(0), productDenoise(1));
    auto filtered_pointcloud = std::get<0>(result);
    // auto filtered_pointcloud = &pointcloud;

    std::vector<size_t> inliers;
    Eigen::Vector4d plane_model;
    double distance_threshold = distance; // Adjust this value based on your needs
    int ransac_n = 3;
    int num_iterations = 1000;
    std::tie(plane_model, inliers) = filtered_pointcloud->SegmentPlane(distance_threshold, ransac_n, num_iterations);

    auto plane_points = filtered_pointcloud->SelectByIndex(inliers);

    // io::WritePointCloudToPLY("/home/hotcat/Downloads/dipexp/label/debug.ply", *plane_points, true);

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

    dipImage2 = ~dipImage2;

    std::cout << "in step2 ..." << std::endl;

    dipImage2.Convert(dip::DT_BIN);

    // // Remove edge objects
    // dipImage2 = dip::EdgeObjectsRemove(dipImage2);

    std::cout << "in step3 ... " << std::endl;

    // Morphological Opening
    dipImage2 = dip::Opening(dipImage2, morphology);

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

    dip::Image dipImage3;
    dipImage2.Convert(dip::DT_BIN);
    dipImage3 = dip::Overlay(dip_opencv::MatToDip(flattened_image).Copy(), dipImage2-dip::BinaryErosion(dipImage2,1,1));

    cv::imwrite("/dev/shm/product_groove.png", dip_opencv::CopyDipToMat(dipImage3));

    std::cout << "in step8 ... " << std::endl;

    // Find contours in the binary image using OpenCV
    std::vector<std::vector<cv::Point>> contours;

    dipImage2.Convert(dip::DT_UINT8);
    dipImage2.At(dipImage2 > 0) = 255;
    cv::findContours(dip_opencv::CopyDipToMat(dipImage2), contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_TC89_L1);

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

    // dipImage2.Convert(dip::DT_BIN);
    // dip::ChainCodeArray ccs2 = dip::GetImageChainCodes(dip::Label(dipImage2), dip::UnsignedArray{});
    // double angle2 = ccs2[0].Polygon().Simplify(2).ConvexHull().Feret().minAngle;
    // angle2 = angle2 * 180.0 / CV_PI;
    // std::cout << angle2 << std::endl;

    // if (angle2 > 180) {
    //   angle2 -= 270;
    // } else if (angle2 > 90) {
    //   angle2 -= 180;
    // } else {
    //   angle2 -= 90;
    // }

    return std::make_tuple(center_2d, angle);
}



std::tuple<Eigen::Vector3d, double, Eigen::Vector3d> GrooveCenterAndOrientation(const open3d::geometry::PointCloud& pointcloud, double resolution, double distance, double morphology, Eigen::Vector2d productDenoise) {
  if (pointcloud.IsEmpty()) {
    throw std::runtime_error("Point cloud is empty.");
  }

  auto result = pointcloud.RemoveStatisticalOutliers(productDenoise(0), productDenoise(1));
  // auto result = pointcloud.RemoveRadiusOutliers(productDenoise(0), productDenoise(1));
  auto filtered_pointcloud = std::get<0>(result);
  // auto filtered_pointcloud = &pointcloud;

  std::vector<size_t> inliers;
  Eigen::Vector4d plane_model;
  double distance_threshold = distance; // Adjust this value based on your needs
  int ransac_n = 3;
  int num_iterations = 1000;
  std::tie(plane_model, inliers) = filtered_pointcloud->SegmentPlane(distance_threshold, ransac_n, num_iterations);

  auto plane_points = filtered_pointcloud->SelectByIndex(inliers);

  open3d::io::WritePointCloud("/home/hotcat/Downloads/new3dvision/myplys/Groove.ply", *plane_points, true);

  // plane_points->EstimateNormals(geometry::KDTreeSearchParamHybrid(0.01, 30));

  // std::vector<double> radii = {0.005, 0.01, 0.02}; // tune to point spacing
  // auto mesh_bp = geometry::TriangleMesh::CreateFromPointCloudBallPivoting(*plane_points, radii);
  // io::WriteTriangleMesh("/home/hotcat/Downloads/new3dvision/myplys/Groove_mesh.ply", *mesh_bp);



  GrooveOBB obb(*plane_points);
  auto ctr = obb.center();
  auto ext = obb.extent();
  double ang = obb.angle();


  // CircleFitting circlefit(*plane_points);
  // if (circlefit.is_valid()) {
  //   Eigen::Vector3d ctr = circlefit.center();
  //   double r = circlefit.radius();
  //   return std::make_tuple(ctr, 0, Eigen::Vector3d{2*r,2*r,2*r});
  //   // return std::make_tuple(Eigen::Vector3d{0,0,0}, 0, Eigen::Vector3d{0,0,0});
  // }

  // return std::make_tuple(Eigen::Vector3d{0,0,0}, 0, Eigen::Vector3d{0,0,0});


  return std::make_tuple(ctr, ang * 180.0 / M_PI, ext);
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

  std::cout << "omp_get_max_threads: " << omp_get_max_threads() << std::endl;
  
  calib.load("/home/hotcat/Downloads/new3dvision/controller/1/calibration.xml");
  triangulator = new Triangulator(calib);

  open3d::geometry::PointCloud cloud;
  // if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/Multiple_Planes_Detection/1/trans5.ply", cloud)) {
  // if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/1/decoder/research6.ply", cloud)) {
  // if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/dipexp/label/my5.ply", cloud)) {
  // if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/1/decoder/my.ply", cloud)) {

  // if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/myplys/pingan.ply", cloud)) {
  if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/myplys/lastcalibration/my2key.ply", cloud)) {
  
  // if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/myplys/my2.ply", cloud)) {
  
  // if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/1/decoder/ultraaaaaaaaaaaaa/labelTempPC.ply", cloud)) {
  // if (open3d::io::ReadPointCloud("/home/hotcat/Downloads/new3dvision/controller/1/decoder/tinyyyyyyyy/labelTempPC2.ply", cloud)) {
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
  configIndex = 0;
  labelMorphology = 8;
  productMorphology = 50;
  labelResolution = 0.07;
  productResolution = 0.07;
  distanceThreshold = 0.09;
  nozzleResolution = 0.05;
  nozzleThreshold = 0.09;
  adjustOffset = {0.0,0.0};
  labelDenoise = {10.0,1.0};
  productDenoise = {10.0,1.0};
  labelExtent = {32.7321, 41.521};

  profiloThreshold = 50;
  labelBox = Eigen::Matrix4f::Identity();
  productBox = Eigen::Matrix4f::Identity();
  
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


int Reconstruct::conductProduction(const cv::Mat& mat, int thresh) {
  if(matSequence.size() < 6) {
    std::vector<cv::Mat> channels;
    cv::split(mat, channels);
    matSequence.push_back(channels[0]);
  } else CV_Assert(false);


  // if(matSequence.size() == 6) {
  //   cv::imwrite("/dev/shm/1.png", matSequence[0]);
  //   cv::imwrite("/dev/shm/2.png", matSequence[1]);
  //   cv::imwrite("/dev/shm/3.png", matSequence[2]);
  //   cv::imwrite("/dev/shm/4.png", matSequence[3]);
  //   cv::imwrite("/dev/shm/5.png", matSequence[4]);
  //   cv::imwrite("/dev/shm/6.png", matSequence[5]);
  // }

  // Check if we have collected 6 Mat objects
  if(matSequence.size() == 6) {
    buildPointCloud(matSequence, thresh);
    matSequence.clear();
    if(calibSequence == -4) {
      processAlignment();
    }
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
  auto start = std::chrono::high_resolution_clock::now();
  
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


  auto end = std::chrono::high_resolution_clock::now();

  auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

  std::cout << "convertToPointCloud Time spent: " << duration << " microseconds" << std::endl;



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


geometry::PointCloud Reconstruct::buildPointCloud(const std::vector<cv::Mat>& mats, int thresh) {
  auto start = std::chrono::high_resolution_clock::now();
  
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

  cv::imwrite("/dev/shm/shading.png", shading);

  cv::Mat deepMat;
  triangulator->triangulate(up, vp, mask, shading, deepMat);

  // Create an empty PointCloud
  // geometry::PointCloud pointCloud;
  pointCloud.Clear();

  // // Determine the number of threads
  // int numThreads = omp_get_max_threads();

  // // Preallocate a vector for each thread
  // std::vector<std::vector<Eigen::Vector3d>> threadPoints(numThreads);
  // std::vector<std::vector<Eigen::Vector3d>> threadColors(numThreads);

  // // Parallel loop over image rows and columns
  // #pragma omp parallel for collapse(2)
  // // Convert CV_32FC3 Mat to Open3D PointCloud
  // for(int y = 0; y < deepMat.rows; ++y) {
  //   for(int x = 0; x < deepMat.cols; ++x) {
  //     Vec3f xyz = deepMat.at<Vec3f>(y, x);
  //     // std::cout << "xyz: " << xyz << '\n';
  //     unsigned char shade = shading.at<unsigned char>(y, x);
  //     if(xyz[0] != 0 && xyz[1] != 0 && xyz[2] != 0) {
  // 	Eigen::Vector3d point(xyz[0],xyz[1], xyz[2]);
  // 	Eigen::Vector3d color(shade/255.0, shade/255.0, shade/255.0);
  // 	// Each thread uses its own index
  // 	int tid = omp_get_thread_num();
  // 	threadPoints[tid].push_back(point);
  // 	threadColors[tid].push_back(color);
  //     }
  //   }
  // }

  // // Merge thread-local vectors into the pointCloud
  // for(int i = 0; i < numThreads; ++i) {
  //   pointCloud.points_.insert(pointCloud.points_.end(),
  // 			      threadPoints[i].begin(), threadPoints[i].end());
  //   pointCloud.colors_.insert(pointCloud.colors_.end(),
  // 			      threadColors[i].begin(), threadColors[i].end());
  // }


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
    // computePitchAngle();
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

  // io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/my.ply", pointCloud, true);
  // io::WritePointCloudToPLY("/dev/shm/my.ply", pointCloud, true);

  auto end = std::chrono::high_resolution_clock::now();

  auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

  std::cout << "buildPointCloud Time spent: " << duration << " microseconds" << std::endl;


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

  // // Save the transformed point cloud
  // if (!open3d::io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/transformed.ply", pcd, true)) {
  //   std::cerr << "Failed to write transformed point cloud!" << std::endl;
  //   return -1;
  // }

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

geometry::PointCloud Reconstruct::i2PC(int index) {
  switch (index) {
    case 0:
      return labelPC;

    case 1:
      return productPC;

    case 2:
      return labelTempPC;

    case 3:
      return productTempPC;
  }
}


Eigen::Matrix4f Reconstruct::getWrapModel(int index) {

  // // Segment plane
  // std::vector<size_t> inliers;
  // Eigen::Vector4d plane_model;
  // double distance_threshold = 0.09; // Adjust this value based on your needs
  // int ransac_n = 4;
  // int num_iterations = 10000;

  // std::tie(plane_model, inliers) = labelPC.SegmentPlane(distance_threshold, ransac_n, num_iterations);

  // std::cout << "label Plane equation: " << plane_model(0) << "x + " << plane_model(1) 
  // 	    << "y + " << plane_model(2) << "z + " << plane_model(3) << " = 0" << std::endl;

  try {
    auto start = std::chrono::high_resolution_clock::now();

    auto [label_center, label_angle, w, h] = LabelCenterAndOrientation(labelPC, labelResolution, labelMorphology, Eigen::Vector2d{0.0, 0.0}, Eigen::Vector2d{10.0, 1.0});
    Eigen::Vector3d extent{w,h,1};
    // auto [label_center, label_angle, extent] = getPointCloud3dWrap(index);
    // auto [label_center, label_angle, extent] = LabelCenterAndOrientation3dPartial(labelPC, labelResolution, labelMorphology, Eigen::Vector2d{0.0, 0.0}, Eigen::Vector2d{10.0, 1.0}, labelExtent);
    // auto [label_center, label_angle, extent] = LabelCenterAndOrientation3d(labelPC, labelResolution, labelMorphology, Eigen::Vector2d{0.0, 0.0}, Eigen::Vector2d{10.0, 1.0});

    // auto [label_center, label_angle, extent] = GrooveCenterAndOrientation(labelPC, labelResolution, distanceThreshold, labelMorphology, labelDenoise);
    std::cout << "label angle: " << label_angle << " degrees" << std::endl;
    std::cout << "x: " << label_center[0] << std::endl;
    std::cout << "y: " << label_center[1] << std::endl;
    std::cout << "extent: " << extent <<std::endl;

    auto end = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
    std::cout << "getWrapModel: " << duration << " microseconds" << std::endl;

    double x0 = label_center[0];
    double y0 = label_center[1];

    // double z_plane = (-plane_model(3) - plane_model(0) * x0 - plane_model(1) * y0) / plane_model(2);
    // std::cout << "test z_plane: " << z_plane << std::endl;

    Eigen::Matrix4f gizmo;
    gizmo = alignGizmoToLabel({label_center(0)/10.0, label_center(1)/10.0, label_center(2)/10.0}, label_angle);
    w > h ? setWrapModel(CreateGizmoModelMatrix(gizmo, w*labelResolution/10.0, h*labelResolution/10.0, 0.1f)):setWrapModel(CreateGizmoModelMatrix(gizmo, h*labelResolution/10.0, w*labelResolution/10.0, 0.1f));
    // w > h ? setWrapModel(CreateGizmoModelMatrix(gizmo, w/10.0, h/10.0, 0.1f)):setWrapModel(CreateGizmoModelMatrix(gizmo, h/10.0, w/10.0, 0.1f));
    // setWrapModel(CreateGizmoModelMatrix(gizmo, extent(0)/10.0, extent(1)/10.0, extent(2)/10.0));

  } catch (const std::exception& e) {
    std::cerr << "Error: " << e.what() << std::endl;
  }

  return wrapBoxModel;
}


Eigen::Matrix4d estimateTransform2(const Eigen::Vector2d& source_center,
                                  double source_angle,
                                  const Eigen::Vector2d& template_center,
				   double template_angle);

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
    double distance_threshold = 0.09; // Adjust this value based on your needs
    int ransac_n = 4;
    int num_iterations = 10000;

    std::tie(plane_model, inliers) = cropped_cloud->SegmentPlane(
							     distance_threshold, ransac_n, num_iterations);

    std::cout << "label Plane equation: " << plane_model(0) << "x + " << plane_model(1) 
	      << "y + " << plane_model(2) << "z + " << plane_model(3) << " = 0" << std::endl;

    try {
      auto [label_center, label_angle, w, h] = LabelCenterAndOrientation(*cropped_cloud, labelResolution, labelMorphology, Eigen::Vector2d{0.0, 0.0}, labelDenoise);
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

  if(seq/10 == -6) {

    try {
      auto nozzle_center = CalibrateNozzleCenter(*cropped_cloud, nozzleResolution, nozzleThreshold, std::abs(seq % 10));
      std::cout << "nozzle x: " << nozzle_center[0] << std::endl;
      std::cout << "nozzle y: " << nozzle_center[1] << std::endl;

      setTargetTranslation({nozzle_center(0), nozzle_center(1), 0.0});
      
    } catch (const std::exception& e) {
      std::cerr << "Error: " << e.what() << std::endl;
      if(std::abs(seq % 10) == 6) {
	calibSequence = -8;
      } else {
	calibSequence = -7;
      }
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

      if(configIndex == 1 || configIndex == 2)
      {
	auto [label_center, label_angle, extent] = LabelCenterAndOrientation3d(labelTempPC, labelResolution, labelMorphology, Eigen::Vector2d{0.0, 0.0}, labelDenoise);
	auto trans1 = estimateTransform2(Eigen::Vector2d{label_center(0), label_center(1)}, label_angle, Eigen::Vector2d{0.0, 0.0}, 0.0);
	// auto result = labelTempPC.RemoveStatisticalOutliers(labelDenoise(0), labelDenoise(1));
	// auto filtered_pointcloud = std::get<0>(result);
	// labelTempPC = (*filtered_pointcloud).Transform(trans1);
	labelTempPC = labelTempPC.Transform(trans1);
	*cropped_cloud = labelTempPC;
      }

      io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/labelTempPC.ply", labelTempPC, true);
      delta_z = 0.01;
      break;

    case 3:
      productTempPC = *cropped_cloud;
      myPC = &transiProductTemp;

      if(configIndex == 1 || configIndex == 2)
      {
	auto [product_center, product_angle, extent] = LabelCenterAndOrientation3d(productTempPC, productResolution, productMorphology, Eigen::Vector2d{0.0, 0.0}, productDenoise);
	auto trans1 = estimateTransform2(Eigen::Vector2d{product_center(0), product_center(1)}, product_angle, Eigen::Vector2d{0.0, 0.0}, 0.0);
	// auto result = productTempPC.RemoveStatisticalOutliers(productDenoise(0), productDenoise(1));
	// auto filtered_pointcloud = std::get<0>(result);
	// productTempPC = (*filtered_pointcloud).Transform(trans1);
	productTempPC = productTempPC.Transform(trans1);
	*cropped_cloud = productTempPC;
      }

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


double getRotationAngleXY2(const Eigen::Matrix4d& transformation) {
    // Extract the 3x3 rotation matrix from the 4x4 transformation matrix
    Eigen::Matrix3d rotation_matrix = transformation.block<3, 3>(0, 0);

    // Calculate the rotation angle in the XY plane
    double angle_xy = atan2(rotation_matrix(1, 0), rotation_matrix(0, 0));

    // Convert the angle from radians to degrees if needed
    double angle_xy_degrees = angle_xy * (180.0f / M_PI);

    return angle_xy_degrees;
}




std::tuple<Eigen::Vector2d, double> FullRegistration3(
    const std::shared_ptr<open3d::geometry::PointCloud> &source,
    const std::shared_ptr<open3d::geometry::PointCloud> &target,
    double voxel_size,
    double max_correspondence_distance_coarse,
    double max_correspondence_distance_fine) {

    using namespace open3d;
    using namespace pipelines::registration;

    // 1️⃣ Downsample first (fast)
    auto source_down = source->VoxelDownSample(voxel_size);
    auto target_down = target->VoxelDownSample(voxel_size);

    // 2️⃣ Estimate normals on downsampled clouds (required for FPFH + ICP)
    source_down->EstimateNormals(
        geometry::KDTreeSearchParamHybrid(voxel_size * 2, 20));
    target_down->EstimateNormals(
        geometry::KDTreeSearchParamHybrid(voxel_size * 2, 20));

    // 3️⃣ Compute FPFH features (only once)
    auto source_fpfh = ComputeFPFHFeature(
        *source_down, geometry::KDTreeSearchParamHybrid(voxel_size * 5, 100));
    auto target_fpfh = ComputeFPFHFeature(
        *target_down, geometry::KDTreeSearchParamHybrid(voxel_size * 5, 100));

    // 4️⃣ RANSAC (coarse)
    std::vector<std::reference_wrapper<const CorrespondenceChecker>> checkers;
    auto checker_edge = CorrespondenceCheckerBasedOnEdgeLength(0.9);
    auto checker_dist = CorrespondenceCheckerBasedOnDistance(max_correspondence_distance_coarse);
    checkers.push_back(checker_edge);
    checkers.push_back(checker_dist);

    auto result_ransac = RegistrationRANSACBasedOnFeatureMatching(
        *source_down, *target_down, *source_fpfh, *target_fpfh,
        false, max_correspondence_distance_coarse,
        TransformationEstimationPointToPoint(false), 3, checkers,
        RANSACConvergenceCriteria(50000, 0.999));

    // 5️⃣ Fine ICP (point-to-plane)
    auto icp_result = RegistrationICP(
        *source_down, *target_down, max_correspondence_distance_fine,
        result_ransac.transformation_,
        TransformationEstimationPointToPlane());

    // 6️⃣ Return transformation
    auto info = GetInformationMatrixFromPointClouds(
        *source_down, *target_down,
        max_correspondence_distance_fine, icp_result.transformation_);

    Eigen::Vector3d translation_vector = icp_result.transformation_.block<3, 1>(0, 3);
    Eigen::Vector2d center_2d(translation_vector(0), translation_vector(1));

    double angle = getRotationAngleXY2(icp_result.transformation_);
    return std::make_tuple(center_2d, angle);
}


std::pair<Eigen::Matrix4d, Eigen::Matrix6d> FullRegistration2(
    const std::shared_ptr<open3d::geometry::PointCloud> &source,
    const std::shared_ptr<open3d::geometry::PointCloud> &target,
    double voxel_size,
    double max_correspondence_distance_coarse,
    double max_correspondence_distance_fine) {

    using namespace open3d;
    using namespace pipelines::registration;

    // 1️⃣ Downsample first (fast)
    auto source_down = source->VoxelDownSample(voxel_size);
    auto target_down = target->VoxelDownSample(voxel_size);

    // 2️⃣ Estimate normals on downsampled clouds (required for FPFH + ICP)
    source_down->EstimateNormals(
        geometry::KDTreeSearchParamHybrid(voxel_size * 2, 20));
    target_down->EstimateNormals(
        geometry::KDTreeSearchParamHybrid(voxel_size * 2, 20));

    // 3️⃣ Compute FPFH features (only once)
    auto source_fpfh = ComputeFPFHFeature(
        *source_down, geometry::KDTreeSearchParamHybrid(voxel_size * 5, 100));
    auto target_fpfh = ComputeFPFHFeature(
        *target_down, geometry::KDTreeSearchParamHybrid(voxel_size * 5, 100));

    // 4️⃣ RANSAC (coarse)
    std::vector<std::reference_wrapper<const CorrespondenceChecker>> checkers;
    auto checker_edge = CorrespondenceCheckerBasedOnEdgeLength(0.9);
    auto checker_dist = CorrespondenceCheckerBasedOnDistance(max_correspondence_distance_coarse);
    checkers.push_back(checker_edge);
    checkers.push_back(checker_dist);

    auto result_ransac = RegistrationRANSACBasedOnFeatureMatching(
        *source_down, *target_down, *source_fpfh, *target_fpfh,
        false, max_correspondence_distance_coarse,
        TransformationEstimationPointToPoint(false), 3, checkers,
        RANSACConvergenceCriteria(50000, 0.999));

    // 5️⃣ Fine ICP (point-to-plane)
    auto icp_result = RegistrationICP(
        *source_down, *target_down, max_correspondence_distance_fine,
        result_ransac.transformation_,
        TransformationEstimationPointToPlane());

    // 6️⃣ Return transformation
    auto info = GetInformationMatrixFromPointClouds(
        *source_down, *target_down,
        max_correspondence_distance_fine, icp_result.transformation_);

    return {icp_result.transformation_, info};
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


void Reconstruct::setLabelAdjustOffset(double dx, double dy) {
  adjustOffset = Eigen::Vector2d(dx, dy);
}


Eigen::Vector2d Reconstruct::getLabelExtent() {
  return labelExtent;
}


void Reconstruct::setLabelExtent(double w, double h) {
  std::cout << "setLabelExtent ++++++++++++++ " << w << "," << h << std::endl;
  labelExtent = Eigen::Vector2d(w, h);
}


void Reconstruct::setLabelDenoise(double neighbors, double ratio) {
  labelDenoise = Eigen::Vector2d(neighbors, ratio);
}


void Reconstruct::setProductDenoise(double neighbors, double ratio) {
  productDenoise = Eigen::Vector2d(neighbors, ratio);
}


void Reconstruct::setLabelMorphology(double value) {
  labelMorphology = value;
}


void Reconstruct::setProductMorphology(double value) {
  productMorphology = value;
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


void Reconstruct::setNozzleResolution(double value) {
  nozzleResolution = value;
}


void Reconstruct::setNozzleThreshold(double value) {
  nozzleThreshold = value;
}


void Reconstruct::setMotionHandle(ModbusZ& modbus) {
  busPtr = cv::makePtr<ModbusZ>(modbus);
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
//     auto [product_center, product_angle] = ProductCenterAndOrientation(productPC, 0.05, 0.09, 50.0, productDenoise);
//     std::cout << "product angle: " << product_angle << " degrees" << std::endl;
//     std::cout << "x: " << product_center[0] << std::endl;
//     std::cout << "y: " << product_center[1] << std::endl;
    
//     auto [label_center, label_angle, w, h] = LabelCenterAndOrientation(labelPC, 0.05, 8.0, Eigen::Vector2d{0.0, 0.0}, labelDenoise);
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
    auto [product_center, product_angle] = ProductCenterAndOrientation(productPC, 0.05, 0.09, 50.0, productDenoise);
    std::cout << "product angle: " << product_angle << " degrees" << std::endl;
    std::cout << "x: " << product_center[0] << std::endl;
    std::cout << "y: " << product_center[1] << std::endl;
    
    auto [label_center, label_angle, w, h] = LabelCenterAndOrientation(labelPC, 0.05, 8.0, Eigen::Vector2d{0.0, 0.0}, labelDenoise);
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


cv::Point2d transPoint(std::vector<cv::Point2d>& pixels, std::vector<cv::Point2d>& worlds, cv::Point2d source) {
  std::vector<double> output;
  cv::Mat affineMatrix = cv::estimateAffine2D(pixels, worlds);

  std::vector<cv::Point2d> myPoint(1);
  myPoint[0] = source;
  std::vector<cv::Point2d> transformedPoint(1);
  cv::transform(myPoint, transformedPoint, affineMatrix);

  return transformedPoint[0];
}


int Reconstruct::setManuParams(int thresh, Eigen::Matrix4f& label, Eigen::Matrix4f& product, std::vector<cv::Point2d>& pixels, std::vector<cv::Point2d>& worlds) {
  labelBox = label;
  productBox = product;
  this->pixels = pixels;
  this->worlds = worlds;
  profiloThreshold = thresh;
  return 0;
}


int Reconstruct::processAlignment() {
  using namespace open3d;
  using namespace std;

  // Define the local bounds for the bounding box (unit cube)
  std::array<float,6> local_bounds = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5};

  // Create Oriented Bounding Box (OBB)
  auto obb = CreateOrientedBoundingBox(labelBox, local_bounds);
  auto obb2 = CreateOrientedBoundingBox(productBox, local_bounds);

  // Clip the point cloud with the defined OBB
  labelPC = *pointCloud.Crop(*obb);
  productPC = *pointCloud.Crop(*obb2);

  if(labelPC.points_.size() == 0 || productPC.points_.size() == 0
     || labelTempPC.points_.size() == 0 || productTempPC.points_.size() == 0) return 0;

  try {

    auto start = std::chrono::high_resolution_clock::now();

    // Launch both tasks concurrently.
    auto productFuture = std::async(std::launch::async, ProductCenterAndOrientation, productPC, productResolution, distanceThreshold, productMorphology, productDenoise);
    auto labelFuture = std::async(std::launch::async, LabelCenterAndOrientation3d, labelPC, labelResolution, labelMorphology, adjustOffset, labelDenoise);

    // Wait for the results
    auto [product_center, product_angle] = productFuture.get();
    std::cout << "product angle: " << product_angle << " degrees" << std::endl;
    std::cout << "x: " << product_center[0] << std::endl;
    std::cout << "y: " << product_center[1] << std::endl;
    
    // auto [label_center, label_angle, w, h] = labelFuture.get();
    auto [label_center, label_angle, extent] = labelFuture.get();
    std::cout << "label angle: " << label_angle << " degrees" << std::endl;
    std::cout << "x: " << label_center[0] << std::endl;
    std::cout << "y: " << label_center[1] << std::endl;

    Eigen::Vector2d label_center2(label_center[0], label_center[1]);

    auto trans1 = estimateTransform2(label_center2, label_angle, product_center, product_angle);
    std::cout << "trans1 Matrix: " << std::endl;
    std::cout << trans1 << std::endl;

    labelPC.Transform(trans1);
    
    double angle = product_angle - label_angle;
    std::cout << "Rotation angle in XY plane: " << angle << " degrees" << std::endl;

    cv::Point2d originalPoint(label_center(0), label_center(1));
    cv::Point2d nozzle_center = pixels[0];
    cv::Mat rotationMatrix = cv::getRotationMatrix2D(nozzle_center, -angle, 1.0);

    std::vector<cv::Point2d> transformedPoints;
    std::vector<cv::Point2d> inputPoints;
    inputPoints.push_back(originalPoint);
    cv::transform(inputPoints, transformedPoints, rotationMatrix);

    cv::Point2d product_center2(product_center(0), product_center(1));

    cv::Point2d label_center_world = transPoint(pixels, worlds, transformedPoints[0]);
    cv::Point2d nozzle_worlds = worlds[0];

    cv::Point2d nozzleOffset = label_center_world - nozzle_worlds;
    cv::Point2d product_world_center = transPoint(pixels, worlds, product_center2);

    cv::Point2d adjusted_translation = product_world_center - nozzleOffset;

    setMotionRevise(angle, adjusted_translation.x, adjusted_translation.y);

    float a[3] = {(float)adjusted_translation.x, (float)adjusted_translation.y, (float)angle};
    busPtr->setFloat(530, 1, a);
    busPtr->setFloat(520, 1, a+1);
    busPtr->setFloat(500, 1, a+2);

    uint8 b[1] = {255};

    // busPtr->setBit(74, 1, b);
    // busPtr->setBit(70, 1, b);
    busPtr->setBit(105, 1, b);

    transiLabel.clear();
    transiProduct.clear();
    
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

    auto end = std::chrono::high_resolution_clock::now();

    auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

    std::cout << "processAlignment Time spent: " << duration << " microseconds" << std::endl;

    io::WritePointCloudToPLY("/home/hotcat/Downloads/new3dvision/controller/1/decoder/my.ply", pointCloud, true);

  } catch (const std::exception& e) {
      std::cerr << "Error: " << e.what() << std::endl;
      setMotionRevise(999.9, 0, 0);
      return 0;
  }

  return 1;
}

int Reconstruct::directlyAlign(Eigen::Matrix4f& label, Eigen::Matrix4f& product, std::vector<cv::Point2d>& pixels, std::vector<cv::Point2d>& worlds) {
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

  // // Save the aligned point clouds
  // io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/labelPC.ply", labelPC, true);
  // io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productPC.ply", productPC, true);

  try {

    auto start = std::chrono::high_resolution_clock::now();

    // Launch both tasks concurrently.
    auto productFuture = std::async(std::launch::async, ProductCenterAndOrientation, productPC, productResolution, distanceThreshold, productMorphology, productDenoise);
    auto labelFuture = std::async(std::launch::async, LabelCenterAndOrientation, labelPC, labelResolution, labelMorphology, adjustOffset, labelDenoise);

    // Wait for the results
    auto [product_center, product_angle] = productFuture.get();
    std::cout << "product angle: " << product_angle << " degrees" << std::endl;
    std::cout << "x: " << product_center[0] << std::endl;
    std::cout << "y: " << product_center[1] << std::endl;
    
    auto [label_center, label_angle, w, h] = labelFuture.get();
    std::cout << "label angle: " << label_angle << " degrees" << std::endl;
    std::cout << "x: " << label_center[0] << std::endl;
    std::cout << "y: " << label_center[1] << std::endl;
    
    auto trans1 = estimateTransform2(label_center, label_angle, product_center, product_angle);
    std::cout << "trans1 Matrix: " << std::endl;
    std::cout << trans1 << std::endl;

    auto end = std::chrono::high_resolution_clock::now();

    auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

    std::cout << "directlyAlign Time spent: " << duration << " microseconds" << std::endl;

    labelPC.Transform(trans1);
    
    double angle = product_angle - label_angle;
    std::cout << "Rotation angle in XY plane: " << angle << " degrees" << std::endl;

    cv::Point2d originalPoint(label_center(0), label_center(1));
    cv::Point2d nozzle_center = pixels[0];
    cv::Mat rotationMatrix = cv::getRotationMatrix2D(nozzle_center, -angle, 1.0);

    std::vector<cv::Point2d> transformedPoints;
    std::vector<cv::Point2d> inputPoints;
    inputPoints.push_back(originalPoint);
    cv::transform(inputPoints, transformedPoints, rotationMatrix);

    cv::Point2d product_center2(product_center(0), product_center(1));

    cv::Point2d label_center_world = transPoint(pixels, worlds, transformedPoints[0]);
    cv::Point2d nozzle_worlds = worlds[0];

    cv::Point2d nozzleOffset = label_center_world - nozzle_worlds;
    cv::Point2d product_world_center = transPoint(pixels, worlds, product_center2);

    cv::Point2d adjusted_translation = product_world_center - nozzleOffset;

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
      setMotionRevise(999.9, 0, 0);
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


// ----------------------------------------------------------------------
// Deterministic, occlusion-resilient product alignment
// ----------------------------------------------------------------------
std::tuple<Eigen::Vector3d, double, Eigen::Vector3d, Eigen::Matrix4d>
ProductCenterAndOrientation3d(const open3d::geometry::PointCloud &production,
                                  const open3d::geometry::PointCloud &templatePC,
                                  double yaw_offset_deg = 0.0,
                                  double resolution = 0.1) {
    using namespace open3d;
    using namespace std;

    // ---- params that match your pipeline ----
    double morphology = 0.0;
    Eigen::Vector2d labelDenoise(20, 1.0);
    Eigen::Vector2d adjustOffset(0.0, 0.0);

    // ---- 1) Compute coarse centers & angles (do not alter the inputs) ----

    auto [templ_center, templ_angle, templ_extent] =
        LabelCenterAndOrientation3d(templatePC, resolution, morphology,
                                    adjustOffset, labelDenoise);


    auto [prod_center, prod_angle, prod_extent] =
        LabelCenterAndOrientation3d(production, resolution, morphology,
                                    adjustOffset, labelDenoise);
    

    cout << "[DEBUG] coarse prod_center: " << prod_center.transpose()
         << " prod_angle: " << prod_angle << " deg\n";
    cout << "[DEBUG] coarse templ_center: " << templ_center.transpose()
         << " templ_angle: " << templ_angle << " deg\n";

    // ---- 2) Build initial transform: template -> production (this is crucial) ----
    double templ_angle_with_offset = templ_angle + yaw_offset_deg;
    Eigen::Matrix4d T_init = estimateTransform2(
        Eigen::Vector2d(templ_center(0), templ_center(1)), templ_angle_with_offset,
        Eigen::Vector2d(prod_center(0), prod_center(1)), prod_angle);

    // Debug: does T_init map the template center -> production center?
    {
        Eigen::Vector4d templ_ctr_h(templ_center(0), templ_center(1), 0.0, 1.0);
        Eigen::Vector4d mapped = T_init * templ_ctr_h;
        cout << "[DEBUG] After T_init, mapped template center: "
             << mapped.head<3>().transpose()
             << " expected prod center: " << prod_center.transpose() << "\n";
    }

    // ---- 3) Create aligned template (copy) and apply T_init (template->production) ----
    auto templ_aligned = std::make_shared<geometry::PointCloud>(templatePC);
    templ_aligned->Transform(T_init);

    // Optional quick sanity: distance between templ_aligned center and prod_center
    {
        Eigen::Vector3d center_t_aligned = templ_aligned->GetCenter();
        double center_dist = (center_t_aligned - prod_center).norm();
        cout << "[DEBUG] center distance after T_init: " << center_dist << " units\n";
    }

    // ---- 4) Run PairwiseRegistration (templ_aligned -> production) ----
    double max_corr_coarse = resolution * 25.0;
    double max_corr_fine   = resolution * 1.0;
    bool robust = true;
    auto prod_ptr = std::make_shared<geometry::PointCloud>(production);

    auto [T_icp, info_icp] = PairwiseRegistration(templ_aligned, prod_ptr,
                                                  max_corr_coarse, max_corr_fine, robust);

    cout << "[DEBUG] ICP returned transform (T_icp):\n" << T_icp << "\n";

    // ---- 5) Compose final transform T_final = T_icp * T_init
    Eigen::Matrix4d T_final = T_icp * T_init;

    // Debug: map template center with T_final and evaluate registration
    {
        Eigen::Vector4d templ_ctr_h(templ_center(0), templ_center(1), 0.0, 1.0);
        Eigen::Vector4d mapped_final = T_final * templ_ctr_h;
        cout << "[DEBUG] After T_final, mapped template center: "
             << mapped_final.head<3>().transpose()
             << " expected prod center: " << prod_center.transpose() << "\n";

        // Evaluate registration fitness using T_final (on downsampled or same clouds)
        auto eval = pipelines::registration::EvaluateRegistration(
            *templ_aligned, *prod_ptr, max_corr_fine, T_icp);
        cout << "[DEBUG] ICP evaluate (on downsampled clouds): fitness=" << eval.fitness_
             << " inlier_rmse=" << eval.inlier_rmse_ << "\n";

        // Also evaluate T_final directly (template original -> production)
        auto eval2 = pipelines::registration::EvaluateRegistration(
            templatePC, production, max_corr_fine, T_final);
        cout << "[DEBUG] Evaluate on ORIGINAL clouds with T_final: fitness=" << eval2.fitness_
             << " inlier_rmse=" << eval2.inlier_rmse_ << "\n";
    }

    // ---- 6) Extract refined center and yaw from T_final ----
    Eigen::Vector3d refined_center = T_final.block<3,1>(0,3);
    Eigen::Matrix3d R = T_final.block<3,3>(0,0);
    double refined_angle_deg = std::atan2(R(1,0), R(0,0)) * 180.0 / M_PI;
    // Normalize
    if (refined_angle_deg < -45.0) refined_angle_deg += 90.0;
    else if (refined_angle_deg > 45.0) refined_angle_deg -= 90.0;

    // ---- 7) Compute refined bounding box extent of merged aligned clouds ----
    auto templ_final = std::make_shared<geometry::PointCloud>(templatePC);
    templ_final->Transform(T_final);
    geometry::PointCloud merged = *prod_ptr + *templ_final;
    auto bbox = merged.GetAxisAlignedBoundingBox();
    Eigen::Vector3d refined_extent = bbox.GetExtent();

    // ---- Final debug summary ----
    cout << "[ProductCenterAndOrientation_Debug] refined_center: "
         << refined_center.transpose() << "\n";
    cout << "  refined_yaw: " << refined_angle_deg << " deg\n";
    cout << "  refined_extent: " << refined_extent.transpose() << "\n";

    return {refined_center, refined_angle_deg, refined_extent, T_final};
}


std::tuple<Eigen::Vector2d, double>
ProductCenterAndOrientation3d2(const open3d::geometry::PointCloud &production,
                                  const open3d::geometry::PointCloud &templatePC,
                                  double yaw_offset_deg = 0.0,
                                  double resolution = 0.1) {
  auto [center, angle, extent, T_final] = ProductCenterAndOrientation3d(production, templatePC, yaw_offset_deg, resolution);
  Eigen::Vector2d center2(center[0], center[1]);
  return std::make_tuple(center2, angle);
}



int Reconstruct::labelAlign() {
    using namespace open3d;
    using namespace std;

    std::cout << "labelResolution: " << labelResolution << std::endl;
    std::cout << "productResolution: " << productResolution << std::endl;
    std::cout << "distanceThreshold: " << distanceThreshold << std::endl;

    try {

      auto start = std::chrono::high_resolution_clock::now();

      auto pcds_down = LoadPointClouds(productPC, productTempPC, 0.4, false);

      // Launch both tasks concurrently.
      auto productFuture = (configIndex == 0)?std::async(std::launch::async, ProductCenterAndOrientation, productPC, productResolution, distanceThreshold, productMorphology, productDenoise):std::async(std::launch::async, ProductCenterAndOrientation3d2, *(pcds_down[0]), *(pcds_down[1]), +5.0, 0.4);
      // auto productFuture = std::async(std::launch::async, ProductCenterAndOrientation, productPC, productResolution, distanceThreshold, productMorphology, productDenoise);

      auto labelFuture = (configIndex == 0)?std::async(std::launch::async, LabelCenterAndOrientation3d, labelPC, labelResolution, labelMorphology, Eigen::Vector2d{0.0, 0.0}, labelDenoise):std::async(std::launch::async, LabelCenterAndOrientation3dPartial, labelPC, labelResolution, labelMorphology, Eigen::Vector2d{0.0, 0.0}, labelDenoise, labelExtent);

      // Wait for the results
      auto [product_center, product_angle] = productFuture.get();
      // auto [product_center, product_angle] = ProductCenterAndOrientation(productPC, productResolution, distanceThreshold, productMorphology, productDenoise);

      std::cout << "product angle: " << product_angle << " degrees" << std::endl;
      std::cout << "x: " << product_center[0] << std::endl;
      std::cout << "y: " << product_center[1] << std::endl;

      // auto [label_center, label_angle, w, h] = labelFuture.get();
      auto [label_center, label_angle, extent2] = labelFuture.get();
      // auto [label_center, label_angle, w, h] = LabelCenterAndOrientation(labelPC, labelResolution, labelMorphology, Eigen::Vector2d{0.0, 0.0}, labelDenoise);

      std::cout << "label angle: " << label_angle << " degrees" << std::endl;
      std::cout << "x: " << label_center[0] << std::endl;
      std::cout << "y: " << label_center[1] << std::endl;

      Eigen::Vector2d label_center2(label_center[0], label_center[1]);

      // AlignPointCloud(labelPC, label_center, label_angle, product_center, product_angle);
      auto trans1 = estimateTransform2(label_center2, label_angle, product_center, product_angle);

      auto end = std::chrono::high_resolution_clock::now();

      auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

      std::cout << "Time spent: " << duration << " microseconds" << std::endl;

      labelPC.Transform(trans1);

      // double rad = product_angle * M_PI /180.0;

      // // Construct the 2x2 rotation matrix
      // Eigen::Matrix2d R;
      // R << std::cos(rad), -std::sin(rad),
      // 	std::sin(rad),  std::cos(rad);

      // Eigen::Vector2d translation2 = R * adjustOffset;
      // Eigen::Vector3d translation3(translation2(0), translation2(1), 0);
      // labelPC.Translate(translation3, true);
      
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


      setMotionRevise(product_angle, 0.0, 0.0);


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
      //   point += adjusted_translation2;
      // }

      // Save the aligned point clouds
      io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/labelPC.ply", labelPC, true);
      io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productPC.ply", productPC, true);

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
      io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/labelPC.ply", labelPC, true);
      io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productPC.ply", productPC, true);
    }

    return 0;
}



// int Reconstruct::labelAlign_original_2d() {
//     using namespace open3d;
//     using namespace std;

//     std::cout << "labelResolution: " << labelResolution << std::endl;
//     std::cout << "productResolution: " << productResolution << std::endl;
//     std::cout << "distanceThreshold: " << distanceThreshold << std::endl;

//     try {

//       auto start = std::chrono::high_resolution_clock::now();

//       // Launch both tasks concurrently.
//       auto productFuture = std::async(std::launch::async, ProductCenterAndOrientation, productPC, productResolution, distanceThreshold, productMorphology, productDenoise);
//       auto labelFuture = std::async(std::launch::async, LabelCenterAndOrientation, labelPC, labelResolution, labelMorphology, Eigen::Vector2d{0.0, 0.0}, labelDenoise);

//       // Wait for the results
//       auto [product_center, product_angle] = productFuture.get();

//       std::cout << "product angle: " << product_angle << " degrees" << std::endl;
//       std::cout << "x: " << product_center[0] << std::endl;
//       std::cout << "y: " << product_center[1] << std::endl;

//       auto [label_center, label_angle, w, h] = labelFuture.get();

//       std::cout << "label angle: " << label_angle << " degrees" << std::endl;
//       std::cout << "x: " << label_center[0] << std::endl;
//       std::cout << "y: " << label_center[1] << std::endl;


//       // AlignPointCloud(labelPC, label_center, label_angle, product_center, product_angle);
//       auto trans1 = estimateTransform2(label_center, label_angle, product_center, product_angle);

//       auto end = std::chrono::high_resolution_clock::now();

//       auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();

//       std::cout << "Time spent: " << duration << " microseconds" << std::endl;

//       labelPC.Transform(trans1);
      
//       double angle = product_angle - label_angle;
//       cv::Point2d originalPoint(label_center(0), label_center(1));
//       cv::Point2d center(7.71, -18.73);
//       cv::Mat rotationMatrix = cv::getRotationMatrix2D(center, -angle, 1.0);
      
//       std::vector<cv::Point2d> transformedPoints;
//       std::vector<cv::Point2d> inputPoints;
//       inputPoints.push_back(originalPoint);
//       cv::transform(inputPoints, transformedPoints, rotationMatrix);

//       cv::Point2d product_center2(product_center(0), product_center(1));
//       cv::Point2d rotated_label_center(transformedPoints[0].x, transformedPoints[0].y);
//       cv::Point2d adjusted_translation = product_center2 - rotated_label_center;
//       Eigen::Vector3d adjusted_translation2 = {adjusted_translation.x, adjusted_translation.y, 0};

//       Eigen::Matrix3d rotation_matrix = trans1.block<3, 3>(0, 0);
//       Eigen::Vector3d translation_vector = trans1.block<3, 1>(0, 3);


//       setMotionRevise(label_angle, 0.0, 0.0);


//       saveTransformationToFile(trans1, "/home/hotcat/Downloads/new3dvision/controller/1/transform.txt");


//       Eigen::Matrix4d mytrans1, mytrans2, mytrans3, mytrans4, mytrans5;
//       mytrans1 = loadTransformationFromFile("/home/hotcat/Downloads/new3dvision/controller/1/transform1.txt");
//       mytrans2 = loadTransformationFromFile("/home/hotcat/Downloads/new3dvision/controller/1/transform2.txt");
//       mytrans3 = loadTransformationFromFile("/home/hotcat/Downloads/new3dvision/controller/1/transform3.txt");
//       mytrans4 = loadTransformationFromFile("/home/hotcat/Downloads/new3dvision/controller/1/transform4.txt");
//       mytrans5 = loadTransformationFromFile("/home/hotcat/Downloads/new3dvision/controller/1/transform5.txt");

//       // Eigen::Vector3d rotation_point = computeRotationPoint(rotation_matrix, translation_vector);
//       Eigen::Vector3d rotation_point = refineRotationCenterWithNonlinearOptimization({mytrans1.block<3,3>(0,0),mytrans2.block<3,3>(0,0), mytrans3.block<3,3>(0,0), mytrans4.block<3,3>(0,0), mytrans5.block<3,3>(0,0)}, {mytrans1.block<3,1>(0,3), mytrans2.block<3,1>(0,3), mytrans3.block<3,1>(0,3), mytrans4.block<3,1>(0,3), mytrans5.block<3,1>(0,3)});
//       std::cout << "== rotation_point == : " << rotation_point << std::endl;


//       Eigen::Vector3d rotation_center = {7.71, -18.73, 0};

//       // // Translate the point cloud to the origin (subtract the rotation center)
//       // for (auto &point : labelPC.points_) {
//       //   point -= rotation_center;
//       // }
      
//       // // Apply the rotation
//       // for (auto &point : labelPC.points_) {
//       //   Eigen::Vector3d rotated_point = rotation_matrix * Eigen::Vector3d(point.x(), point.y(), point.z());
//       //   point = rotated_point;
//       // }
      
//       // // Translate the point cloud back to the original position (add the rotation center)
//       // for (auto &point : labelPC.points_) {
//       //   point += rotation_center;
//       // }
      
//       // for (auto &point : labelPC.points_) {
//       //   point += adjusted_translation2;
//       // }

//       // Save the aligned point clouds
//       io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/labelPC.ply", labelPC, true);
//       io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productPC.ply", productPC, true);

//       transiLabel.clear();
//       transiLabelTemp.clear();

//       for (size_t i = 0; i < labelPC.points_.size(); ++i) {
// 	const auto& point = labelPC.points_[i];
// 	const auto& color = labelPC.colors_[i];

// 	transiLabel.push_back(static_cast<float>(point(0)));
// 	transiLabel.push_back(static_cast<float>(point(1)));
// 	transiLabel.push_back(static_cast<float>(point(2)));

// 	transiLabel.push_back(static_cast<float>(color(0)));
// 	transiLabel.push_back(static_cast<float>(color(1)));
// 	transiLabel.push_back(static_cast<float>(color(2)));
// 	transiLabel.push_back(static_cast<float>(1.0));
//       }


//       for (size_t i = 0; i < labelTempPC.points_.size(); ++i) {
// 	const auto& point = labelTempPC.points_[i];
// 	const auto& color = labelTempPC.colors_[i];

// 	transiLabelTemp.push_back(static_cast<float>(point(0)));
// 	transiLabelTemp.push_back(static_cast<float>(point(1)));
// 	transiLabelTemp.push_back(static_cast<float>(point(2)));

// 	transiLabelTemp.push_back(static_cast<float>(color(0)));
// 	transiLabelTemp.push_back(static_cast<float>(color(1)));
// 	transiLabelTemp.push_back(static_cast<float>(color(2)));
// 	transiLabelTemp.push_back(static_cast<float>(1.0));
//       }

//     } catch (const std::exception& e) {
//       std::cerr << "Error: " << e.what() << std::endl;
//       io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/labelPC.ply", labelPC, true);
//       io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productPC.ply", productPC, true);
//     }

//     return 0;
// }






int Reconstruct::productAlign() {
    using namespace open3d;
    using namespace std;

    // double voxel_size = 0.08;
    double voxel_size = 0.4;
    double max_correspondence_distance_coarse = voxel_size * 25;
    double max_correspondence_distance_fine = voxel_size * 1.0;




    // auto start = std::chrono::high_resolution_clock::now();

    // auto pcds_down = LoadPointClouds(productTempPC, productPC, voxel_size, false);
    // // auto [transformation_icp, information_icp] = FullRegistration2(std::make_shared<open3d::geometry::PointCloud>(productTempPC), std::make_shared<open3d::geometry::PointCloud>(productPC), voxel_size, max_correspondence_distance_coarse, max_correspondence_distance_fine);
    // auto [transformation_icp, information_icp] = PairwiseRegistration(pcds_down[0], pcds_down[1], max_correspondence_distance_coarse, max_correspondence_distance_fine);

    // auto end = std::chrono::high_resolution_clock::now();
    // auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
    // std::cout << "FullRegistration2 Time spent: " << duration << " microseconds" << std::endl;


    // std::cout << "Transformation ICP Matrix: " << std::endl;
    // std::cout << transformation_icp << std::endl;

    // double angle = getRotationAngleXY(transformation_icp);
    // std::cout << "Rotation angle in XY plane: " << angle << " degrees" << std::endl;

    // // Apply the transformation to the source point cloud
    // // pcds_down[0]->Transform(transformation_icp);

    // // productTempPC = *pcds_down[0];

    // auto [product_center, product_angle]= FullRegistration3(std::make_shared<open3d::geometry::PointCloud>(productTempPC), std::make_shared<open3d::geometry::PointCloud>(productPC), voxel_size, max_correspondence_distance_coarse, max_correspondence_distance_fine);
    // std::cout << "product angle: " << product_angle << " degrees" << std::endl;
    // std::cout << "x: " << product_center[0] << std::endl;
    // std::cout << "y: " << product_center[1] << std::endl;

    // productTempPC.Transform(transformation_icp);


    auto pcds_down = LoadPointClouds(productPC, productTempPC, voxel_size, false);

    auto [product_center, product_angle, product_extent, Tfinal]= ProductCenterAndOrientation3d(*(pcds_down[0]), *(pcds_down[1]), +5.0, 0.05);
    std::cout << "product angle: " << product_angle << " degrees" << std::endl;
    std::cout << "x: " << product_center[0] << std::endl;
    std::cout << "y: " << product_center[1] << std::endl;

    // auto trans1 = estimateTransform2(Eigen::Vector2d{product_center(0), product_center(1)}, product_angle, Eigen::Vector2d{0.0, 0.0}, 0.0);
    productTempPC.Transform(Tfinal);




    // {
    //   auto [transformation_icp, information_icp] = FullRegistration2(std::make_shared<open3d::geometry::PointCloud>(productTempPC), std::make_shared<open3d::geometry::PointCloud>(productPC), voxel_size, max_correspondence_distance_coarse, max_correspondence_distance_fine);
    //   std::cout << "product angle: " << product_angle << " degrees" << std::endl;
    //   std::cout << "x: " << product_center[0] << std::endl;
    //   std::cout << "y: " << product_center[1] << std::endl;

    //   productTempPC.Transform(transformation_icp);
    // }





    // Save the aligned point clouds
    // io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productTempPC.ply", *pcds_down[0], true);
    // io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productPC.ply", *pcds_down[1], true);

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



// int Reconstruct::productAlign() {
//     using namespace open3d;
//     using namespace std;

//     // double voxel_size = 0.08;
//     double voxel_size = 0.2;
//     double max_correspondence_distance_coarse = voxel_size * 25;
//     double max_correspondence_distance_fine = voxel_size * 1.0;

//     auto start = std::chrono::high_resolution_clock::now();

//     auto pcds_down = LoadPointClouds(productTempPC, productPC, voxel_size, false);

//     // Perform pairwise registration
//     // auto [transformation_icp, information_icp] = PairwiseRegistration(pcds_down[0], pcds_down[1], max_correspondence_distance_coarse, max_correspondence_distance_fine);
//     auto [transformation_icp, information_icp] = FullRegistration(pcds_down[0], pcds_down[1], voxel_size, max_correspondence_distance_coarse, max_correspondence_distance_fine);

//     auto end = std::chrono::high_resolution_clock::now();
//     auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start).count();
//     std::cout << "FullRegistration Time spent: " << duration << " microseconds" << std::endl;


//     std::cout << "Transformation ICP Matrix: " << std::endl;
//     std::cout << transformation_icp << std::endl;

//     double angle = getRotationAngleXY(transformation_icp);
//     std::cout << "Rotation angle in XY plane: " << angle << " degrees" << std::endl;

//     // Apply the transformation to the source point cloud
//     // pcds_down[0]->Transform(transformation_icp);

//     // productTempPC = *pcds_down[0];


//     productTempPC.Transform(transformation_icp);

//     // Save the aligned point clouds
//     io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productTempPC.ply", *pcds_down[0], true);
//     io::WritePointCloud("/home/hotcat/Downloads/new3dvision/controller/1/productPC.ply", *pcds_down[1], true);

//     transiProduct.clear();
//     transiProductTemp.clear();

//     for (size_t i = 0; i < productPC.points_.size(); ++i) {
//       const auto& point = productPC.points_[i];
//       const auto& color = productPC.colors_[i];

//       transiProduct.push_back(static_cast<float>(point(0)));
//       transiProduct.push_back(static_cast<float>(point(1)));
//       transiProduct.push_back(static_cast<float>(point(2)));

//       transiProduct.push_back(static_cast<float>(color(0)));
//       transiProduct.push_back(static_cast<float>(color(1)));
//       transiProduct.push_back(static_cast<float>(color(2)));
//       transiProduct.push_back(static_cast<float>(1.0));
//     }


//     for (size_t i = 0; i < productTempPC.points_.size(); ++i) {
//       const auto& point = productTempPC.points_[i];
//       const auto& color = productTempPC.colors_[i];

//       transiProductTemp.push_back(static_cast<float>(point(0)));
//       transiProductTemp.push_back(static_cast<float>(point(1)));
//       transiProductTemp.push_back(static_cast<float>(point(2)));

//       transiProductTemp.push_back(static_cast<float>(color(0)));
//       transiProductTemp.push_back(static_cast<float>(color(1)));
//       transiProductTemp.push_back(static_cast<float>(color(2)));
//       transiProductTemp.push_back(static_cast<float>(1.0));
//     }


//     std::string ply_file = "/home/hotcat/Downloads/new3dvision/controller/1/decoder/research2.ply";
//     std::string depth_map_file = "/dev/shm/depth_map.ics";
//     std::string flattened_image_file = "/dev/shm/flattened_image.png";
//     ConvertPointCloudTo2D(ply_file, depth_map_file, flattened_image_file, 0.05);

//     return 0;
// }


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


void Reconstruct::setConfigIndex(int index) {
  configIndex = index;
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





int cgal(){
  using Kernel = CGAL::Simple_cartesian<double>;
  using Point2 = Kernel::Point_2;

  // 1. Load point cloud (aligned XY)
  open3d::geometry::PointCloud pcd;
  open3d::io::ReadPointCloud("partial.ply", pcd);

  // 2. Build 2D points & Z extents
  std::vector<Point2> pts2d;
  double zmin = 1e9, zmax = -1e9;
  for(auto& p : pcd.points_){
    pts2d.emplace_back(p(0), p(1));
    zmin = std::min(zmin, p(2));
    zmax = std::max(zmax, p(2));
  }

  // 3. Convex hull
  std::vector<Point2> hull;
  CGAL::convex_hull_2(pts2d.begin(), pts2d.end(),
                      std::back_inserter(hull));

  // 4. Rotating calipers ¡ú OBB rectangle
  std::vector<Point2> rect2d;
  CGAL::min_rectangle_2(hull.begin(), hull.end(),
                        std::back_inserter(rect2d));

  // 5. Compute center & angle
  double cx=0, cy=0;
  for(auto& q: rect2d){ cx+=q.x(); cy+=q.y(); }
  cx/=4; cy/=4;
  double dx = rect2d[1].x()-rect2d[0].x();
  double dy = rect2d[1].y()-rect2d[0].y();
  double angle_deg = std::atan2(dy, dx)*180.0/M_PI;
  double cz = 0.5*(zmin+zmax);

  // 6. Output
  std::cout<<"Center: ("<<cx<<","<<cy<<","<<cz<<")\n";
  std::cout<<"Rotation about Z: "<<angle_deg<<" deg\n";
}




int cgal2() {
  using Kernel = CGAL::Simple_cartesian<double>;
  using Point2 = Kernel::Point_2;

  using LEmptyRect = CGAL::Largest_empty_iso_rectangle_2<Kernel>;
  using IsoRect2   = typename LEmptyRect::Iso_rectangle_2;
  

  // 1. Load point cloud (aligned XY)
  open3d::geometry::PointCloud pcd;
  open3d::io::ReadPointCloud("partial.ply", pcd);

  // 2. Build 2D points & Z extents
  std::vector<Point2> pts2d;
  double zmin = 1e9, zmax = -1e9;
  for(auto& p : pcd.points_){
    pts2d.emplace_back(p(0), p(1));
    zmin = std::min(zmin, p(2));
    zmax = std::max(zmax, p(2));
  }

  // Assume pts2d contains (x,y) from your segmented plane
  std::vector<Point2> hull;
  CGAL::convex_hull_2(pts2d.begin(), pts2d.end(), std::back_inserter(hull));  // O(n log n) :contentReference[oaicite:4]{index=4}

  std::vector<Point2> rect2d;
  CGAL::min_rectangle_2(hull.begin(), hull.end(), std::back_inserter(rect2d)); // O(h) :contentReference[oaicite:5]{index=5}

  // Compute 2D center (cx,cy)
  double cx=0, cy=0;
  for (auto& p : rect2d) { cx += p.x(); cy += p.y(); }
  cx /= rect2d.size();  cy /= rect2d.size();

  // Compute orientation ¦È (radians) of edge 0¡ú1
  double dx = rect2d[1].x() - rect2d[0].x();
  double dy = rect2d[1].y() - rect2d[0].y();
  double theta = std::atan2(dy, dx);  // ¡Ê [¨C¦Ð,¦Ð]


  // Build 2¡Á2 rotation matrix R(¨C¦È)
  Eigen::Matrix2d R;
  R <<  std::cos(-theta), -std::sin(-theta),
    std::sin(-theta),  std::cos(-theta);

  // Apply to each 2D point
  std::vector<Point2> rotated_pts;
  rotated_pts.reserve(pts2d.size());
  for (auto& p : pts2d) {
    Eigen::Vector2d v(p.x(), p.y());
    Eigen::Vector2d v2 = R * (v - Eigen::Vector2d(cx, cy));
    rotated_pts.emplace_back(v2.x(), v2.y());
  }



  // 3.1 Compute XY bounding box of rotated plane
  double xmin=1e9, ymin=1e9, xmax=-1e9, ymax=-1e9;
  for (auto& p : rotated_pts) {
    xmin = std::min(xmin, p.x());
    ymin = std::min(ymin, p.y());
    xmax = std::max(xmax, p.x());
    ymax = std::max(ymax, p.y());
  }
  IsoRect2 bbox(Point2(xmin,ymin), Point2(xmax,ymax)); // :contentReference[oaicite:6]{index=6}

  // 3.2 Build and populate LEmptyRect
  LEmptyRect ler(bbox);
  for (auto& p : rotated_pts) {
    ler.insert(p);  // O(log n) each, overall O(n log n) :contentReference[oaicite:7]{index=7}
  }

  // 3.3 Query the largest empty rectangle
  IsoRect2 groove = ler.get_largest_empty_iso_rectangle();  // :contentReference[oaicite:8]{index=8}
  Point2 lo = groove.min(), hi = groove.max();  // axis©\aligned corners


  // 4.1 Center in de-rotated frame
  double gx = 0.5 * (lo.x() + hi.x());
  double gy = 0.5 * (lo.y() + hi.y());

  // 4.2 Rotate center back by +¦È (inverse of earlier)
  Eigen::Matrix2d Rinv = R.transpose();  // since R is orthonormal
  Eigen::Vector2d g_local(gx, gy);
  Eigen::Vector2d g_world = Rinv * g_local + Eigen::Vector2d(cx, cy);

  // 4.3 Final 2D center
  double final_cx = g_world.x();
  double final_cy = g_world.y();

  // Assuming original Z extents [zmin, zmax]
  double final_cz = 0.5 * (zmin + zmax);

  // Box extents
  double ex = hi.x() - lo.x();
  double ey = hi.y() - lo.y();
  double ez = zmax - zmin;

  std::cout << "Paste©\area MVBB center: ("
	    << final_cx << ", "
	    << final_cy << ", "
	    << final_cz << ")\n";
  std::cout << "Extents: ("
	    << ex << ", "
	    << ey << ", "
	    << ez << ")\n";
  std::cout << "Groove orientation = template orientation ¦È = "
	    << (theta * 180.0/M_PI) << "¡ã\n";

  
}


int cgal3() {
  using Kernel    = CGAL::Simple_cartesian<double>;
  using Point2    = Kernel::Point_2;
  using Traits    = CGAL::Alpha_shape_vertex_base_2<Kernel>;  
  using Vb        = CGAL::Alpha_shape_vertex_base_2<Kernel>;
  using Fb        = CGAL::Alpha_shape_face_base_2<Kernel>;
  using AsTraits  = CGAL::Alpha_shape_face_base_2<Kernel>;
  using Tds       = CGAL::Triangulation_data_structure_2<Vb,Fb>;
  using Triangulation_2 = CGAL::Delaunay_triangulation_2<Kernel, Tds>;
  using AlphaShape2 = CGAL::Alpha_shape_2<Triangulation_2>;

  // 1. Load point cloud (aligned XY)
  open3d::geometry::PointCloud pcd;
  open3d::io::ReadPointCloud("partial.ply", pcd);

  // 2. Build 2D points & Z extents
  std::vector<Point2> pts2d;
  double zmin = 1e9, zmax = -1e9;
  for(auto& p : pcd.points_){
    pts2d.emplace_back(p(0), p(1));
    zmin = std::min(zmin, p(2));
    zmax = std::max(zmax, p(2));
  }

  // Construct ¦Á-shape: choose ¦Á so holes appear (e.g., alpha = average edge length)
  double alpha = 1.5 * 8; /* tune: e.g. 1.5 * mean edge length */;
  AlphaShape2 A(pts2d.begin(), pts2d.end(), alpha,
  		AlphaShape2::GENERAL);

  // A.alpha() gives ¦Á; facets with classification `INTERIOR` form the shape,
  // those with `EXTERIOR` or `REGULAR` form holes :contentReference[oaicite:4]{index=4}.


  std::vector<std::vector<Point2>> holes;
  for (auto it = A.alpha_shape_edges_begin();
       it != A.alpha_shape_edges_end(); ++it) {
    if (A.classify(*it) == AlphaShape2::REGULAR) {
      // This edge lies on a hole boundary.
      // Traverse adjacent edges to build a cycle.
      // (Use a graph©\walk on the dual structure.)
    }
  }


}


// int cgal4() {

//   // 1. Load point cloud (aligned XY)
//   open3d::geometry::PointCloud pcd;
//   open3d::io::ReadPointCloud("partial.ply", pcd);

//   // // 2. Build 2D points & Z extents
//   // std::vector<Point2> pts2d;
//   // double zmin = 1e9, zmax = -1e9;
//   // for(auto& p : pcd.points_){
//   //   pts2d.emplace_back(p(0), p(1));
//   //   zmin = std::min(zmin, p(2));
//   //   zmax = std::max(zmax, p(2));
//   // }

//   GrooveOBB obb(pcd);
//   auto ctr = obb.center();
//   auto ext = obb.extent();
//   double ang = obb.angle();

// }
