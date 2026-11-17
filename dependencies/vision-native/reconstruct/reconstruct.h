
#include "open3d/Open3D.h"
#include "Eigen/Dense"
#include "Triangulator.h"
#include "CalibrationData.h"
#include "CodecFactory.h"
#include "opencv2/opencv.hpp"
#include "unordered_map"
#include "diplib.h"
#include "dipviewer.h"
#include "dip_opencv_interface.h"
#include "diplib/file_io.h"
#include "diplib/regions.h"
#include "diplib/binary.h"
#include "diplib/measurement.h"
#include "diplib/chain_code.h"
#include "diplib/statistics.h"
#include "diplib/morphology.h"
#include "diplib/generation.h"
#include "diplib/display.h"
#include "dip_opencv_interface.h"
#include "ceres/ceres.h"
#include "future"
#include "iostream"
#include "ZMotion/Motion.hpp"
#include "zmotion.hpp"

#include "map"
#include "set"
#include "unordered_set"
#include "mapbox/variant.hpp"

#include "CGAL/Simple_cartesian.h"
#include "CGAL/convex_hull_2.h"
#include "CGAL/Polygon_2.h"
#include "CGAL/min_quadrilateral_2.h"
#include "CGAL/Largest_empty_iso_rectangle_2.h"
#include "CGAL/Alpha_shape_2.h"
#include "CGAL/Delaunay_triangulation_2.h"
#include "CGAL/Alpha_shape_vertex_base_2.h"
#include "CGAL/Alpha_shape_face_base_2.h"
#include "CGAL/Triangulation_data_structure_2.h"

/* #include "Polylidar/Polylidar.hpp" */
/* #include "PolylidarOBB.h" */

/* #include "GrooveOBB.h" */
#include "GrooveOBB_optimized.h"
#include "CircleFitting.h"


using namespace cv;
using namespace open3d;

// Define a type alias for a 4-component vector (RGBA color)
using Vec4 = std::array<float, 4>;

using Value = mapbox::util::variant<double, int, std::string>;

// Define a custom hash function for Eigen::Vector3d
struct Vector3dHash {
    std::size_t operator()(const Eigen::Vector3d& vec) const {
        std::size_t seed = 0;
        for (int i = 0; i < 3; ++i) {
            seed ^= std::hash<double>()(vec[i]) + 0x9e3779b9 + (seed << 6) + (seed >> 2);
        }
        return seed;
    }
};


class Reconstruct {

public:
  Reconstruct();
  ~Reconstruct();

  geometry::PointCloud i2PC(int index);
  int addFrame(const cv::Mat& mat, int thresh);
  int conductProduction(const cv::Mat& mat, int thresh);
  std::vector<float> exportPC(int index);
  void findPlane();
  int  alignGrid(open3d::geometry::PointCloud& pointCloud);
  void NormalizePC(open3d::geometry::PointCloud& pointcloud);
  void clipPointCloud(Eigen::Matrix4f & model_matrix, int index);
  void applyTransform(Eigen::Matrix4f & matrix, int index);
  void setProfiloBlend(float blend);
  void setCalibSequence(int sequence);
  void setConfigIndex(int index);
  int getCalibSequence();
  void setTargetTranslation(Eigen::Vector3d translation);
  Eigen::Vector3d getTargetTranslation();
  void setCustomColorBlend(Vec4& customColor, float blend, int index);
  void setLabelMorphology(double value);
  void setProductMorphology(double value);
  void setLabelResolution(double value);
  void setProductResolution(double value);
  void setDistanceThreshold(double value);
  void setNozzleResolution(double value);
  void setNozzleThreshold(double value);
  void setWrapModel(Eigen::Matrix4f model_matrix);
  Eigen::Matrix4f getWrapModel(int index);
  int labelAlign();
  int productAlign();
  int syncPointcloud();
  int syntheticAlign(Eigen::Matrix4f& label, Eigen::Matrix4f& product, Eigen::Vector3d axis);
  int directlyAlign(Eigen::Matrix4f& label, Eigen::Matrix4f& product, std::vector<cv::Point2d>& pixels, std::vector<cv::Point2d>& worlds);
  int setManuParams(int thresh, Eigen::Matrix4f& label, Eigen::Matrix4f& product, std::vector<cv::Point2d>& pixels, std::vector<cv::Point2d>& worlds);
  void setMotionHandle(ModbusZ& handle);
  Eigen::Matrix4d estimateTransform(open3d::geometry::PointCloud& source, open3d::geometry::PointCloud& dest, bool project);
  Eigen::Matrix4f gizmoAlign(Eigen::Matrix4f &gizmoMatrix);
  Eigen::Matrix4f gizmoRotationAxle(Eigen::Matrix4f &gizmoMatrix, float scaleFactor = 10.0f);
  std::tuple<double, double, double> getMotionRevise();
  void setMotionRevise(double angle, double dx, double dy);
  void setLabelAdjustOffset(double dx, double dy);
  void setLabelDenoise(double neighbors, double ratio);
  Eigen::Vector2d getLabelExtent();
  void setLabelExtent(double w, double h);
  void setProductDenoise(double neighbors, double ratio);
  std::vector<Eigen::Vector3d> unwrapPointCloud(std::vector<Eigen::Vector3d>& pointCloud);

private:
  int calibSequence;
  int configIndex;
  double labelMorphology;
  double productMorphology;
  double labelResolution;
  double productResolution;
  double distanceThreshold;
  double nozzleResolution;
  double nozzleThreshold;
  int profiloThreshold;
  Eigen::Vector2d labelDenoise;
  Eigen::Vector2d productDenoise;
  Eigen::Vector2d adjustOffset;
  Eigen::Vector2d labelExtent;
  Eigen::Matrix4f wrapBoxModel;
  Eigen::Matrix4f labelBox;
  Eigen::Matrix4f productBox;
  std::vector<cv::Point2d> pixels;
  std::vector<cv::Point2d> worlds;
  cv::Ptr<ModbusZ> busPtr;

  Vec4 customColor[10];
  float blendFactor[10];
  float profiloBlend;
  double plane_a, plane_b, plane_c, plane_d;
  CalibrationData calib;
  Triangulator *triangulator;
  Eigen::Vector3d targetTranslation;
  geometry::PointCloud originCloud;
  geometry::PointCloud pointCloud;
  geometry::PointCloud labelPC;
  geometry::PointCloud labelTempPC;
  geometry::PointCloud productPC;
  geometry::PointCloud productTempPC;
  geometry::PointCloud convPlanePC;
  Eigen::Matrix4d altTransform;

  std::vector<float> transiPC;
  std::vector<float> transiLabel;
  std::vector<float> transiLabelTemp;
  std::vector<float> transiProduct;
  std::vector<float> transiProductTemp;
  std::vector<float> transiConvPlane;

  std::tuple<double, double, double> motionRevise;

  std::vector<cv::Mat> matSequence; // Stores the sequence of Mats
  geometry::PointCloud convertToPointCloud(const std::vector<cv::Mat>& mats, int thresh);
  geometry::PointCloud buildPointCloud(const std::vector<cv::Mat>& mats, int thresh);
  int processAlignment();
  std::shared_ptr<geometry::OrientedBoundingBox> CreateOrientedBoundingBox(const Eigen::Matrix4f& model_matrix, const std::array<float, 6>& local_bounds);
  std::tuple<Eigen::Vector3d, double, Eigen::Vector3d> getPointCloud3dWrap(int index);

  std::pair<Eigen::Matrix4d, Eigen::Matrix6d> FullRegistration(
    const std::shared_ptr<open3d::geometry::PointCloud> &source,
    const std::shared_ptr<open3d::geometry::PointCloud> &target,
    double voxel_size,
    double max_correspondence_distance_coarse,
    double max_correspondence_distance_fine);

  Eigen::Vector3d BlendColors(const Eigen::Vector3d& color1, const Eigen::Vector3d& color2, double weight1, double weight2);
  Eigen::Vector3d findRealRotationPoint(const Eigen::Matrix4d& transform);
  open3d::geometry::PointCloud CombinePointCloudsFromSameSource(const std::vector<open3d::geometry::PointCloud>& cropped_pcds);
  double getRotationAngleXY(const Eigen::Matrix4d& transformation);
  Eigen::Matrix4d combineTransformationsWithRotationPoint(const Eigen::Matrix4d& firstTransform,const Eigen::Matrix4d& secondTransform,const Eigen::Vector3d& rotationPoint);
  std::vector<std::shared_ptr<open3d::geometry::PointCloud>> LoadPointClouds(open3d::geometry::PointCloud& source, open3d::geometry::PointCloud& dest, double voxel_size, bool project);
  double computePitchAngle();
  Vec4 mix(const Vec4& color1, const Vec4& color2, float factor);
};


