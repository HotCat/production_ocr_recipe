#include <Open3D/Open3D.h>
#include <Eigen/Dense>
#include <iostream>

int main() {
    // Sample point cloud
    auto pcd = std::make_shared<open3d::geometry::PointCloud>();
    // Assuming pcd is already defined and loaded

    // Translation parameters
    double d = 1.0, a = 0.0, b = 0.0, c = 1.0;

    // Translate the point cloud
    pcd->Translate(Eigen::Vector3d(0, 0, d / c));

    // Calculate the angle and axis for rotation
    double cos_theta = c / std::sqrt(a * a + b * b + c * c);
    double theta = std::acos(cos_theta);

    Eigen::Vector3d rotation_axis(b / std::sqrt(a * a + b * b), -a / std::sqrt(a * a + b * b), 0);
    Eigen::Matrix3d R = open3d::geometry::GetRotationMatrixFromAxisAngle(rotation_axis * theta);

    // Apply the rotation
    pcd->Rotate(R, Eigen::Vector3d(0, 0, 0));

    // Combined transformation matrix (translation + rotation)
    Eigen::Matrix4d T = Eigen::Matrix4d::Identity();
    T.block<3, 3>(0, 0) = R;
    T.block<3, 1>(0, 3) = Eigen::Vector3d(0, 0, d / c);

    // Apply the combined transformation matrix
    pcd->Transform(T);

    // Visualize the point cloud
    open3d::visualization::DrawGeometries({pcd}, "Transformed Point Cloud");

    return 0;
}
