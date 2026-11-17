#include <iostream>
#include <Eigen/Dense>

// Define a structure for a line
struct Line {
    Eigen::Vector3d point;
    Eigen::Vector3d direction;
};

// Define a structure for a plane
struct Plane {
    Eigen::Vector3d normal;
    double d;
};

// Function to translate a line along a plane in a parallel way
Line translateLineAlongPlane(const Line& line, const Plane& plane, double distance) {
    // Calculate a translation vector parallel to the plane
    Eigen::Vector3d translationVector = plane.normal.cross(Eigen::Vector3d::UnitX());
    if (translationVector.norm() < 1e-6) {
        translationVector = plane.normal.cross(Eigen::Vector3d::UnitY());
    }
    translationVector.normalize();

    // Scale the translation vector by the specified distance
    translationVector *= distance;

    // Translate the line's point
    Eigen::Vector3d translatedPoint = line.point + translationVector;

    // Create the translated line
    Line translatedLine = {translatedPoint, line.direction};
    
    return translatedLine;
}

int main() {
    // Define the line
    Line line = {Eigen::Vector3d(1, 2, 3), Eigen::Vector3d(1, 0, 0)};
    
    // Define the plane
    Plane plane = {Eigen::Vector3d(0, 1, 0), 0.0}; // Plane y = 0

    // Translate the line along the plane in a parallel way
    double distance = 5.0; // Translate by a distance of 5 units
    Line translatedLine = translateLineAlongPlane(line, plane, distance);

    // Output the results
    std::cout << "Original Line Point: " << line.point.transpose() << std::endl;
    std::cout << "Translated Line Point: " << translatedLine.point.transpose() << std::endl;

    return 0;
}
