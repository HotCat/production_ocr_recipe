{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

{-|
Module: DearImGui

Main ImGui module, exporting the functions to create a GUI.
-}

module DearImGui.Raw
  ( -- * Context Creation and Access
    Context(..)
  , createContext
  , destroyContext
  , getCurrentContext
  , setCurrentContext

    -- * Main
  , newFrame
  , endFrame
  , render
  , DrawData(..)
  , getDrawData
  , checkVersion

    -- * Demo, Debug, Information
  , showDemoWindow
  , showMetricsWindow
  , showAboutWindow
  , showUserGuide
  , getVersion

    -- * Styles
  , styleColorsDark
  , styleColorsLight
  , styleColorsClassic

    -- * Windows
  , begin
  , end

    -- ** Utilities

  , getWindowDrawList
  , getWindowPos
  , getWindowSize
  , getDisplaySize
  , getWindowWidth
  , getWindowHeight

    -- ** Manipulation

  , setNextWindowPos
  , setNextWindowSize
  , setNextWindowFullscreen
  , setNextWindowContentSize
  , setNextWindowSizeConstraints
  , setNextWindowCollapsed
  , setNextWindowBgAlpha

    -- ** Child Windows
  , beginChild
  , beginChildContext
  , endChild

    -- * Parameter stacks
  , pushStyleColor
  , popStyleColor
  , pushStyleVar
  , popStyleVar

    -- * Cursor/Layout
  , separator
  , sameLine
  , sameLine2
  , newLine
  , spacing
  , dummy
  , indent
  , unindent
  , setNextItemWidth
  , setNextItemOpen
  , pushItemWidth
  , popItemWidth
  , beginGroup
  , endGroup
  , setCursorPos
  , getCursorScreenPos
  , alignTextToFramePadding

    -- * Widgets
    -- ** Text
  , textUnformatted
  , textColored
  , textDisabled
  , textWrapped
  , labelText
  , bulletText

    -- ** Main
  , button
  , paddingbutton
  , smallButton
  , invisibleButton
  , arrowButton
  , image
  , imageButton
  , checkbox
  , radiobutton
  , progressBar
  , progressBar2
  , bullet

    -- ** Combo Box
  , beginCombo
  , endCombo
  , combo

    -- ** Drag Sliders
  , dragFloat
  , dragFloat2
  , dragFloat3
  , dragFloat4
  , dragFloatRange2
  , dragInt
  , dragInt2
  , dragInt3
  , dragInt4
  , dragIntRange2
  , dragScalar
  , dragScalarN

    -- ** Slider
  , sliderFloat
  , sliderFloat2
  , sliderFloat3
  , sliderFloat4
  , sliderAngle
  , sliderInt
  , sliderInt2
  , sliderInt3
  , sliderInt4
  , sliderScalar
  , sliderScalarN
  , vSliderFloat
  , vSliderInt
  , vSliderScalar

    -- ** Text Input
  , inputText
  , inputText2
  , inputTextMultiline
  , inputTextWithHint

    -- * Color Editor/Picker
  , colorEdit4
  , colorPicker3
  , colorButton

    -- * Tables
  , beginTable
  , endTable
  , tableNextRow
  , tableNextColumn
  , tableSetColumnIndex

  , tableSetupColumn
  , tableSetupScrollFreeze
  , tableHeadersRow
  , tableHeader

  , tableGetSortSpecs
  , tableClearSortSpecsDirty

  , tableGetColumnCount
  , tableGetColumnIndex
  , tableGetRowIndex
  , tableGetColumnName
  , tableGetColumnFlags
  , tableSetColumnEnabled
  , tableSetBgColor

    -- * Trees
  , treeNode
  , treePush
  , treePop
  , collapsingHeader

    -- ** Selectables
  , selectable
  , selectable2

    -- ** List Boxes
  , listBox

    -- * Data Plotting
  , plotHistogram

    -- ** Menus
  , beginMenuBar
  , endMenuBar
  , beginMainMenuBar
  , endMainMenuBar
  , beginMenu
  , endMenu
  , menuItem
  , menuItem2

    -- ** Tabs, tab bar
  , beginTabBar
  , endTabBar
  , beginTabItem
  , beginTabItem2
  , endTabItem
  , tabItemButton
  , setTabItemClosed

    -- * Tooltips
  , beginTooltip
  , endTooltip

    -- * Popups/Modals
  , beginPopup
  , beginPopupModal
  , endPopup
  , openPopup
  , openPopupOnItemClick
  , closeCurrentPopup
  , beginPopupContextItem
  , beginPopupContextWindow
  , beginPopupContextVoid
  , isPopupOpen

    -- * ID stack/scopes
  , pushIDInt
  , pushIDPtr
  , pushIDStr
  , pushIDStrLen
  , popID
  , getFPS
  , getMouseWheel
  , showAppLog
  , myHelpMarker
  , myColorButton

    -- * Item/Widgets Utilities
  , isItemHovered
  , isItemActive
  , wantCaptureMouse
  , wantCaptureKeyboard

    -- * Utilities
  , getCrosshair
  , getIndicator
  , isMouseDoubleClicked
  , captureMouseWheel

  , initImGuizmo
  , gizmoManipulate
  , framebufferProject
  , framebufferModel
  , setupViewWindow
  , copyModelMatrix
  , switchBoundingBox
  , curBoundingBox
  , beginImPlot
  , filledLinePlots
  , runPlotDemo

    -- ** Miscellaneous
  , getBackgroundDrawList
  , getForegroundDrawList
  , imCol32

    -- * Types
  , module DearImGui.Enums
  , module DearImGui.Structs
  )
  where

-- base
import Control.Monad.IO.Class
  ( MonadIO, liftIO )
import Foreign
import Foreign.C
import System.IO.Unsafe
  ( unsafePerformIO )

-- dear-imgui
import DearImGui.Context
  ( imguiContext )
import DearImGui.Enums
import DearImGui.Structs
import DearImGui.Raw.DrawList (DrawList(..))

-- inline-c
import qualified Language.C.Inline as C

-- inline-c-cpp
import qualified Language.C.Inline.Cpp as Cpp

import Data.Bool

import Linear (M44, V4(..))
import Text.RawString.QQ

C.context (Cpp.cppCtx <> C.bsCtx <> imguiContext)
C.include "imgui.h"
Cpp.using "namespace ImGui"

C.include "stdio.h"
C.include "stdlib.h"
C.include "imgui_internal.h"

C.include "ImGuizmo.h"

C.include "implot.h"
C.include "implot_internal.h"

C.include "RollingBuffer.h"

-- | Wraps @ImGuiContext*@.
newtype Context = Context (Ptr ImGuiContext)


-- | Wraps @ImGui::CreateContext()@.
createContext :: (MonadIO m) => m Context
createContext = liftIO do
  Context <$> [C.exp| ImGuiContext* { CreateContext() } |]


beginImPlot :: (MonadIO m) => m ()
beginImPlot = liftIO do
  [C.block| void {
       ImPlot::CreateContext(); }
  |]


C.verbatim [r|

  #include <vector>
  #include <iostream>
  #include <map>
  #include <algorithm>
  #include <cmath>
  #include <sstream>
  #include <string>
  #include <Eigen/Dense>

  #define GLM_ENABLE_EXPERIMENTAL
  #include <glm/glm.hpp>
  #include <glm/gtc/type_ptr.hpp>
  #include <glm/gtc/quaternion.hpp>
  #include <glm/gtx/quaternion.hpp>
  #include <glm/gtc/matrix_transform.hpp>

  static ImGuizmo::OPERATION mCurrentGizmoOperation(ImGuizmo::TRANSLATE);
  
  int gizmoCount = 1;
  bool isPerspective = true;
  bool isDrawGrid = false;
  bool boundSizing = false;
  float panOffsetX = 0.0;
  float panOffsetY = 0.0;
  float panStepsX = 0.022;
  float panStepsY = 0.022;

  float camDistance = 8.f;
  float fov = 41.007f;
  float viewWidth = 10.f; // for orthographic
  float camYAngle = 165.f / 180.f * 3.14159f;
  float camXAngle = 32.f / 180.f * 3.14159f;

  bool viewDirty = false;
  bool viewDirty2 = false;
  bool firstFrame = true;

  static float cameraView2[16] =
  { 1.f, 0.f, 0.f, 0.f,
    0.f, 1.f, 0.f, 0.f,
    0.f, 0.f, 1.f, 0.f,
    0.f, 0.f, 0.f, 1.f };

  static float cameraProjection2[16];
  static float cameraProjection3[16];

  static float identityMatrix[16] =
  { 1.f, 0.f, 0.f, 0.f,
    0.f, 1.f, 0.f, 0.f,
    0.f, 0.f, 1.f, 0.f,
    0.f, 0.f, 0.f, 1.f };

  static float matrix2[16] =
  { 1.f, 0.f, 0.f, 0.f,
    0.f, 1.f, 0.f, 0.f,
    0.f, 0.f, 1.f, 0.f,
    0.f, 0.f, 0.f, 1.f };

  static float objectMatrix[4][16] = {
    { 1.f, 0.f, 0.f, 0.f,
      0.f, 1.f, 0.f, 0.f,
      0.f, 0.f, 1.f, 0.f,
      0.f, 0.f, 0.f, 1.f },
  
    { 1.f, 0.f, 0.f, 0.f,
    0.f, 1.f, 0.f, 0.f,
    0.f, 0.f, 1.f, 0.f,
    2.f, 0.f, 0.f, 1.f },
  
    { 1.f, 0.f, 0.f, 0.f,
    0.f, 1.f, 0.f, 0.f,
    0.f, 0.f, 1.f, 0.f,
    2.f, 0.f, 2.f, 1.f },
  
    { 1.f, 0.f, 0.f, 0.f,
    0.f, 1.f, 0.f, 0.f,
    0.f, 0.f, 1.f, 0.f,
    0.f, 0.f, 2.f, 1.f }
  };

  static float deltaMatrix[16] =
  { 1.f, 0.f, 0.f, 0.f,
    0.f, 1.f, 0.f, 0.f,
    0.f, 0.f, 1.f, 0.f,
    0.f, 0.f, 0.f, 1.f };

  // Define PI for angle conversion
  constexpr float PI = 3.14159265358979323846f;

  // Function to convert degrees to radians
  float radians(float degrees) {
      return degrees * PI / 180.0f;
  }

  // Function to get the rotation matrix as a float[16] array
  void getRotationMatrix(float* matrix) {
      // Define the angle of rotation (90 degrees in radians)
      float angle = radians(90.0f);
  
      // Calculate the sine and cosine of the angle
      float cosA = std::cos(angle);
      float sinA = std::sin(angle);
  
      // Create a 4x4 rotation matrix for a 90-degree rotation around the X-axis
      matrix[0]  = 1.0f; matrix[1]  = 0.0f;  matrix[2]  = 0.0f;  matrix[3]  = 0.0f;
      matrix[4]  = 0.0f; matrix[5]  = cosA;  matrix[6]  = -sinA; matrix[7]  = 0.0f;
      matrix[8]  = 0.0f; matrix[9]  = sinA;  matrix[10] = cosA;  matrix[11] = 0.0f;
      matrix[12] = 0.0f; matrix[13] = 0.0f;  matrix[14] = 0.0f;  matrix[15] = 1.0f;
  }

  void EditTransform(float* cameraView, float* cameraProjection, float* matrix, float* delta);

  void Cross(const float* a, const float* b, float* r)
  {
     r[0] = a[1] * b[2] - a[2] * b[1];
     r[1] = a[2] * b[0] - a[0] * b[2];
     r[2] = a[0] * b[1] - a[1] * b[0];
  }

  float Dot(const float* a, const float* b)
  {
     return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  }
  
  void Normalize(const float* a, float* r)
  {
     float il = 1.f / (sqrtf(Dot(a, a)) + FLT_EPSILON);
     r[0] = a[0] * il;
     r[1] = a[1] * il;
     r[2] = a[2] * il;
  }

  void LookAt(const float* eye, const float* at, const float* up, float* m16)
  {
     float X[3], Y[3], Z[3], tmp[3];
  
     tmp[0] = eye[0] - at[0];
     tmp[1] = eye[1] - at[1];
     tmp[2] = eye[2] - at[2];
     Normalize(tmp, Z);
     Normalize(up, Y);
  
     Cross(Y, Z, tmp);
     Normalize(tmp, X);
  
     Cross(Z, X, tmp);
     Normalize(tmp, Y);
  
     m16[0] = X[0];
     m16[1] = Y[0];
     m16[2] = Z[0];
     m16[3] = 0.0f;
     m16[4] = X[1];
     m16[5] = Y[1];
     m16[6] = Z[1];
     m16[7] = 0.0f;
     m16[8] = X[2];
     m16[9] = Y[2];
     m16[10] = Z[2];
     m16[11] = 0.0f;
     m16[12] = -Dot(X, eye);
     m16[13] = -Dot(Y, eye);
     m16[14] = -Dot(Z, eye);
     m16[15] = 1.0f;
  }

  void Frustum(float left, float right, float bottom, float top, float znear, float zfar, float* m16)
  {
     float temp, temp2, temp3, temp4;
     temp = 2.0f * znear;
     temp2 = right - left;
     temp3 = top - bottom;
     temp4 = zfar - znear;
     m16[0] = temp / temp2;
     m16[1] = 0.0;
     m16[2] = 0.0;
     m16[3] = 0.0;
     m16[4] = 0.0;
     m16[5] = temp / temp3;
     m16[6] = 0.0;
     m16[7] = 0.0;
     m16[8] = (right + left) / temp2;
     m16[9] = (top + bottom) / temp3;
     m16[10] = (-zfar - znear) / temp4;
     m16[11] = -1.0f;
     m16[12] = 0.0;
     m16[13] = 0.0;
     m16[14] = (-temp * zfar) / temp4;
     m16[15] = 0.0;
  }

  void OrthoGraphic(const float l, float r, float b, const float t, float zn, const float zf, float* m16)
  {
     m16[0] = 2 / (r - l);
     m16[1] = 0.0f;
     m16[2] = 0.0f;
     m16[3] = 0.0f;
     m16[4] = 0.0f;
     m16[5] = 2 / (t - b);
     m16[6] = 0.0f;
     m16[7] = 0.0f;
     m16[8] = 0.0f;
     m16[9] = 0.0f;
     m16[10] = 1.0f / (zf - zn);
     m16[11] = 0.0f;
     m16[12] = (l + r) / (l - r);
     m16[13] = (t + b) / (b - t);
     m16[14] = zn / (zn - zf);
     m16[15] = 1.0f;
  }

  void Perspective(float fovyInDegrees, float aspectRatio, float znear, float zfar, float* m16)
  {
     float ymax, xmax;
     ymax = znear * tanf(fovyInDegrees * 3.141592f / 180.0f);
     xmax = ymax * aspectRatio;
     Frustum(-xmax, xmax, -ymax, ymax, znear, zfar, m16);
  }

  void PanView(glm::mat4& viewMatrix, float deltaX, float deltaY)
  {
    // Extract right and up vectors from the current view matrix
    glm::vec3 right(viewMatrix[0][0], viewMatrix[1][0], viewMatrix[2][0]);
    glm::vec3 up(viewMatrix[0][1], viewMatrix[1][1], viewMatrix[2][1]);

    // Calculate the translation based on deltas and vectors
    glm::vec3 translation = right * deltaX + up * deltaY;

    // Apply the translation to the view matrix (camera position and target)
    viewMatrix = glm::translate(viewMatrix, translation);
  }

  void setupViewWindow(bool active)
  {
    if(active)
    {
      isPerspective = false;
      gizmoCount = 2;
      viewWidth = 10.f;
      viewDirty2 = true;
      boundSizing = true;
    }
    else
    {
      gizmoCount = 1;
      viewDirty2 = false;
    }
  }

  void copymodelmatrix(float* matrix)
  {
    memcpy(&objectMatrix[1][0], matrix, 16*sizeof(float));
  }

  void copyBoundingBox(float* matrix)
  {
    memcpy(&objectMatrix[0][0], matrix, 16*sizeof(float));
  }

  void EditTransform(float* cameraView, float* cameraProjection, float* matrix, float* delta)
  {
    static ImGuizmo::MODE mCurrentGizmoMode(ImGuizmo::LOCAL);
    static bool useSnap = false;
    static float snap[3] = { 0.001f, 0.001f, 0.001f };
    static float bounds[] = { -0.5f, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f };
    static float boundsSnap[] = { 0.001f, 0.001f, 0.001f };
    static bool boundSizingSnap = false;

    ImGuiIO& io = ImGui::GetIO();

    if (isPerspective)
    {
       Perspective(fov, io.DisplaySize.x / io.DisplaySize.y, 0.1f, 100.f, cameraProjection2);
    }
    else
    {
      float viewHeight = viewWidth * io.DisplaySize.y / io.DisplaySize.x;
      OrthoGraphic(-viewWidth, viewWidth, -viewHeight, viewHeight, 1000.f, -1000.f, cameraProjection2);
    }

    ImGuizmo::SetOrthographic(!isPerspective);

    ImGui::Begin("Gizmo", 0, 0);

    ImGui::Text("Camera");

    if (ImGui::RadioButton("Perspective", isPerspective)) isPerspective = true;
    ImGui::SameLine();
    if (ImGui::RadioButton("Orthographic", !isPerspective)) isPerspective = false;
    if (isPerspective)
    {
       ImGui::SliderFloat("Fov", &fov, 2.f, 110.f);
    }
    else
    {
       ImGui::SliderFloat("Ortho width", &viewWidth, 1, 20);
    }

    viewDirty = ImGui::SliderFloat("Distance", &camDistance, 1.f, 10.f);
    ImGui::SliderFloat("panStepsX", &panStepsX, 0.01f, 0.05f);
    ImGui::SliderFloat("panStepsY", &panStepsY, 0.01f, 0.05f);

    if (ImGui::RadioButton("Translate", mCurrentGizmoOperation == ImGuizmo::TRANSLATE))
        mCurrentGizmoOperation = ImGuizmo::TRANSLATE;
    ImGui::SameLine();
    if (ImGui::RadioButton("Rotate", mCurrentGizmoOperation == ImGuizmo::ROTATE))
        mCurrentGizmoOperation = ImGuizmo::ROTATE;
    ImGui::SameLine();
    if (ImGui::RadioButton("Scale", mCurrentGizmoOperation == ImGuizmo::SCALE))
        mCurrentGizmoOperation = ImGuizmo::SCALE;

    ImGui::SliderInt("Gizmo count", &gizmoCount, 1, 2);

    ImGui::Checkbox("DrawGrid", &isDrawGrid);

    ImGui::Checkbox("Bound Sizing", &boundSizing);

    if (viewDirty || viewDirty2 || firstFrame)
    {
      glm::mat4 view = glm::lookAt(glm::vec3(0.0f, 0.0f, camDistance), glm::vec3(0.0f, 0.0f, 0.0f), glm::vec3(0.0f, 1.0f, 0.0f));
      std::copy(glm::value_ptr(view), glm::value_ptr(view) + 16, cameraView2);

      firstFrame = false;
    }

    ImGui::End();

    io = ImGui::GetIO();

    float viewManipulateRight = io.DisplaySize.x;
    float viewManipulateTop = 0;

    ImGuizmo::SetRect(0, 0, io.DisplaySize.x, io.DisplaySize.y);
    ImGuizmo::AllowAxisFlip(false);

    float horizMatrix[16];

    getRotationMatrix(horizMatrix);

    if(isDrawGrid) {
      ImGuizmo::DrawGrid(cameraView2, cameraProjection2, horizMatrix, 100.f);
    }

    for(int matId = 0; matId < gizmoCount; matId++)
    {
      ImGuizmo::SetID(matId);
      ImGuizmo::Manipulate(cameraView2, cameraProjection2, mCurrentGizmoOperation, ImGuizmo::LOCAL, objectMatrix[matId], deltaMatrix, &snap[0], boundSizing ? bounds : NULL, boundsSnap);
      ImGuizmo::ViewManipulate(cameraView2, camDistance, ImVec2(viewManipulateRight - 128, viewManipulateTop), ImVec2(128, 128), 0x10101010);
    }

    if(IsMouseDown(1)) {
      panOffsetX = io.MouseDelta.x * panStepsX;
      panOffsetY = -io.MouseDelta.y * panStepsY;
    }

    if(io.KeyCtrl) {
      if (isPerspective) {
        fov += 1.5 * io.MouseWheel;
        if(fov > 60.0) fov = 60.0;
        if(fov < 2.0) fov = 2.0;
      }
      else {
        viewWidth += 1.5 * io.MouseWheel;
        if(viewWidth > 20.0) viewWidth = 20.0;
        if(viewWidth < 1.0) viewWidth = 1.0;
      }
    }


    glm::mat4 viewMatrix = glm::make_mat4(cameraView2);
    PanView(viewMatrix, panOffsetX, panOffsetY);
    panOffsetX = 0.f;
    panOffsetY = 0.f;
    std::copy(glm::value_ptr(viewMatrix), glm::value_ptr(viewMatrix) + 16, cameraView2);
    
    memcpy(cameraView, cameraView2, 16*sizeof(float));
    memcpy(cameraProjection, cameraProjection2, 16*sizeof(float));
    memcpy(matrix, &objectMatrix[0][0], 2*16*sizeof(float));
    memcpy(delta, deltaMatrix, 16*sizeof(float));
  }

  void framebufferMatrix(float* cameraProjection)
  {
    float fov = 41.007f;
    float viewWidth = 10.f;
    ImGuiIO& io = ImGui::GetIO();

    if (isPerspective)
    {
       Perspective(fov, io.DisplaySize.x / io.DisplaySize.y, 0.1f, 100.f, cameraProjection3);
    }
    else
    {
      float viewHeight = viewWidth * io.DisplaySize.y / io.DisplaySize.x;
      OrthoGraphic(-viewWidth, viewWidth, -viewHeight, viewHeight, 1000.f, -1000.f, cameraProjection3);
    }

    memcpy(cameraProjection, cameraProjection3, 16*sizeof(float));
  }

  void framebufferModel(float* cameraModel)
  {
    memcpy(cameraModel, &objectMatrix[1][0], 16*sizeof(float));
  }

|]


cFloatArrayToM44 :: Ptr CFloat -> IO (M44 Float)
cFloatArrayToM44 ptr = do
    values <- peekArray 16 ptr
    let [m11,m12,m13,m14,m21,m22,m23,m24,m31,m32,m33,m34,m41,m42,m43,m44] = map realToFrac values
    return $ V4 (V4 m11 m12 m13 m14)
                (V4 m21 m22 m23 m24)
                (V4 m31 m32 m33 m34)
                (V4 m41 m42 m43 m44)


-- Convert M44 to Ptr Float
withM44 :: M44 Float -> (Ptr CFloat -> IO a) -> IO a
withM44 (V4 (V4 a00 a01 a02 a03)
             (V4 a10 a11 a12 a13)
             (V4 a20 a21 a22 a23)
             (V4 a30 a31 a32 a33)) f =
  let arr = [ realToFrac a00, realToFrac a01, realToFrac a02, realToFrac a03
            , realToFrac a10, realToFrac a11, realToFrac a12, realToFrac a13
            , realToFrac a20, realToFrac a21, realToFrac a22, realToFrac a23
            , realToFrac a30, realToFrac a31, realToFrac a32, realToFrac a33]
  in withArray arr f


setupViewWindow :: Bool -> IO ()
setupViewWindow active = do
  let c'flag = fromIntegral (if active then 1 else 0)
  [C.block| void {
     if($(int c'flag)) {
       setupViewWindow(true);
     }
     else {
       setupViewWindow(false);
     }
  }|]


-- Function to copy matrix to C representation
copyModelMatrix :: M44 Float -> IO ()
copyModelMatrix matrix = 
  withM44 matrix $ \matrixPtr -> do
    -- Call the C function `copymodelmatrix`
    [C.block| void {
      copymodelmatrix($(float* matrixPtr));
    } |]


identityMatrix = V4 (V4 1 0 0 0) (V4 0 1 0 0) (V4 0 0 1 0) (V4 0 0 0 1)


switchBoundingBox :: M44 Float -> IO ()
switchBoundingBox matrix =
  withM44 matrix $ \matrixPtr -> do
  [C.block| void {
    copyBoundingBox($(float* matrixPtr));
  } |]


curBoundingBox :: IO (M44 Float)
curBoundingBox = do
  let curModel = identityMatrix
  withM44 curModel $ \curModelPtr -> do
    [C.block| void {
       memcpy($(float* curModelPtr), &objectMatrix[0][0], 16*sizeof(float));
    } |]

    newModel <- peekArray 16 curModelPtr
    let [d11, d12, d13, d14, d21, d22, d23, d24, d31, d32, d33, d34, d41, d42, d43, d44] = map realToFrac newModel
    return (V4 (V4 d11 d12 d13 d14)
             (V4 d21 d22 d23 d24)
             (V4 d31 d32 d33 d34)
             (V4 d41 d42 d43 d44))


framebufferProject :: IO (M44 Float)
framebufferProject = do
  let cameraProjection = identityMatrix

  withM44 cameraProjection $ \cameraProjectionPtr -> do
    -- Call the framebufferMatrix function
    [C.block| void {
      framebufferMatrix($(float* cameraProjectionPtr));
    } |]

    -- Read 16 elements (4x4 matrix) from cameraProjectionPtr
    newCameraProjection <- peekArray 16 cameraProjectionPtr
    let [k11, k12, k13, k14, k21, k22, k23, k24, k31, k32, k33, k34, k41, k42, k43, k44] = map realToFrac newCameraProjection

    return (V4 (V4 k11 k12 k13 k14)
               (V4 k21 k22 k23 k24)
               (V4 k31 k32 k33 k34)
               (V4 k41 k42 k43 k44))


framebufferModel :: IO (M44 Float)
framebufferModel = do
  let modelMatrix = identityMatrix

  withM44 modelMatrix $ \modelMatrixPtr -> do
    -- Call the framebufferModel function
    [C.block| void {
      framebufferModel($(float* modelMatrixPtr));
    } |]

    -- Read 16 elements (4x4 matrix) from modelMatrixPtr
    newModelMatrix <- peekArray 16 modelMatrixPtr
    let [k11, k12, k13, k14, k21, k22, k23, k24, k31, k32, k33, k34, k41, k42, k43, k44] = map realToFrac newModelMatrix

    return (V4 (V4 k11 k12 k13 k14)
               (V4 k21 k22 k23 k24)
               (V4 k31 k32 k33 k34)
               (V4 k41 k42 k43 k44))



gizmoManipulate :: IO (M44 Float, M44 Float, [M44 Float], M44 Float)
gizmoManipulate = do
  let cameraView = identityMatrix
      cameraProjection = identityMatrix
      deltaMatrix = identityMatrix

  withM44 cameraView $ \cameraViewPtr ->
    withM44 cameraProjection $ \cameraProjectionPtr ->
      withM44 deltaMatrix $ \deltaPtr -> do
        -- Allocate enough space for the matrices (assuming 3 matrices, adjust size as needed)
        allocaArray (16 * 3) $ \matrixPtr -> do
          -- Call the EditTransform function
          [C.block| void {
            EditTransform($(float* cameraViewPtr), $(float* cameraProjectionPtr), $(float* matrixPtr), $(float* deltaPtr));
          } |]
          
          -- Read 16 elements (4x4 matrix) from cameraViewPtr
          newCameraView <- peekArray 16 cameraViewPtr
          let [m11, m12, m13, m14, m21, m22, m23, m24, m31, m32, m33, m34, m41, m42, m43, m44] = map realToFrac newCameraView
          
          -- Read 16 elements (4x4 matrix) from cameraProjectionPtr
          newCameraProjection <- peekArray 16 cameraProjectionPtr
          let [k11, k12, k13, k14, k21, k22, k23, k24, k31, k32, k33, k34, k41, k42, k43, k44] = map realToFrac newCameraProjection

          newDelta <- peekArray 16 deltaPtr
          let [d11, d12, d13, d14, d21, d22, d23, d24, d31, d32, d33, d34, d41, d42, d43, d44] = map realToFrac newDelta
          
          -- Read multiple matrices from matrixPtr (adjust number of matrices as needed)
          matrixData <- peekArray (16 * 3) matrixPtr  -- Read 3 matrices, adjust 3 as needed
          
          -- Convert the matrix data to a list of M44 Float
          let matrices = [V4 (V4 j11 j12 j13 j14) (V4 j21 j22 j23 j24) (V4 j31 j32 j33 j34) (V4 j41 j42 j43 j44)
                          | i <- [0, 16 .. (16 * 3 - 1)]
                          , let [j11, j12, j13, j14, j21, j22, j23, j24, j31, j32, j33, j34, j41, j42, j43, j44] = map realToFrac (take 16 (drop i matrixData))
                          ]
          
          return (V4 (V4 m11 m12 m13 m14)
                     (V4 m21 m22 m23 m24)
                     (V4 m31 m32 m33 m34)
                     (V4 m41 m42 m43 m44),
                  V4 (V4 k11 k12 k13 k14)
                     (V4 k21 k22 k23 k24)
                     (V4 k31 k32 k33 k34)
                     (V4 k41 k42 k43 k44),
                  matrices,
                  V4 (V4 d11 d12 d13 d14)
                     (V4 d21 d22 d23 d24)
                     (V4 d31 d32 d33 d34)
                     (V4 d41 d42 d43 d44)
                  )


initImGuizmo :: (MonadIO m) => m ()
initImGuizmo = liftIO do
  [C.block| void {
       ImGuizmo::SetDrawlist(ImGui::GetForegroundDrawList());
  }|]


filledLinePlots :: (MonadIO m) => Int -> Double -> m ()
filledLinePlots seq value = do
  let c'seq = fromIntegral seq
      c'value = realToFrac value
  liftIO do
    [C.block| void {

      ImGui::Begin("My plot");
    
      static RollingBuffer rdata1;
      ImVec2 mouse = ImGui::GetMousePos();
      static float t = 0;
      if($(double c'value) > 0.0) {
        t = (float)$(int c'seq);
        rdata1.AddPoint(t, $(double c'value));
      }
      static float history = 256.0f;
      rdata1.Span = history;

      static ImPlotAxisFlags flags = ImPlotAxisFlags_NoTickLabels;

      if (ImPlot::BeginPlot("##Rolling", ImVec2(-1,300))) {
          ImPlot::SetupAxes(nullptr, nullptr, flags, flags);
          ImPlot::SetupAxisLimits(ImAxis_X1,0,history, ImGuiCond_Always);
          ImPlot::SetupAxisLimits(ImAxis_Y1,0,100);
          if(rdata1.Data.size() > 0) {
            ImPlot::PushStyleColor(ImPlotCol_Line, ImVec4(1.0f,0.0f,0.0f,1.0f));
            ImPlot::PlotLine("Gamma Response", &rdata1.Data[0].x, &rdata1.Data[0].y, rdata1.Data.size(), 0, 0, 2 * sizeof(float));
            ImPlot::PopStyleColor();
          }
          ImPlot::EndPlot();
      }
    
      ImGui::End();
    
    }|]


C.verbatim [r|

   #include <mutex>

   struct Level {
       std::vector<double> xs;
       std::vector<double> ys;
   };

   std::vector<Level> LOD;
   std::vector<std::string> serialStrings;
   std::mutex g_mutex;

   long plotIndex = -1;
   std::vector<int> dbIndex;

|]


-- runPlotDemo :: (MonadIO m) => m ()
-- runPlotDemo = liftIO do
--   [C.block| void {
--       std::lock_guard<std::mutex> lk(g_mutex);

--       if (LOD.empty())
--           return;

--       if (ImGui::Begin("Batch Weight Plot")) {
--         if (ImPlot::BeginPlot("Weights")) {
--           // -----------------------------------------------------
--           // Get visible X range using ImPlotRect
--           // -----------------------------------------------------
--           ImPlotRect limits = ImPlot::GetPlotLimits();  // returns X.Min, X.Max
--           double visibleMin = limits.X.Min;
--           double visibleMax = limits.X.Max;
          
--           // -----------------------------------------------------
--           // Determine LOD level based on total points
--           // -----------------------------------------------------
--           const int TARGET = 20000;

--           //int level = 0;
--           //while (level + 1 < (int)LOD.size()) {
--           //    if ((int)LOD[level].xs.size() > TARGET)
--           //        level++;
--           //    else
--           //        break;
--           //}

--           // Select the LOD level that has <= TARGET points in the visible range
--           int level = 0;
--           for (int i = 0; i < (int)LOD.size(); i++) {
--               // Count points in visible range
--               auto &xs = LOD[i].xs;
--               int count = std::count_if(xs.begin(), xs.end(),
--                                         [&](double x){ return x >= visibleMin && x <= visibleMax; });
--               if (count <= TARGET) {
--                   level = i;
--                   break;
--               }
--           }


--           // Zoom-in check: switch to full-resolution if few points in visible range
--           auto& xsFull = LOD[0].xs;
--           int idxStart = std::max(0, (int)visibleMin);
--           int idxEnd   = std::min((int)xsFull.size()-1, (int)visibleMax);
--           if ((idxEnd - idxStart) < TARGET) {
--               level = 0;  // force full-resolution
--           }

--           std::cout << "level +++: " << level << std::endl;
          
--           // -----------------------------------------------------
--           // Select LOD arrays
--           // -----------------------------------------------------
--           auto& xs = LOD[level].xs;
--           auto& ys = LOD[level].ys;
          
--           // -----------------------------------------------------
--           // Draw Plot
--           // -----------------------------------------------------

--           // std::cout << "plotIndex+++: " << plotIndex << std::endl;

--           // draw line
--           ImPlot::PlotLine("Weight", xs.data(), ys.data(), xs.size());

--           if(ImPlot::IsPlotHovered()) {
--             ImGuiIO& io = ImGui::GetIO();
--             if(ImGui::IsMouseDown(0) && io.MouseDownDuration[0] > 0.5) {
--               ImPlotPoint mouse = ImPlot::GetPlotMousePos();
--               plotIndex = (long)round(mouse.x);

--               if (plotIndex >= 0 && plotIndex < serialStrings.size()) {
--                 const char* serial = serialStrings[plotIndex].c_str();

--                 std::cout << "serial +++: " << serial << std::endl;

--                 ImGui::BeginTooltip();
--                 ImGui::Text("Serial: %s", serial);
--                 ImGui::Text("Weight: %.2f", mouse.y);
--                 ImGui::EndTooltip();
--               }
              
--             }
--           }
        
--           ImPlot::EndPlot();
--         }
--         ImGui::End();
--       }

--   }|]


runPlotDemo :: (MonadIO m) => m ()
runPlotDemo = liftIO do
  [C.block| void {
      std::lock_guard<std::mutex> lk(g_mutex);

      if (LOD.empty())
          return;

      if (ImGui::Begin("Batch Weight Plot")) {
        if (ImPlot::BeginPlot("Weights")) {
          // -----------------------------------------------------
          // Get visible X range using ImPlotRect
          // -----------------------------------------------------
          ImPlotRect limits = ImPlot::GetPlotLimits();  // returns X.Min, X.Max
          double visibleMin = limits.X.Min;
          double visibleMax = limits.X.Max;
          
          // -----------------------------------------------------
          // Determine LOD level based on total points
          // -----------------------------------------------------
          const int TARGET = 20000;
          int level = 0;
          while (level + 1 < (int)LOD.size()) {
              if ((int)LOD[level].xs.size() > TARGET)
                  level++;
              else
                  break;
          }

          // Zoom-in check: switch to full-resolution if few points in visible range
          auto& xsFull = LOD[0].xs;
          int idxStart = std::max(0, (int)visibleMin);
          int idxEnd   = std::min((int)xsFull.size()-1, (int)visibleMax);
          if ((idxEnd - idxStart) < TARGET) {
              level = 0;  // force full-resolution
          }

          // std::cout << "level +++: " << level << std::endl;
          
          // -----------------------------------------------------
          // Select LOD arrays
          // -----------------------------------------------------
          auto& xs = LOD[level].xs;
          auto& ys = LOD[level].ys;
          
          // -----------------------------------------------------
          // Draw Plot
          // -----------------------------------------------------

          // std::cout << "plotIndex+++: " << plotIndex << std::endl;

          // draw line
          ImPlot::PlotLine("Weight", xs.data(), ys.data(), xs.size());

          if(ImPlot::IsPlotHovered()) {
            ImGuiIO& io = ImGui::GetIO();
            if(ImGui::IsMouseDown(0) && io.MouseDownDuration[0] > 0.5) {
              ImPlotPoint mouse = ImPlot::GetPlotMousePos();
              plotIndex = (long)round(mouse.x);

              if (plotIndex >= 0 && plotIndex < serialStrings.size()) {
                const char* serial = serialStrings[plotIndex].c_str();

                std::cout << "serial +++: " << serial << std::endl;

                ImGui::BeginTooltip();
                ImGui::Text("Serial: %s", serial);
                ImGui::Text("Weight: %.2f", mouse.y);
                ImGui::EndTooltip();
              }
              
            }
          }
        
          ImPlot::EndPlot();
        }
        ImGui::End();
      }

  }|]


-- | Wraps @ImGui::DestroyContext()@.
destroyContext :: (MonadIO m) => Context -> m ()
destroyContext (Context contextPtr) = liftIO do
  [C.exp| void { DestroyContext($(ImGuiContext* contextPtr)); } |]

-- | Wraps @ImGui::GetCurrentContext()@.
getCurrentContext :: MonadIO m => m Context
getCurrentContext = liftIO do
  Context <$> [C.exp| ImGuiContext* { GetCurrentContext() } |]


-- | Wraps @ImGui::SetCurrentContext()@.
setCurrentContext :: MonadIO m => Context -> m ()
setCurrentContext (Context contextPtr) = liftIO do
  [C.exp| void { SetCurrentContext($(ImGuiContext* contextPtr)) } |]


-- | Start a new Dear ImGui frame, you can submit any command from this point
-- until 'render'/'endFrame'.
--
-- Wraps @ImGui::NewFrame()@.
newFrame :: (MonadIO m) => m ()
newFrame = liftIO do
  [C.exp| void { NewFrame(); } |]


-- | Ends the Dear ImGui frame. automatically called by 'render'. If you don't
-- need to render data (skipping rendering) you may call 'endFrame' without
-- 'render'... but you'll have wasted CPU already! If you don't need to render,
-- better to not create any windows and not call 'newFrame' at all!
endFrame :: (MonadIO m) => m ()
endFrame = liftIO do
  [C.exp| void { EndFrame(); } |]


-- | Ends the Dear ImGui frame, finalize the draw data. You can then get call
-- 'getDrawData'.
render :: (MonadIO m) => m ()
render = liftIO do
  [C.exp| void { Render(); } |]




getIndicator :: (MonadIO m) => Ptr CBool -> m ()
getIndicator boolPtr = liftIO do
  [C.block| void {
    bool active = *$(bool* boolPtr);
    ImVec2 size(50.0f, 60.0f);

    ImGui::SameLine();
    ImGui::InvisibleButton("##canvas", size);

    if (!ImGui::IsItemVisible())
       return;

    const ImVec2 p0 = ImGui::GetItemRectMin();
    const ImVec2 p1 = ImGui::GetItemRectMax();

    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    draw_list->AddCircleFilled(ImVec2(p0.x+15,p0.y+30) , 25.0, active?IM_COL32(255, 255, 0, 255):IM_COL32(255, 0, 0, 255), 0);

  }|]




getCrosshair :: (MonadIO m) => Ptr CDouble -> m ()
getCrosshair doublePtr = liftIO do
  [C.block| void {
    static ImVec2 size(75.0f, 25.0f);

    ImGui::InvisibleButton("##canvas", size);
    if (ImGui::IsItemActive() && ImGui::IsMouseDragging(ImGuiMouseButton_Left))
    {
        ($(double* doublePtr))[0] += ImGui::GetIO().MouseDelta.x;
        ($(double* doublePtr))[1] += -ImGui::GetIO().MouseDelta.y;
    }

    if (!ImGui::IsItemVisible())
      return;

    const ImVec2 p0 = ImGui::GetItemRectMin();
    const ImVec2 p1 = ImGui::GetItemRectMax();
    ImDrawList* draw_list = ImGui::GetWindowDrawList();

    ImVec4 clip_rect(p0.x, p0.y, p1.x, p1.y);
    draw_list->AddRectFilled(p0, p1, IM_COL32(90, 90, 120, 255));
  }|]


isMouseDoubleClicked :: (MonadIO m) => m CInt
isMouseDoubleClicked = liftIO do
  [C.block| int {
      return IsMouseDoubleClicked(0);
  }|]


-- | Disable mouse scrolling event
captureMouseWheel :: (MonadIO m) => m ()
captureMouseWheel = liftIO do
  [C.block| void {
    SetItemUsingMouseWheel();
  }|]


getMouseWheel :: (MonadIO m) => m Double
getMouseWheel = liftIO do
  realToFrac <$> [C.exp| double { GetIO().MouseWheel } |]


-- | Wraps @ImDrawData*@.
newtype DrawData = DrawData (Ptr ())


-- | Valid after 'render' and until the next call to 'newFrame'. This is what
-- you have to render.
getDrawData :: (MonadIO m) => m DrawData
getDrawData = liftIO do
  DrawData <$> [C.exp| void* { GetDrawData() } |]


-- | Wraps @IMGUI_CHECKVERSION()@
checkVersion :: (MonadIO m) => m ()
checkVersion = liftIO do
  [C.exp| void { IMGUI_CHECKVERSION(); } |]


-- | Create demo window. Demonstrate most ImGui features. Call this to learn
-- about the library! Try to make it always available in your application!
showDemoWindow :: (MonadIO m) => m ()
showDemoWindow = liftIO do
  [C.exp| void { ShowDemoWindow(); } |]


-- | Create Metrics/Debugger window. Display Dear ImGui internals: windows, draw
-- commands, various internal state, etc.
showMetricsWindow :: (MonadIO m) => m ()
showMetricsWindow = liftIO do
  [C.exp| void { ShowMetricsWindow(); } |]


-- | Create About window. display Dear ImGui version, credits and build/system
-- information.
showAboutWindow :: (MonadIO m) => m ()
showAboutWindow = liftIO do
  [C.exp| void { ShowAboutWindow(); } |]


-- | Add basic help/info block (not a window): how to manipulate ImGui as a
-- end-user (mouse/keyboard controls).
showUserGuide :: (MonadIO m) => m ()
showUserGuide = liftIO do
  [C.exp| void { ShowUserGuide() } |]


-- | Get the compiled version string e.g. "1.80 WIP" (essentially the value for
-- @IMGUI_VERSION@ from the compiled version of @imgui.cpp@).
getVersion :: (MonadIO m) => m CString
getVersion = liftIO do
  [C.exp| const char* { GetVersion() } |]


-- | New, recommended style (default).
--
-- Wraps @ImGui::StyleColorsDark()@.
styleColorsDark :: (MonadIO m) => m ()
styleColorsDark = liftIO do
  [C.exp| void { StyleColorsDark(); } |]


-- | Best used with borders and a custom, thicker font.
--
-- Wraps @ImGui::StyleColorsLight()@.
styleColorsLight :: (MonadIO m) => m ()
styleColorsLight = liftIO do
  [C.exp| void { StyleColorsLight(); } |]


-- | Classic ImGui style.
--
-- Wraps @ImGui::StyleColorsClasic()@.
styleColorsClassic :: (MonadIO m) => m ()
styleColorsClassic = liftIO do
  [C.exp| void { StyleColorsClassic(); } |]


-- | Push window to the stack and start appending to it.
--
-- Returns 'False' to indicate the window is collapsed or fully clipped, so you
-- may early out and omit submitting anything to the window. Always call a
-- matching 'end' for each 'begin' call, regardless of its return value!
--
-- Wraps @ImGui::Begin()@.
--
-- Passing non-null @Ptr CBool@ shows a window-closing widget in the upper-right corner of the window,
-- wich clicking will set the boolean to false when clicked.
begin :: (MonadIO m) => CString -> Maybe (Ptr CBool) -> Maybe (ImGuiWindowFlags) -> m Bool
begin namePtr (Just openPtr) (Just flags) = liftIO do
  (0 /=) <$> [C.exp| bool { Begin($(char* namePtr), $(bool* openPtr), $(ImGuiWindowFlags flags)) } |]
begin namePtr (Just openPtr) Nothing = liftIO do
  (0 /=) <$> [C.exp| bool { Begin($(char* namePtr), $(bool* openPtr)) } |]
begin namePtr Nothing Nothing = liftIO do
  (0 /=) <$> [C.exp| bool { Begin($(char* namePtr)) } |]
begin _ Nothing _ = error "C++ default argument restriction."

-- | Pop window from the stack.
--
-- Wraps @ImGui::End()@.
end :: (MonadIO m) => m ()
end = liftIO do
  [C.exp| void { End(); } |]


-- | Begin a self-contained independent scrolling/clipping regions within a host window.
--
-- Child windows can embed their own child.
--
-- For each independent axis of @size@:
--   * ==0.0f: use remaining host window size
--   * >0.0f: fixed size
--   * <0.0f: use remaining window size minus abs(size)
--
-- Each axis can use a different mode, e.g. @ImVec2 0 400@.
--
-- @BeginChild()@ returns `False` to indicate the window is collapsed or fully clipped, so you may early out and omit submitting anything to the window.
--
-- Always call a matching `endChild` for each `beginChild` call, regardless of its return value.
--
-- Wraps @ImGui::BeginChild()@.
beginChild :: (MonadIO m) => CString -> Ptr ImVec2 -> CBool -> ImGuiWindowFlags -> m Bool
beginChild namePtr sizePtr border flags = liftIO do
  (0 /=) <$> [C.exp|
    bool {
      BeginChild(
        $(char* namePtr),
        *$(ImVec2* sizePtr),
        $(bool border),
        $(ImGuiWindowFlags flags)
      )
    }
  |]

-- | Switch context to another child window by its ID
--
-- Wraps @ImGui::BeginChild()@.
beginChildContext :: (MonadIO m) => CString -> m Bool
beginChildContext namePtr = liftIO do
  (0 /=) <$> [C.exp|
    bool {
      BeginChild(
        $(char* namePtr)
      )
    }
  |]

-- | Wraps @ImGui::EndChild()@.
endChild :: (MonadIO m) => m ()
endChild = liftIO do
  [C.exp| void { EndChild(); } |]


-- | Separator, generally horizontal. inside a menu bar or in horizontal layout
-- mode, this becomes a vertical separator.
--
-- Wraps @ImGui::Separator()@
separator :: (MonadIO m) => m ()
separator = liftIO do
  [C.exp| void { Separator(); } |]


-- | Call between widgets or groups to layout them horizontally.
--
-- Wraps @ImGui::SameLine@.
sameLine :: (MonadIO m) => m ()
sameLine = liftIO do
  [C.exp| void { SameLine(); } |]


sameLine2 :: (MonadIO m) => m ()
sameLine2 = liftIO do
  [C.exp| void { SameLine(0.0f, ImGui::GetStyle().ItemInnerSpacing.x); } |]

-- | Raw text without formatting.
--
-- Roughly equivalent to Text("%s", text) but:
--   A) doesn't require null terminated string if 'text_end' is specified,
--   B) it's faster, no memory copy is done, no buffer size limits, recommended for long chunks of text.
--
-- Wraps @ImGui::TextUnformatted()@.
textUnformatted :: (MonadIO m) => CString -> Maybe CString -> m ()
textUnformatted textPtr (Just textEndPtr) = liftIO do
  [C.exp| void { TextUnformatted($(char* textPtr), $(char* textEndPtr)) } |]
textUnformatted textPtr Nothing = liftIO do
  [C.exp| void { TextUnformatted($(char* textPtr)) } |]

-- | Shortcut for @PushStyleColor(ImGuiCol_Text, col); Text(fmt, ...); PopStyleColor();@.
--
-- XXX: Unlike the original, does not do string formatting.
--
-- Wraps @ImGui::TextColored()@.
textColored :: (MonadIO m) => Ptr ImVec4 -> CString -> m ()
textColored colorPtr textPtr = liftIO do
  [C.exp| void { TextColored(*$(ImVec4 *colorPtr), "%s", $(char* textPtr)) } |]

-- | Shortcut for @PushStyleColor(ImGuiCol_Text, style.Colors[ImGuiCol_TextDisabled]); Text(fmt, ...); PopStyleColor();@.
--
-- XXX: Unlike the original, does not do string formatting.
--
-- Wraps @ImGui::TextWrapped()@.
textDisabled :: (MonadIO m) => CString -> m ()
textDisabled textPtr = liftIO do
  [C.exp| void { TextDisabled("%s", $(char* textPtr)) } |]

-- | Shortcut for @PushTextWrapPos(0.0f); Text(fmt, ...); PopTextWrapPos();@.
--
-- Note that this won't work on an auto-resizing window if there's no other widgets to extend the window width,
-- you may need to set a size using 'setNextWindowSize'.
--
-- XXX: Unlike the original, does not do string formatting.
--
-- Wraps @ImGui::TextWrapped()@.
textWrapped :: (MonadIO m) => CString -> m ()
textWrapped textPtr = liftIO do
  [C.exp| void { TextWrapped("%s", $(char* textPtr)) } |]

-- | Label+text combo aligned to other label+value widgets.
--
-- XXX: Unlike the original, does not do string formatting.
--
-- Wraps @ImGui::LabelText()@.
labelText :: (MonadIO m) => CString -> CString -> m ()
labelText labelPtr textPtr = liftIO do
  [C.exp| void { LabelText($(char* labelPtr), "%s", $(char* textPtr)) } |]

-- | Text with a little bullet aligned to the typical tree node.
--
-- XXX: Unlike the original, does not do string formatting.
--
-- Wraps @ImGui::BulletText()@.
bulletText :: (MonadIO m) => CString -> m ()
bulletText textPtr = liftIO do
  [C.exp| void { BulletText("%s", $(char* textPtr)) } |]

-- | A button. Returns 'True' when clicked.
--
-- Wraps @ImGui::Button()@.
button :: (MonadIO m) => CString -> m Bool
button labelPtr = liftIO do
  (0 /=) <$> [C.exp| bool { Button($(char* labelPtr)) } |]

paddingbutton :: (MonadIO m) => CString -> m Bool
paddingbutton labelPtr = liftIO do
  (0 /=) <$> [C.exp| bool { Button($(char* labelPtr), ImVec2(-FLT_MIN, 0.0f)) } |]

-- | Button with @FramePadding=(0,0)@ to easily embed within text.
--
-- Wraps @ImGui::SmallButton()@.
smallButton :: (MonadIO m) => CString -> m Bool
smallButton labelPtr = liftIO do
  (0 /=) <$> [C.exp| bool { SmallButton($(char* labelPtr)) } |]


-- | Flexible button behavior without the visuals.
--
-- Frequently useful to build custom behaviors using the public api
-- (along with IsItemActive, IsItemHovered, etc).
--
-- Wraps @ImGui::InvisibleButton()@.
invisibleButton :: (MonadIO m) => CString -> Ptr ImVec2 -> ImGuiButtonFlags -> m Bool
invisibleButton labelPtr size flags = liftIO do
  (0 /=) <$> [C.exp|
    bool {
      InvisibleButton(
        $(char* labelPtr),
        *$(ImVec2* size),
        $(ImGuiButtonFlags flags)
      )
    }
  |]

-- | Square button with an arrow shape.
--
-- Wraps @ImGui::ArrowButton()@.
arrowButton :: (MonadIO m) => CString -> ImGuiDir -> m Bool
arrowButton strIdPtr dir = liftIO do
  (0 /=) <$> [C.exp| bool { ArrowButton($(char* strIdPtr), $(ImGuiDir dir)) } |]


-- | Image Area to draw a texture.
--
-- For OpenGL: The @userTextureIDPtr@ points to the texture memory (eg. @0x0000000000000001@)
--
-- See @examples/sdl/Image.hs@ for the whole process.
--
-- Wraps @ImGui::Image()@.
image :: (MonadIO m) => Ptr () -> Ptr ImVec2 -> Ptr ImVec2 -> Ptr ImVec2 -> Ptr ImVec4 -> Ptr ImVec4 -> m ()
image userTextureIDPtr sizePtr uv0Ptr uv1Ptr tintColPtr borderColPtr = liftIO do
  [C.exp|
    void {
      Image(
        $(void* userTextureIDPtr),
        *$(ImVec2* sizePtr),
        *$(ImVec2* uv0Ptr),
        *$(ImVec2* uv1Ptr),
        *$(ImVec4* tintColPtr),
        *$(ImVec4* borderColPtr)
      )
    }
  |]

-- | Clickable Image Area.
--
-- Negative @frame_padding@ uses default frame padding settings. Set to 0 for no padding.
--
-- Wraps @ImGui::ImageButton()@.
imageButton :: (MonadIO m) => Ptr () -> Ptr ImVec2 -> Ptr ImVec2 -> Ptr ImVec2 -> CInt -> Ptr ImVec4 -> Ptr ImVec4 -> m Bool
imageButton userTextureIDPtr sizePtr uv0Ptr uv1Ptr framePadding bgColPtr tintColPtr = liftIO do
  (0 /=) <$> [C.exp|
    bool {
      ImageButton(
        $(void* userTextureIDPtr),
        *$(ImVec2* sizePtr),
        *$(ImVec2* uv0Ptr),
        *$(ImVec2* uv1Ptr),
        $(int framePadding),
        *$(ImVec4* bgColPtr),
        *$(ImVec4* tintColPtr)
      )
    }
  |]


-- | Wraps @ImGui::Checkbox()@.
checkbox :: (MonadIO m) => CString -> Ptr CBool -> m Bool
checkbox labelPtr boolPtr = liftIO do
  (0 /=) <$> [C.exp| bool { Checkbox($(char* labelPtr), $(bool* boolPtr)) } |]


radiobutton :: (MonadIO m) => CString -> Ptr CInt -> CInt -> m Bool
radiobutton labelPtr intPtr tag = liftIO do
  (0 /=) <$> [C.exp| bool { RadioButton($(char* labelPtr), $(int* intPtr), $(int tag)) } |]


-- TODO: publish ImVec2(-FLT_MIN, 0)
-- | Wraps @ImGui::ProgressBar()@.
progressBar :: (MonadIO m) => CFloat -> CString -> m ()
progressBar progress overlayPtr = liftIO do
    [C.exp| void { ProgressBar($(float progress), ImVec2(-FLT_MIN, 0), $(char* overlayPtr)) } |]

progressBar2 :: (MonadIO m) => CFloat -> CString -> m ()
progressBar2 progress overlayPtr = liftIO do
    [C.exp| void { ProgressBar($(float progress), ImVec2(0, 0), $(char* overlayPtr)) } |]

-- | Draw a small circle + keep the cursor on the same line. Advance cursor x
-- position by 'getTreeNodeToLabelSpacing', same distance that 'treeNode' uses.
bullet :: (MonadIO m) => m ()
bullet = liftIO do
  [C.exp| void { Bullet() } |]


-- | Begin creating a combo box with a given label and preview value.
--
-- Returns 'True' if the combo box is open. In this state, you should populate
-- the contents of the combo box - for example, by calling 'selectable'.
--
-- Wraps @ImGui::BeginCombo()@.
beginCombo :: (MonadIO m) => CString -> CString -> m Bool
beginCombo labelPtr previewValuePtr = liftIO do
  (0 /=) <$> [C.exp| bool { BeginCombo($(char* labelPtr), $(char* previewValuePtr)) } |]


-- | Only call 'endCombo' if 'beginCombo' returns 'True'!
--
-- Wraps @ImGui::EndCombo()@.
endCombo :: (MonadIO m) => m ()
endCombo = liftIO do
  [C.exp| void { EndCombo() } |]


-- | Wraps @ImGui::Combo()@.
combo :: (MonadIO m) => CString -> Ptr CInt -> Ptr CString -> CInt -> m Bool
combo labelPtr iPtr itemsPtr itemsLen = liftIO do
  (0 /=) <$> [C.exp| bool { Combo($(char* labelPtr), $(int* iPtr), $(char** itemsPtr), $(int itemsLen)) }|]


-- | Wraps @ImGui::DragFloat()@
dragFloat :: (MonadIO m) => CString -> Ptr CFloat -> CFloat -> CFloat -> CFloat -> m Bool
dragFloat descPtr floatPtr speed minValue maxValue = liftIO do
  (0 /=) <$> [C.exp| bool { DragFloat( $(char* descPtr), $(float* floatPtr), $(float speed), $(float minValue), $(float maxValue)) } |]


-- | Wraps @ImGui::DragFloat2()@
dragFloat2 :: (MonadIO m) => CString -> Ptr CFloat -> CFloat -> CFloat -> CFloat -> m Bool
dragFloat2 descPtr floatPtr speed minValue maxValue = liftIO do
  (0 /=) <$> [C.exp| bool { DragFloat2( $(char* descPtr), $(float* floatPtr), $(float speed), $(float minValue), $(float maxValue)) } |]


-- | Wraps @ImGui::DragFloat3()@
dragFloat3 :: (MonadIO m) => CString -> Ptr CFloat -> CFloat -> CFloat -> CFloat -> m Bool
dragFloat3 descPtr floatPtr speed minValue maxValue = liftIO do
  (0 /=) <$> [C.exp| bool { DragFloat3( $(char* descPtr), $(float* floatPtr), $(float speed), $(float minValue), $(float maxValue)) } |]


-- | Wraps @ImGui::DragFloat4()@
dragFloat4 :: (MonadIO m) => CString -> Ptr CFloat -> CFloat -> CFloat -> CFloat -> m Bool
dragFloat4 descPtr floatPtr speed minValue maxValue = liftIO do
  (0 /=) <$> [C.exp| bool { DragFloat4( $(char* descPtr), $(float* floatPtr), $(float speed), $(float minValue), $(float maxValue)) } |]


-- | Wraps @ImGui::DragFloatRange2()@
dragFloatRange2 :: (MonadIO m) => CString -> Ptr CFloat -> Ptr CFloat -> CFloat -> CFloat -> CFloat -> CString -> CString -> ImGuiSliderFlags -> m Bool
dragFloatRange2 labelPtr vCurrentMin vCurrentMax vSpeed vMin vMax formatMin formatMax flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    DragFloatRange2(
      $(char* labelPtr),
      $(float* vCurrentMin),
      $(float* vCurrentMax),
      $(float vSpeed),
      $(float vMin),
      $(float vMax),
      $(char* formatMin),
      $(char* formatMax),
      $(ImGuiSliderFlags flags)
    )
  } |]


-- | Wraps @ImGui::DragInt()@
dragInt :: (MonadIO m) => CString -> Ptr CInt -> CFloat -> CInt -> CInt -> CString -> ImGuiSliderFlags -> m Bool
dragInt labelPtr vPtr vSpeed vMin vMax formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    DragInt(
      $(char* labelPtr),
      $(int* vPtr),
      $(float vSpeed),
      $(int vMin),
      $(int vMax),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]

-- | Wraps @ImGui::DragInt2()@
dragInt2 :: (MonadIO m) => CString -> Ptr CInt -> CFloat -> CInt -> CInt -> CString -> ImGuiSliderFlags -> m Bool
dragInt2 labelPtr vPtr vSpeed vMin vMax formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    DragInt2(
      $(char* labelPtr),
      $(int vPtr[2]),
      $(float vSpeed),
      $(int vMin),
      $(int vMax),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]

-- | Wraps @ImGui::DragInt3()@
dragInt3 :: (MonadIO m) => CString -> Ptr CInt -> CFloat -> CInt -> CInt -> CString -> ImGuiSliderFlags -> m Bool
dragInt3 labelPtr vPtr vSpeed vMin vMax formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    DragInt3(
      $(char* labelPtr),
      $(int vPtr[3]),
      $(float vSpeed),
      $(int vMin),
      $(int vMax),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]

-- | Wraps @ImGui::DragInt4()@
dragInt4 :: (MonadIO m) => CString -> Ptr CInt -> CFloat -> CInt -> CInt -> CString -> ImGuiSliderFlags -> m Bool
dragInt4 labelPtr vPtr vSpeed vMin vMax formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    DragInt4(
      $(char* labelPtr),
      $(int vPtr[4]),
      $(float vSpeed),
      $(int vMin),
      $(int vMax),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]

-- | Wraps @ImGui::DragFloatRange2()@
dragIntRange2 :: (MonadIO m) => CString -> Ptr CInt -> Ptr CInt -> CFloat -> CInt -> CInt -> CString -> CString -> ImGuiSliderFlags -> m Bool
dragIntRange2 labelPtr vCurrentMin vCurrentMax vSpeed vMin vMax formatMin formatMax flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    DragIntRange2(
      $(char* labelPtr),
      $(int* vCurrentMin),
      $(int* vCurrentMax),
      $(float vSpeed),
      $(int vMin),
      $(int vMax),
      $(char* formatMin),
      $(char* formatMax),
      $(ImGuiSliderFlags flags)
    )
  } |]

-- | Wraps @ImGui::DragScalar()@
dragScalar :: (MonadIO m) => CString -> ImGuiDataType -> Ptr a -> CFloat -> Ptr a -> Ptr a -> CString -> ImGuiSliderFlags -> m Bool
dragScalar labelPtr dataType dataPtr vSpeed minPtr maxPtr formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    DragScalar(
      $(char* labelPtr),
      $(ImGuiDataType dataType),
      $(void* dataPtr_),
      $(float vSpeed),
      $(void* minPtr_),
      $(void* maxPtr_),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]
  where
    dataPtr_ = castPtr dataPtr
    minPtr_ = castPtr minPtr
    maxPtr_ = castPtr maxPtr

-- | Wraps @ImGui::DragScalarN()@
dragScalarN :: (MonadIO m) => CString -> ImGuiDataType -> Ptr a -> CInt -> CFloat -> Ptr a -> Ptr a -> CString -> ImGuiSliderFlags -> m Bool
dragScalarN labelPtr dataType dataPtr components vSpeed minPtr maxPtr formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    DragScalarN(
      $(char* labelPtr),
      $(ImGuiDataType dataType),
      $(void* dataPtr_),
      $(int components),
      $(float vSpeed),
      $(void* minPtr_),
      $(void* maxPtr_),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]
  where
    dataPtr_ = castPtr dataPtr
    minPtr_ = castPtr minPtr
    maxPtr_ = castPtr maxPtr

-- | Wraps @ImGui::SliderFloat()@
sliderFloat :: (MonadIO m) => CString -> Ptr CFloat -> CFloat -> CFloat -> m Bool
sliderFloat descPtr floatPtr minValue maxValue = liftIO do
  (0 /=) <$> [C.exp| bool { SliderFloat( $(char* descPtr), $(float* floatPtr), $(float minValue), $(float maxValue)) } |]


-- | Wraps @ImGui::SliderFloat2()@
sliderFloat2 :: (MonadIO m) => CString -> Ptr CFloat -> CFloat -> CFloat -> m Bool
sliderFloat2 descPtr floatPtr minValue maxValue = liftIO do
  (0 /=) <$> [C.exp| bool { SliderFloat2( $(char* descPtr), $(float* floatPtr), $(float minValue), $(float maxValue)) } |]


-- | Wraps @ImGui::SliderFloat3()@
sliderFloat3 :: (MonadIO m) => CString -> Ptr CFloat -> CFloat -> CFloat -> m Bool
sliderFloat3 descPtr floatPtr minValue maxValue = liftIO do
  (0 /=) <$> [C.exp| bool { SliderFloat3( $(char* descPtr), $(float* floatPtr), $(float minValue), $(float maxValue)) } |]


-- | Wraps @ImGui::SliderFloat4()@
sliderFloat4 :: (MonadIO m) => CString -> Ptr CFloat -> CFloat -> CFloat -> m Bool
sliderFloat4 descPtr floatPtr minValue maxValue = liftIO do
  (0 /=) <$> [C.exp| bool { SliderFloat4( $(char* descPtr), $(float* floatPtr), $(float minValue), $(float maxValue)) } |]

-- | Wraps @ImGui::SliderAngle()@
sliderAngle :: (MonadIO m) => CString -> Ptr CFloat -> CFloat -> CFloat -> CString -> ImGuiSliderFlags -> m Bool
sliderAngle descPtr valueRadPtr degreesMin degreesMax format flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    SliderAngle(
      $(char* descPtr),
      $(float* valueRadPtr),
      $(float degreesMin),
      $(float degreesMax),
      $(char* format),
      $(ImGuiSliderFlags flags)
    )
  } |]

-- | Wraps @ImGui::SliderInt()@
sliderInt :: (MonadIO m) => CString -> Ptr CInt -> CInt -> CInt -> CString -> ImGuiSliderFlags -> m Bool
sliderInt labelPtr vPtr vMin vMax formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    SliderInt(
      $(char* labelPtr),
      $(int* vPtr),
      $(int vMin),
      $(int vMax),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]

-- | Wraps @ImGui::SliderInt2()@
sliderInt2 :: (MonadIO m) => CString -> Ptr CInt -> CInt -> CInt -> CString -> ImGuiSliderFlags -> m Bool
sliderInt2 labelPtr vPtr vMin vMax formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    SliderInt2(
      $(char* labelPtr),
      $(int vPtr[2]),
      $(int vMin),
      $(int vMax),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]

-- | Wraps @ImGui::SliderInt3()@
sliderInt3 :: (MonadIO m) => CString -> Ptr CInt -> CInt -> CInt -> CString -> ImGuiSliderFlags -> m Bool
sliderInt3 labelPtr vPtr vMin vMax formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    SliderInt3(
      $(char* labelPtr),
      $(int vPtr[3]),
      $(int vMin),
      $(int vMax),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]

-- | Wraps @ImGui::SliderInt4()@
sliderInt4 :: (MonadIO m) => CString -> Ptr CInt -> CInt -> CInt -> CString -> ImGuiSliderFlags -> m Bool
sliderInt4 labelPtr vPtr vMin vMax formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    SliderInt4(
      $(char* labelPtr),
      $(int vPtr[4]),
      $(int vMin),
      $(int vMax),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]

-- | Wraps @ImGui::SliderScalar()@
sliderScalar :: (MonadIO m) => CString -> ImGuiDataType -> Ptr a -> Ptr a -> Ptr a -> CString -> ImGuiSliderFlags -> m Bool
sliderScalar labelPtr dataType dataPtr minPtr maxPtr formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    SliderScalar(
      $(char* labelPtr),
      $(ImGuiDataType dataType),
      $(void* dataPtr_),
      $(void* minPtr_),
      $(void* maxPtr_),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]
  where
    dataPtr_ = castPtr dataPtr
    minPtr_ = castPtr minPtr
    maxPtr_ = castPtr maxPtr

-- | Wraps @ImGui::SliderScalarN()@
sliderScalarN :: (MonadIO m) => CString -> ImGuiDataType -> Ptr a -> CInt -> Ptr a -> Ptr a -> CString -> ImGuiSliderFlags -> m Bool
sliderScalarN labelPtr dataType dataPtr components minPtr maxPtr formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    SliderScalarN(
      $(char* labelPtr),
      $(ImGuiDataType dataType),
      $(void* dataPtr_),
      $(int components),
      $(void* minPtr_),
      $(void* maxPtr_),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]
  where
    dataPtr_ = castPtr dataPtr
    minPtr_ = castPtr minPtr
    maxPtr_ = castPtr maxPtr

-- | Wraps @ImGui::VSliderFloat()@
vSliderFloat :: (MonadIO m) => CString -> Ptr ImVec2 -> Ptr CFloat -> CFloat -> CFloat -> CString -> ImGuiSliderFlags -> m Bool
vSliderFloat labelPtr sizePtr vPtr vMin vMax formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    VSliderFloat(
      $(char* labelPtr),
      *$(ImVec2* sizePtr),
      $(float* vPtr),
      $(float vMin),
      $(float vMax),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]

-- | Wraps @ImGui::VSliderFloat()@
vSliderInt :: (MonadIO m) => CString -> Ptr ImVec2 -> Ptr CInt -> CInt -> CInt -> CString -> ImGuiSliderFlags -> m Bool
vSliderInt labelPtr sizePtr vPtr vMin vMax formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    VSliderInt(
      $(char* labelPtr),
      *$(ImVec2* sizePtr),
      $(int* vPtr),
      $(int vMin),
      $(int vMax),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]

-- | Wraps @ImGui::VSliderScalar()@
vSliderScalar :: (MonadIO m) => CString -> Ptr ImVec2 -> ImGuiDataType -> Ptr a -> Ptr a -> Ptr a -> CString -> ImGuiSliderFlags -> m Bool
vSliderScalar labelPtr sizePtr dataType dataPtr minPtr maxPtr formatPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool {
    VSliderScalar(
      $(char* labelPtr),
      *$(ImVec2* sizePtr),
      $(ImGuiDataType dataType),
      $(void* dataPtr_),
      $(void* minPtr_),
      $(void* maxPtr_),
      $(char* formatPtr),
      $(ImGuiSliderFlags flags)
    )
  } |]
  where
    dataPtr_ = castPtr dataPtr
    minPtr_ = castPtr minPtr
    maxPtr_ = castPtr maxPtr


-- | Wraps @ImGui::InputText()@.
inputText :: (MonadIO m) => CString -> CStringLen -> ImGuiInputTextFlags -> m Bool
inputText labelPtr (bufPtr, fromIntegral -> bufSize) flags = liftIO do
  (0 /= ) <$> [C.exp|
    bool {
      InputText(
        $(char* labelPtr),
        $(char* bufPtr),
        $(int bufSize),
        $(ImGuiInputTextFlags flags)
      )
    }
  |]


inputText2 :: (MonadIO m) => CString -> CStringLen -> ImGuiInputTextFlags -> m [Int]
inputText2 labelPtr (bufPtr, fromIntegral -> bufSize) flags = liftIO do
  alloca $ \(markPtr :: (Ptr (Ptr Int32))) -> do
    [C.block|
      void {
        static int32_t result[2];
        result[0] = 0;
        result[1] = 0;
        *$(int32_t * * markPtr) = result;

        struct Funcs
        {
            static int MyCallback(ImGuiInputTextCallbackData* data)
            {
                if (data->EventFlag == ImGuiInputTextFlags_CallbackAlways)
                {
                  result[0] = data->SelectionStart;
                  result[1] = data->SelectionEnd;
                }
                return 0;
            }
        };

        InputText(
          $(char* labelPtr),
          $(char* bufPtr),
          $(int bufSize),
          $(ImGuiInputTextFlags flags),
          Funcs::MyCallback
        );
      }
    |]
    a <- peek markPtr >>= peekArray 2
    return $ map fromIntegral a


-- | Wraps @ImGui::InputTextMultiline()@.
inputTextMultiline :: (MonadIO m) => CString -> CStringLen -> Ptr ImVec2 -> ImGuiInputTextFlags -> m Bool
inputTextMultiline labelPtr (bufPtr, fromIntegral -> bufSize) sizePtr flags = liftIO do
  (0 /= ) <$> [C.exp|
    bool {
      InputTextMultiline(
        $(char* labelPtr),
        $(char* bufPtr),
        $(size_t bufSize),
        *$(ImVec2* sizePtr),
        $(ImGuiInputTextFlags flags)
      )
    }
  |]

-- | Wraps @ImGui::InputTextWithHint()@.
inputTextWithHint :: (MonadIO m) => CString -> CString -> CStringLen -> ImGuiInputTextFlags -> m Bool
inputTextWithHint labelPtr hintPtr (bufPtr, fromIntegral -> bufSize) flags = liftIO do
  (0 /= ) <$> [C.exp|
    bool {
      InputTextWithHint(
        $(char* labelPtr),
        $(char* hintPtr),
        $(char* bufPtr),
        $(int bufSize),
        $(ImGuiInputTextFlags flags)
      )
    }
  |]


-- | Wraps @ImGui::ColorPicker3()@.
colorPicker3 :: (MonadIO m) => CString -> Ptr CFloat -> m Bool
colorPicker3 descPtr refPtr = liftIO do
  (0 /= ) <$> [C.exp| bool { ColorPicker3( $(char* descPtr), $(float* refPtr) ) } |]


colorEdit4 :: (MonadIO m) => CString -> Ptr CFloat -> m Bool
colorEdit4 descPtr refPtr = liftIO do
  (0 /= ) <$> [C.exp| bool { ColorEdit4( $(char* descPtr), $(float* refPtr), ImGuiColorEditFlags_Float | ImGuiColorEditFlags_NoInputs) } |]


-- | Display a color square/button, hover for details, return true when pressed.
--
-- Wraps @ImGui::ColorButton()@.
colorButton :: (MonadIO m) => CString -> Ptr ImVec4 -> m Bool
colorButton descPtr refPtr = liftIO do
  (0 /=) <$> [C.exp| bool { ColorButton( $(char* descPtr), *$(ImVec4* refPtr) ) } |]


-- | Wraps @ImGui::BeginTable()@.
beginTable :: MonadIO m => CString -> CInt -> ImGuiTableFlags -> Ptr ImVec2 -> CFloat -> m Bool
beginTable labelPtr column flags outerSizePtr innerWidth = liftIO do
  (0 /=) <$> [C.exp| bool { BeginTable($(char* labelPtr), $(int column), $(ImGuiTableFlags flags), *$(ImVec2* outerSizePtr), $(float innerWidth)) } |]

-- | Only call 'endTable' if 'beginTable' returns true!
--
-- Wraps @ImGui::EndTable()@.
endTable :: MonadIO m => m ()
endTable = liftIO do
  [C.exp| void { EndTable() } |]

-- | Wraps @ImGui::TableNextRow()@.
--   append into the first cell of a new row.
tableNextRow :: MonadIO m => ImGuiTableRowFlags -> CFloat -> m ()
tableNextRow flags minRowHeight = liftIO do
  [C.exp| void { TableNextRow($(ImGuiTableRowFlags flags), $(float minRowHeight)) } |]

-- | Wraps @ImGui::TableNextColumn()@.
--   append into the next column (or first column of next row if currently in
--   last column). Return true when column is visible.
tableNextColumn :: MonadIO m => m Bool
tableNextColumn = liftIO do
  (0 /=) <$> [C.exp| bool { TableNextColumn() } |]

-- | Wraps @ImGui::TableSetColumnIndex()@.
--   append into the specified column. Return true when column is visible.
tableSetColumnIndex :: MonadIO m => CInt -> m Bool
tableSetColumnIndex column= liftIO do
  (0 /=) <$> [C.exp| bool { TableSetColumnIndex($(int column)) } |]

-- | Wraps @ImGui::TableSetupColumn()@.
tableSetupColumn :: MonadIO m => CString -> ImGuiTableColumnFlags -> CFloat -> ImGuiID-> m ()
tableSetupColumn labelPtr flags initWidthOrWeight userId = liftIO do
  [C.exp| void { TableSetupColumn($(char* labelPtr), $(ImGuiTableColumnFlags flags), $(float initWidthOrWeight), $(ImGuiID userId)) } |]

-- | Wraps @ImGui::TableSetupScrollFreeze()@.
tableSetupScrollFreeze :: MonadIO m => CInt -> CInt -> m ()
tableSetupScrollFreeze cols rows = liftIO do
  [C.exp| void { TableSetupScrollFreeze($(int cols), $(int rows)) } |]

-- | Wraps @ImGui::TableHeadersRow()@.
--   submit all headers cells based on data provided to 'tableSetupColumn'
--   + submit context menu
tableHeadersRow :: MonadIO m => m ()
tableHeadersRow = liftIO do
  [C.exp| void { TableHeadersRow() } |]

-- | Wraps @ImGui::TableHeader()@.
--   submit one header cell manually (rarely used)
tableHeader :: MonadIO m => CString -> m ()
tableHeader labelPtr = liftIO do
  [C.exp| void { TableHeader($(char* labelPtr)) } |]

-- | Wraps @ImGui::TableGetSortSpecs()@.
--   Low-level-Function. Better use the wrapper that outomatically conform
--   to the things described below
--
--   Tables: Sorting
--   - Call TableGetSortSpecs() to retrieve latest sort specs for the table.
--     NULL when not sorting.
--   - When 'SpecsDirty == true' you should sort your data. It will be true when
--     sorting specs have changed since last call, or the first time. Make sure
--     to set 'SpecsDirty = false' after sorting, else you may wastefully sort
--     your data every frame!
--   - Lifetime: don't hold on this pointer over multiple frames or past any
--     subsequent call to BeginTable().
tableGetSortSpecs :: MonadIO m => m (Maybe (Ptr ImGuiTableSortSpecs))
tableGetSortSpecs = liftIO do
  ptr <- [C.exp| ImGuiTableSortSpecs* { TableGetSortSpecs() } |]
  if ptr == nullPtr then
    return Nothing
  else
    return $ Just ptr

tableClearSortSpecsDirty :: MonadIO m => Ptr ImGuiTableSortSpecs -> m ()
tableClearSortSpecsDirty specsPtr = liftIO do
  [C.block| void {
    $(ImGuiTableSortSpecs* specsPtr)->SpecsDirty = false;
  } |]

-- | Wraps @ImGui::TableGetColumnCount()@.
tableGetColumnCount :: MonadIO m => m CInt
tableGetColumnCount = liftIO do
  [C.exp| int { TableGetColumnCount() } |]

-- | Wraps @ImGui::TableGetColumnIndex()@.
tableGetColumnIndex :: MonadIO m => m CInt
tableGetColumnIndex = liftIO do
  [C.exp| int { TableGetColumnIndex() } |]

-- | Wraps @ImGui::TableGetRowIndex()@.
tableGetRowIndex :: MonadIO m => m CInt
tableGetRowIndex = liftIO do
  [C.exp| int { TableGetRowIndex() } |]

-- | Wraps @ImGui::TableGetColumnName
--   'Nothing' returns the current column name
tableGetColumnName :: MonadIO m => Maybe CInt -> m CString
tableGetColumnName Nothing = tableGetColumnName (Just (-1))
tableGetColumnName (Just column_n) = liftIO do
  [C.exp| const char* { TableGetColumnName($(int column_n)) } |]

-- | Wraps @ImGui::TableGetRowIndex()@.
--   'Nothing' returns the current column flags
tableGetColumnFlags :: MonadIO m => Maybe CInt -> m ImGuiTableColumnFlags
tableGetColumnFlags Nothing = tableGetColumnFlags (Just (-1))
tableGetColumnFlags (Just column_n) = liftIO do
  [C.exp| ImGuiTableColumnFlags { TableGetColumnFlags($(int column_n)) } |]

-- | Wraps @ImGui::TableSetColumnEnabled()@.
tableSetColumnEnabled :: MonadIO m => CInt -> CBool -> m ()
tableSetColumnEnabled column_n v = liftIO do
  [C.exp| void { TableSetColumnEnabled($(int column_n), $(bool v)) } |]

-- | Wraps @ImGui::TableSetBgColor()@.
--   'Nothing' sets the current row/column color
tableSetBgColor :: MonadIO m => ImGuiTableBgTarget -> ImU32 -> Maybe CInt -> m ()
tableSetBgColor target color Nothing = tableSetBgColor target color (Just (-1))
tableSetBgColor target color (Just column_n) = liftIO do
  [C.exp| void { TableSetBgColor($(ImGuiTableBgTarget target), $(ImU32 color), $(int column_n)) } |]

-- | Wraps @ImGui::TreeNode()@.
treeNode :: (MonadIO m) => CString -> m Bool
treeNode labelPtr = liftIO do
  (0 /=) <$> [C.exp| bool { TreeNode($(char* labelPtr)) } |]

collapsingHeader :: (MonadIO m) => CString -> m Bool
collapsingHeader labelPtr = liftIO do
  (0 /=) <$> [C.exp| bool { CollapsingHeader($(char* labelPtr), ImGuiTreeNodeFlags_None) } |]
  

-- | Wraps @ImGui::TreePush()@.
treePush :: (MonadIO m) => CString -> m ()
treePush labelPtr = liftIO do
  [C.exp| void { TreePush($(char* labelPtr)) } |]


-- | Wraps @ImGui::TreePop()@.
treePop :: (MonadIO m) => m ()
treePop = liftIO do
  [C.exp| void { TreePop() } |]


-- -- | Wraps @ImGui::Selectable()@.
-- selectable :: (MonadIO m) => CString -> m Bool
-- selectable labelPtr = liftIO do
--   (0 /=) <$> [C.exp| bool { Selectable($(char* labelPtr)) } |]


-- | Wraps @ImGui::Selectable()@.
selectable :: (MonadIO m) => CString -> CBool -> ImGuiSelectableFlags -> Ptr ImVec2 -> m Bool
selectable labelPtr selected flags size = liftIO do
  (0 /=) <$> [C.exp| bool { Selectable($(char* labelPtr), $(bool selected), $(ImGuiSelectableFlags flags), *$(ImVec2 *size)) } |]


selectable2 :: (MonadIO m) => CString -> Ptr CBool -> m Bool
selectable2 labelPtr selected = liftIO do
  (0 /=) <$> [C.exp| bool { Selectable($(char* labelPtr), $(bool* selected)) } |]



-- | Wraps @ImGui::ListBox()@.
listBox :: (MonadIO m) => CString -> Ptr CInt -> Ptr CString -> CInt -> m Bool
listBox labelPtr iPtr itemsPtr itemsLen = liftIO do
  (0 /=) <$> [C.exp| bool { ListBox($(char* labelPtr), $(int* iPtr), $(char** itemsPtr), $(int itemsLen)) }|]


-- | Wraps @ImGui::PlotHistogram()@.
plotHistogram :: (MonadIO m) => CString -> Ptr CFloat -> CInt -> m ()
plotHistogram labelPtr valuesPtr valuesLen = liftIO do
  [C.exp| void { PlotHistogram($(char* labelPtr), $(float* valuesPtr), $(int valuesLen)) } |]


-- | Append to menu-bar of current window (requires 'ImGuiWindowFlagsMenuBar'
-- flag set on parent window).
--
-- Wraps @ImGui::BeginMenuBar()@.
beginMenuBar :: (MonadIO m) => m Bool
beginMenuBar = liftIO do
  (0 /=) <$> [C.exp| bool { BeginMenuBar() } |]


-- | Only call 'endMenuBar' if 'beginMenuBar' returns true!
--
-- Wraps @ImGui::EndMenuBar()@.
endMenuBar :: (MonadIO m) => m ()
endMenuBar = liftIO do
  [C.exp| void { EndMenuBar(); } |]


-- | Create and append to a full screen menu-bar.
--
-- Wraps @ImGui::BeginMainMenuBar()@.
beginMainMenuBar :: (MonadIO m) => m Bool
beginMainMenuBar = liftIO do
  (0 /=) <$> [C.exp| bool { BeginMainMenuBar() } |]


-- | Only call 'endMainMenuBar' if 'beginMainMenuBar' returns true!
--
-- Wraps @ImGui::EndMainMenuBar()@.
endMainMenuBar :: (MonadIO m) => m ()
endMainMenuBar = liftIO do
  [C.exp| void { EndMainMenuBar(); } |]


-- | Create a sub-menu entry.
--
-- Wraps @ImGui::BeginMenu()@.
beginMenu :: (MonadIO m) => CString -> m Bool
beginMenu labelPtr = liftIO do
  (0 /=) <$> [C.exp| bool { BeginMenu($(char* labelPtr)) } |]


-- | Only call 'endMenu' if 'beginMenu' returns true!
--
-- Wraps @ImGui::EndMenu()@.
endMenu :: (MonadIO m) => m ()
endMenu = liftIO do
  [C.exp| void { EndMenu(); } |]


-- | Return true when activated. Shortcuts are displayed for convenience but not
-- processed by ImGui at the moment
--
-- Wraps @ImGui::MenuItem()@
menuItem :: (MonadIO m) => CString -> m Bool
menuItem labelPtr = liftIO do
  (0 /=) <$> [C.exp| bool { MenuItem($(char* labelPtr)) } |]


menuItem2 :: (MonadIO m) => CString -> Ptr CBool -> m Bool
menuItem2 labelPtr refPtr = liftIO do
  (0 /=) <$> [C.exp| bool { MenuItem($(char* labelPtr), NULL, *$(bool* refPtr)) } |]


-- | Create a @TabBar@ and start appending to it.
--
-- Wraps @ImGui::BeginTabBar@.
beginTabBar :: (MonadIO m) => CString -> ImGuiTabBarFlags -> m Bool
beginTabBar tabBarID flags = liftIO do
  (0 /=) <$> [C.exp| bool { BeginTabBar($(char* tabBarID), $(ImGuiTabBarFlags flags) ) } |]


-- | Finish appending elements to a tab bar. Only call if 'beginTabBar' returns @True@.
--
-- Wraps @ImGui::EndTabBar@.
endTabBar :: (MonadIO m) => m ()
endTabBar = liftIO do
  [C.exp| void { EndTabBar(); } |]


-- | Create a new tab. Returns @True@ if the tab is selected.
--
-- Wraps @ImGui::BeginTabItem@.
beginTabItem :: (MonadIO m) => CString -> Ptr CBool -> ImGuiTabBarFlags -> m Bool
beginTabItem namePtr refPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool { BeginTabItem($(char* namePtr), $(bool* refPtr), $(ImGuiTabBarFlags flags) ) } |]


beginTabItem2 :: (MonadIO m) => CString -> m Bool
beginTabItem2 namePtr = liftIO do
  (0 /=) <$> [C.exp| bool { BeginTabItem($(char* namePtr)) } |]


-- | Finish appending elements to a tab. Only call if 'beginTabItem' returns @True@.
--
-- Wraps @ImGui::EndTabItem@.
endTabItem :: (MonadIO m) => m ()
endTabItem = liftIO do
  [C.exp| void { EndTabItem(); } |]


-- | Create a tab that behaves like a button. Returns @True@ when clicked. Cannot be selected in the tab bar.
--
-- Wraps @ImGui.TabItemButton@.
tabItemButton :: (MonadIO m) => CString -> ImGuiTabItemFlags -> m Bool
tabItemButton namePtr flags = liftIO do
  (0 /=) <$> [C.exp| bool { TabItemButton($(char* namePtr), $(ImGuiTabItemFlags flags) ) } |]


-- | Notify the tab bar (or the docking system) that a tab/window is about to close.
-- Useful to reduce visual flicker on reorderable tab bars.
--
-- __For tab-bar__: call after 'beginTabBar' and before tab submission. Otherwise, call with a window name.
setTabItemClosed :: (MonadIO m) => CString -> m ()
setTabItemClosed namePtr = liftIO do
  [C.exp| void { SetTabItemClosed($(char* namePtr)); } |]


-- | Begin/append a tooltip window to create full-featured tooltip (with any
-- kind of items).
--
-- Wraps @ImGui::BeginTooltip()@
beginTooltip :: (MonadIO m) => m ()
beginTooltip = liftIO do
  [C.exp| void { BeginTooltip() } |]


-- | Wraps @ImGui::EndTooltip()@
endTooltip :: (MonadIO m) => m ()
endTooltip = liftIO do
  [C.exp| void { EndTooltip() } |]


-- | Returns 'True' if the popup is open, and you can start outputting to it.
--
-- Wraps @ImGui::BeginPopup()@
beginPopup :: (MonadIO m) => CString -> m Bool
beginPopup popupIdPtr = liftIO do
  (0 /=) <$> [C.exp| bool { BeginPopup($(char* popupIdPtr)) } |]


-- | Returns 'True' if the modal is open, and you can start outputting to it.
--
-- Wraps @ImGui::BeginPopupModal()@
beginPopupModal :: (MonadIO m) => CString -> m Bool
beginPopupModal popupIdPtr = liftIO do
  (0 /=) <$> [C.exp| bool { BeginPopupModal($(char* popupIdPtr)) } |]


-- | Only call 'endPopup' if 'beginPopup' or 'beginPopupModal' returns 'True'!
--
-- Wraps @ImGui::BeginPopupModal()@
endPopup :: (MonadIO m) => m ()
endPopup = liftIO do
  [C.exp| void { EndPopup() } |]


-- | Call to mark popup as open (don't call every frame!).
--
-- Wraps @ImGui::OpenPopup()@
openPopup :: (MonadIO m) => CString -> m ()
openPopup popupIdPtr = liftIO do
  [C.exp| void { OpenPopup($(char* popupIdPtr)) } |]


-- | Open popup when clicked on last item.
--
-- Note: actually triggers on the mouse _released_ event to be consistent with popup behaviors.
--
-- Wraps @ImGui::OpenPopupOnItemClick()@
openPopupOnItemClick :: (MonadIO m) => CString -> ImGuiPopupFlags-> m ()
openPopupOnItemClick popupIdPtr flags = liftIO do
  [C.exp| void { OpenPopupOnItemClick($(char* popupIdPtr), $(ImGuiPopupFlags flags)) } |]


-- | Manually close the popup we have begin-ed into.
--
-- Wraps @ImGui::ClosePopup()@
closeCurrentPopup :: (MonadIO m) => m ()
closeCurrentPopup = liftIO do
  [C.exp| void { CloseCurrentPopup() } |]

-- | Open+begin popup when clicked on last item.
--
-- Use str_id==NULL to associate the popup to previous item.
--
-- If you want to use that on a non-interactive item such as 'text' you need to pass in an explicit ID here.
beginPopupContextItem :: (MonadIO m) => CString -> ImGuiPopupFlags-> m Bool
beginPopupContextItem popupIdPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool { BeginPopupContextItem($(char* popupIdPtr), $(ImGuiPopupFlags flags)) } |]

-- | Open+begin popup when clicked on current window.
beginPopupContextWindow :: (MonadIO m) => CString -> ImGuiPopupFlags-> m Bool
beginPopupContextWindow popupIdPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool { BeginPopupContextWindow($(char* popupIdPtr), $(ImGuiPopupFlags flags)) } |]

-- | Open+begin popup when clicked in void (where there are no windows).
beginPopupContextVoid :: (MonadIO m) => CString -> ImGuiPopupFlags-> m Bool
beginPopupContextVoid popupIdPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool { BeginPopupContextVoid($(char* popupIdPtr), $(ImGuiPopupFlags flags)) } |]

-- | Query popup status
--
-- - return 'True' if the popup is open at the current 'beginPopup' level of the popup stack.
-- - with 'ImGuiPopupFlags_AnyPopupId': return 'True' if any popup is open at the current 'beginPopup' level of the popup stack.
-- - with 'ImGuiPopupFlags_AnyPopupId' | 'ImGuiPopupFlags_AnyPopupLevel': return 'True' if any popup is open.
--
-- Wraps @ImGui::IsPopupOpen()@
isPopupOpen :: (MonadIO m) => CString -> ImGuiPopupFlags-> m Bool
isPopupOpen popupIdPtr flags = liftIO do
  (0 /=) <$> [C.exp| bool { IsPopupOpen($(char* popupIdPtr), $(ImGuiPopupFlags flags)) } |]


-- | Is the last item hovered? (and usable, aka not blocked by a popup, etc.).
--
-- Wraps @ImGui::IsItemHovered()@
isItemHovered :: (MonadIO m) => m Bool
isItemHovered = liftIO do
  (0 /=) <$> [C.exp| bool { IsItemHovered() } |]


isItemActive :: (MonadIO m) => m Bool
isItemActive = liftIO do
  (0 /=) <$> [C.exp| bool { IsItemActive() } |]


-- | Get draw list associated to the current window.
getWindowDrawList :: (MonadIO m) => m DrawList
getWindowDrawList = liftIO do
  DrawList <$> [C.exp|
    ImDrawList* {
      GetWindowDrawList()
    }
  |]

-- | Get current window position in screen space.
--
-- Useful if you want to do your own drawing via the "DrawList" API.
getWindowPos :: (MonadIO m) => m ImVec2
getWindowPos = liftIO do
  C.withPtr_ \ptr ->
    [C.block|
      void {
        *$(ImVec2 * ptr) = GetWindowPos();
      }
    |]

getWindowSize :: (MonadIO m) => m ImVec2
getWindowSize = liftIO do
  C.withPtr_ \ptr ->
    [C.block|
      void {
        *$(ImVec2 * ptr) = GetWindowSize();
      }
    |]


getDisplaySize :: (MonadIO m) => m ImVec2
getDisplaySize = liftIO do
  C.withPtr_ \ptr ->
    [C.block|
      void {
        ImGuiIO& io = ImGui::GetIO();
        *$(ImVec2 * ptr) = ImVec2(io.DisplaySize.x, io.DisplaySize.y);
      }
    |]


getWindowWidth :: (MonadIO m) => m CFloat
getWindowWidth = liftIO do
  [C.exp| float { GetWindowWidth() } |]

getWindowHeight :: (MonadIO m) => m CFloat
getWindowHeight = liftIO do
  [C.exp| float { GetWindowHeight() } |]

-- | Set next window position. Call before `begin` Use pivot=(0.5,0.5) to center on given point, etc.
--
-- Wraps @ImGui::SetNextWindowPos()@
setNextWindowPos :: (MonadIO m) => Ptr ImVec2 -> ImGuiCond -> Maybe (Ptr ImVec2) -> m ()
setNextWindowPos posPtr cond (Just pivotPtr) = liftIO do
  [C.exp| void { SetNextWindowPos(*$(ImVec2* posPtr), $(ImGuiCond cond), *$(ImVec2* pivotPtr)) } |]
setNextWindowPos posPtr cond Nothing = liftIO do
  [C.exp| void { SetNextWindowPos(*$(ImVec2* posPtr), $(ImGuiCond cond)) } |]


-- | Set next window size. Call before `begin`
--
-- Wraps @ImGui::SetNextWindowSize()@
setNextWindowSize :: (MonadIO m) => Ptr ImVec2 -> ImGuiCond -> m ()
setNextWindowSize sizePtr cond = liftIO do
  [C.exp| void { SetNextWindowSize(*$(ImVec2* sizePtr), $(ImGuiCond cond)) } |]


-- | Set next window size and position to match current display size.
--
-- Call before `begin`.
--
-- Wraps @ImGui::SetNextWindowPos()@, @ImGui::SetNextWindowSize()@
setNextWindowFullscreen :: (MonadIO m) => m ()
setNextWindowFullscreen = liftIO
  [C.block|
    void {
      SetNextWindowPos(ImVec2(0, 0));
      SetNextWindowSize(GetIO().DisplaySize);
    }
  |]

-- | Set next window content size (~ scrollable client area, which enforce the range of scrollbars). Not including window decorations (title bar, menu bar, etc.) nor WindowPadding. call before `begin`
--
-- Wraps @ImGui::SetNextWindowContentSize()@
setNextWindowContentSize :: (MonadIO m) => Ptr ImVec2 -> m ()
setNextWindowContentSize sizePtr = liftIO do
  [C.exp| void { SetNextWindowContentSize(*$(ImVec2* sizePtr)) } |]


-- | Set next window size limits. use -1,-1 on either X/Y axis to preserve the current size. Sizes will be rounded down.
--
-- Wraps @ImGui::SetNextWindowContentSize()@
setNextWindowSizeConstraints :: (MonadIO m) => Ptr ImVec2 -> Ptr ImVec2 -> m ()
setNextWindowSizeConstraints sizeMinPtr sizeMaxPtr = liftIO do
  [C.exp| void { SetNextWindowSizeConstraints(*$(ImVec2* sizeMinPtr), *$(ImVec2* sizeMaxPtr)) } |]


-- | Set next window collapsed state. call before `begin`
--
-- Wraps @ImGui::SetNextWindowCollapsed()@
setNextWindowCollapsed :: (MonadIO m) => CBool -> ImGuiCond -> m ()
setNextWindowCollapsed b cond = liftIO do
  [C.exp| void { SetNextWindowCollapsed($(bool b), $(ImGuiCond cond)) } |]


-- | Set next window background color alpha. helper to easily override the Alpha component of `ImGuiCol_WindowBg`, `ChildBg`, `PopupBg`. you may also use `ImGuiWindowFlags_NoBackground`.
--
-- Wraps @ImGui::SetNextWindowBgAlpha()@
setNextWindowBgAlpha :: (MonadIO m) => CFloat -> m ()
setNextWindowBgAlpha alpha = liftIO do
  [C.exp| void { SetNextWindowBgAlpha($(float alpha)) } |]


-- | undo a sameLine or force a new line when in an horizontal-layout context.
--
-- Wraps @ImGui::NewLine()@
newLine :: (MonadIO m) => m ()
newLine = liftIO do
  [C.exp| void { NewLine() } |]


-- | Add vertical spacing.
--
-- Wraps @ImGui::Spacing()@
spacing :: (MonadIO m) => m ()
spacing = liftIO do
  [C.exp| void { Spacing() } |]


-- | Add a dummy item of given size. unlike `invisibleButton`, `dummy` won't take the mouse click or be navigable into.
--
-- Wraps @ImGui::Dummy()@
dummy :: (MonadIO m) => Ptr ImVec2 -> m ()
dummy sizePtr = liftIO do
  [C.exp| void { Dummy(*$(ImVec2* sizePtr)) } |]


-- | Move content position toward the right, by indent_w, or style.IndentSpacing if indent_w <= 0
--
-- Wraps @ImGui::Indent()@
indent :: (MonadIO m) => CFloat -> m ()
indent indent_w = liftIO do
  [C.exp| void { Indent($(float indent_w)) } |]


-- | Move content position back to the left, by indent_w, or style.IndentSpacing if indent_w <= 0
--
-- Wraps @ImGui::Unindent()@
unindent :: (MonadIO m) => CFloat -> m ()
unindent indent_w = liftIO do
  [C.exp| void { Unindent($(float indent_w)) } |]


-- | Affect large frame+labels widgets only.
--
-- Wraps @ImGui::SetNextItemWidth()@
setNextItemWidth :: (MonadIO m) => CFloat -> m ()
setNextItemWidth itemWidth = liftIO do
  [C.exp| void { SetNextItemWidth($(float itemWidth)) } |]


setNextItemOpen :: (MonadIO m) => Bool -> m ()
setNextItemOpen on = liftIO do
  let my = bool 0 1 on
      c'my = fromIntegral my
  [C.exp| void { SetNextItemOpen($(int c'my)) } |]


-- Wraps @ImGui::PushItemWidth()@
pushItemWidth :: (MonadIO m) => CFloat -> m ()
pushItemWidth itemWidth = liftIO do
  [C.exp| void { PushItemWidth($(float itemWidth)) } |]


-- Wraps @ImGui::PopItemWidth()@
popItemWidth :: (MonadIO m) => m ()
popItemWidth = liftIO do
  [C.exp| void { PopItemWidth() } |]


-- | lock horizontal starting position
--
--  Wraps @ImGui::BeginGroup()@
beginGroup :: (MonadIO m) => m ()
beginGroup = liftIO do
  [C.exp| void { BeginGroup() } |]


-- | unlock horizontal starting position + capture the whole group bounding box into one "item" (so you can use `isItemHovered` or layout primitives such as `sameLine` on whole group, etc.)
--
-- Wraps @ImGui::EndGroup()@
endGroup :: (MonadIO m) => m ()
endGroup = liftIO do
  [C.exp| void { EndGroup() } |]


-- | Vertically align upcoming text baseline to FramePadding.y so that it will align properly to regularly framed items (call if you have text on a line before a framed item)
--
-- Wraps @ImGui::AlignTextToFramePadding()@
alignTextToFramePadding :: (MonadIO m) => m ()
alignTextToFramePadding = liftIO do
  [C.exp| void { AlignTextToFramePadding() } |]


-- | Set cursor position in window-local coordinates
--
-- Wraps @ImGui::SetCursorPos()@
setCursorPos :: (MonadIO m) => Ptr ImVec2 -> m ()
setCursorPos posPtr = liftIO do
  [C.exp| void { SetCursorPos(*$(ImVec2* posPtr)) } |]

-- | Cursor position in absolute coordinates.
--
-- Useful to work with 'DrawList' API.
--
-- Generally top-left == @GetMainViewport()->Pos == (0,0)@ in single viewport mode,
-- and bottom-right == @GetMainViewport()->Pos+Size == io.DisplaySize@ in single-viewport mode.
getCursorScreenPos :: (MonadIO m) => m ImVec2
getCursorScreenPos = liftIO do
  C.withPtr_ \ptr ->
    [C.block|
      void {
        *$(ImVec2 * ptr) = GetCursorScreenPos();
      }
    |]


-- | Modify a style color by pushing to the shared stack. always use this if you modify the style after `newFrame`
--
-- Wraps @ImGui::PushStyleColor()@
pushStyleColor :: (MonadIO m) => ImGuiCol -> Ptr ImVec4 -> m ()
pushStyleColor col colorPtr = liftIO do
  [C.exp| void { PushStyleColor($(ImGuiCol col), *$(ImVec4 *colorPtr)) } |]


-- | Remove style color modifications from the shared stack
--
-- Wraps @ImGui::PopStyleColor()@
popStyleColor :: (MonadIO m) => CInt -> m ()
popStyleColor n = liftIO do
  [C.exp| void { PopStyleColor($(int n)) } |]


-- | Modify a style variable by pushing to the shared stack. always use this if you modify the style after `newFrame`
--
-- Wraps @ImGui::PushStyleVar()@
pushStyleVar :: (MonadIO m) => ImGuiStyleVar -> Ptr ImVec2 -> m ()
pushStyleVar style valPtr = liftIO do
  [C.exp| void { PushStyleVar($(ImGuiStyleVar style), *$(ImVec2* valPtr)) } |]


-- | Remove style variable modifications from the shared stack
--
-- Wraps @ImGui::PopStyleVar()@
popStyleVar :: (MonadIO m) => CInt -> m ()
popStyleVar n = liftIO do
  [C.exp| void { PopStyleVar($(int n)) } |]


-- | Push integer into the ID stack (will hash int).
--
-- Wraps @ImGui::PushId@
pushIDInt :: (MonadIO m) => CInt -> m ()
pushIDInt intId = liftIO do
  [C.exp| void { PushID($(int intId)) } |]

-- | Push pointer into the ID stack (will hash pointer).
--
-- Wraps @ImGui::PushId@
pushIDPtr :: (MonadIO m) => Ptr a -> m ()
pushIDPtr ptr = liftIO do
  [C.exp| void { PushID($(void * ptr_)) } |]
  where
    ptr_ = castPtr ptr

-- | Push string into the ID stack (will hash string).
--
-- Wraps @ImGui::PushId@
pushIDStr :: (MonadIO m) => CString -> m ()
pushIDStr strId = liftIO do
  [C.exp| void { PushID($(char * strId)) } |]

-- | Push string into the ID stack (will hash string).
--
-- Wraps @ImGui::PushId@
pushIDStrLen :: (MonadIO m) => CStringLen -> m ()
pushIDStrLen (strBegin, strLen) = liftIO do
  [C.exp| void { PushID($(char * strBegin), $(char * strEnd)) } |]
  where
    strEnd = plusPtr strBegin strLen

popID :: (MonadIO m) => m ()
popID = liftIO do
  [C.exp| void { PopID() } |]

getFPS :: MonadIO m => m Double
getFPS = liftIO do
  realToFrac <$> [C.exp| double { GetIO().Framerate } |]

myHelpMarker :: (MonadIO m) => CString -> Int -> m ()
myHelpMarker msg flag = liftIO do
  let c'flag = fromIntegral flag
  [C.block| void {
     switch ($(int c'flag)) {
       case 0:
         ImGui::TextDisabled("  ");
         break;

       case 2:
         ImGui::TextDisabled("(?)");
         break;

       default:
         break;
     }
     
     if (ImGui::IsItemHovered())
     {
        ImGui::BeginTooltip();
        ImGui::PushTextWrapPos(ImGui::GetFontSize() * 35.0f);
        ImGui::TextUnformatted($(char * msg));
        ImGui::PopTextWrapPos();
        ImGui::EndTooltip();
     }}|]


myColorButton :: (MonadIO m) => CString -> Int -> m Bool
myColorButton caption seq = liftIO do
  let c'seq = fromIntegral seq
      cIntToBool :: CInt -> Bool
      cIntToBool cint = cint /= 0
  cIntToBool <$> [C.block| int {
                   bool r;
                   ImGui::PushID($(int c'seq));
                   ImGui::PushStyleColor(ImGuiCol_Button, (ImVec4)ImColor::HSV($(int c'seq) / 7.0f, 0.6f, 0.6f));
                   ImGui::PushStyleColor(ImGuiCol_ButtonHovered, (ImVec4)ImColor::HSV($(int c'seq) / 7.0f, 0.7f, 0.7f));
                   ImGui::PushStyleColor(ImGuiCol_ButtonActive, (ImVec4)ImColor::HSV($(int c'seq) / 7.0f, 0.8f, 0.8f));
                   r = ImGui::Button($(char * caption));
                   ImGui::PopStyleColor(3);
                   ImGui::PopID();
                   return r;
                 }|]


showAppLog :: MonadIO m => String -> m ()
showAppLog msg = liftIO do
  withCString msg $ \msgPtr->
    [C.exp| void {

      struct ExampleAppLog
      {
          ImGuiTextBuffer     Buf;
          ImGuiTextFilter     Filter;
          ImVector<int>       LineOffsets; // Index to lines offset. We maintain this with AddLog() calls.
          bool                AutoScroll;  // Keep scrolling if already at the bottom.
      
          ExampleAppLog()
          {
              AutoScroll = true;
              Clear();
          }
      
          void    Clear()
          {
              Buf.clear();
              LineOffsets.clear();
              LineOffsets.push_back(0);
          }
      
          void    AddLog(const char* fmt, ...) IM_FMTARGS(2)
          {
              int old_size = Buf.size();
              va_list args;
              va_start(args, fmt);
              Buf.appendfv(fmt, args);
              va_end(args);
              for (int new_size = Buf.size(); old_size < new_size; old_size++)
                  if (Buf[old_size] == '\n')
                      LineOffsets.push_back(old_size + 1);
          }
      
          void    Draw(const char* title, bool* p_open = NULL)
          {
              if (!ImGui::Begin(title, p_open))
              {
                  ImGui::End();
                  return;
              }
      
              // Options menu
              if (ImGui::BeginPopup("选项"))
              {
                  ImGui::Checkbox("Auto-scroll", &AutoScroll);
                  ImGui::EndPopup();
              }
      
              // Main window
              if (ImGui::Button("选项"))
                  ImGui::OpenPopup("选项");
              ImGui::SameLine();
              bool clear = ImGui::Button("清除");
              ImGui::SameLine();
              bool copy = ImGui::Button("复制");
              ImGui::SameLine();
              Filter.Draw("过滤器", -100.0f);
      
              ImGui::Separator();
              ImGui::BeginChild("scrolling", ImVec2(0, 0), false, ImGuiWindowFlags_HorizontalScrollbar);
      
              if (clear)
                  Clear();
              if (copy)
                  ImGui::LogToClipboard();
      
              ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, 0));
              const char* buf = Buf.begin();
              const char* buf_end = Buf.end();
              if (Filter.IsActive())
              {
                  // In this example we don't use the clipper when Filter is enabled.
                  // This is because we don't have a random access on the result on our filter.
                  // A real application processing logs with ten of thousands of entries may want to store the result of
                  // search/filter.. especially if the filtering function is not trivial (e.g. reg-exp).
                  for (int line_no = 0; line_no < LineOffsets.Size; line_no++)
                  {
                      const char* line_start = buf + LineOffsets[line_no];
                      const char* line_end = (line_no + 1 < LineOffsets.Size) ? (buf + LineOffsets[line_no + 1] - 1) : buf_end;
                      if (Filter.PassFilter(line_start, line_end))
                          ImGui::TextUnformatted(line_start, line_end);
                  }
              }
              else
              {
                  // The simplest and easy way to display the entire buffer:
                  //   ImGui::TextUnformatted(buf_begin, buf_end);
                  // And it'll just work. TextUnformatted() has specialization for large blob of text and will fast-forward
                  // to skip non-visible lines. Here we instead demonstrate using the clipper to only process lines that are
                  // within the visible area.
                  // If you have tens of thousands of items and their processing cost is non-negligible, coarse clipping them
                  // on your side is recommended. Using ImGuiListClipper requires
                  // - A) random access into your data
                  // - B) items all being the  same height,
                  // both of which we can handle since we an array pointing to the beginning of each line of text.
                  // When using the filter (in the block of code above) we don't have random access into the data to display
                  // anymore, which is why we don't use the clipper. Storing or skimming through the search result would make
                  // it possible (and would be recommended if you want to search through tens of thousands of entries).
                  ImGuiListClipper clipper;
                  clipper.Begin(LineOffsets.Size);
                  while (clipper.Step())
                  {
                      for (int line_no = clipper.DisplayStart; line_no < clipper.DisplayEnd; line_no++)
                      {
                          const char* line_start = buf + LineOffsets[line_no];
                          const char* line_end = (line_no + 1 < LineOffsets.Size) ? (buf + LineOffsets[line_no + 1] - 1) : buf_end;
                          ImGui::TextUnformatted(line_start, line_end);
                      }
                  }
                  clipper.End();
              }
              ImGui::PopStyleVar();
      
              if (AutoScroll && ImGui::GetScrollY() >= ImGui::GetScrollMaxY())
                  ImGui::SetScrollHereY(1.0f);
      
              ImGui::EndChild();
              ImGui::End();
          }
      };

      static ExampleAppLog my_log;

      if(strlen($(char* msgPtr)) != 0) {
        my_log.AddLog("%s\n", $(char* msgPtr));
      }
      my_log.Draw("控制台");
    }|]

wantCaptureMouse :: MonadIO m => m Bool
wantCaptureMouse = liftIO do
  (0 /=) <$> [C.exp| bool { GetIO().WantCaptureMouse } |]

wantCaptureKeyboard :: MonadIO m => m Bool
wantCaptureKeyboard = liftIO do
  (0 /=) <$> [C.exp| bool { GetIO().WantCaptureKeyboard } |]

-- | This draw list will be the first rendering one.
--
-- Useful to quickly draw shapes/text behind dear imgui contents.
getBackgroundDrawList :: (MonadIO m) => m DrawList
getBackgroundDrawList = liftIO do
  DrawList <$> [C.exp|
    ImDrawList* {
      GetBackgroundDrawList()
    }
  |]

--  | This draw list will be the last rendered one.
--
-- Useful to quickly draw shapes/text over dear imgui contents.
getForegroundDrawList :: (MonadIO m) => m DrawList
getForegroundDrawList = liftIO do
  DrawList <$> [C.exp|
    ImDrawList* {
      GetForegroundDrawList()
    }
  |]

-- | Generate 32-bit encoded colors using DearImgui macros.
--
-- Follows @IMGUI_USE_BGRA_PACKED_COLOR@ define to put bytes in appropriate positions.
imCol32 :: CUChar -> CUChar -> CUChar -> CUChar -> ImU32
imCol32 r g b a = unsafePerformIO
  [C.exp|
    ImU32 {
      IM_COL32(
        $(unsigned char r),
        $(unsigned char g),
        $(unsigned char b),
        $(unsigned char a)
      )
    }
  |]


