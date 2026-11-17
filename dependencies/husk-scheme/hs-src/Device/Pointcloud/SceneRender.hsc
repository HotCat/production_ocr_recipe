
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# language BlockArguments #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}

module Device.Pointcloud.SceneRender (GLResources(..), initPointCloud, getPointCloudShader, updatePointCloud, renderPointCloud, findPlane, clipPointCloud, transformPointCloud, gizmoAlignToPlane, gizmoAlignToAxle, labelAlignPairwise, productAlignPairwise, syntheticAlign, setManuParams, directlyAlign, syncPointcloud, getMotionRevise) where

import DearImGui
import Data.Word
import Data.Char
import Data.Bits
import Foreign.C.Types
import Foreign.C.String
import qualified Language.C.Inline as C
import qualified Language.C.Inline.Unsafe as CU
import qualified Language.C.Inline.Cpp as C
import qualified Data.ByteString as B

import qualified OpenCV
import OpenCV.Core.Types
import OpenCV.Internal
import OpenCV.Internal.C.Inline ( openCvCtx )
import OpenCV.Internal.C.Types
import OpenCV.Internal.Core.ArrayOps
import OpenCV.Internal.Core.Types ( withArrayPtr, Scalar )
import OpenCV.Internal.Core.Types.Mat
import OpenCV.Internal.C.FinalizerTH
import OpenCV.Internal.Exception ( cvExcept, cvExceptU, unsafeWrapException, handleCvException, wrapException )
import OpenCV.TypeLevel

import Control.Monad
import Control.Exception
import Control.Monad.Error.Class ( MonadError )
import Control.Monad.IO.Class ( MonadIO, liftIO )
import Control.Concurrent
import Control.Concurrent.STM
import qualified Data.Text as T

import Foreign.ForeignPtr ( ForeignPtr, withForeignPtr, castForeignPtr )
import Foreign.Marshal.Array
import Foreign.Marshal.Alloc
import Foreign.Marshal.Utils (with)
import System.IO.Unsafe ( unsafePerformIO )
import Text.RawString.QQ

import Graphics.GL
import Data.IORef
import System.Exit (exitFailure)
import Foreign.Ptr
import Foreign.Storable
import Data.Vector.Storable (Vector)
import qualified Data.Vector.Storable as V
import Device.Pointcloud.Profilometry (Reconstruct)
import Linear

-- StateVar
import Data.StateVar
  ( HasGetter(get), HasSetter, ($=!) )


C.context openCvCtx

C.include "reconstruct.h"

C.using "namespace cv"
C.using "namespace std"

C.include "GL/glew.h"

C.verbatim [r|
typedef cv::Ptr<Reconstruct> Ptr_Reconstruct;
|]

data GLResources = GLResources {
  sceneVao      :: GLuint,
  sceneVbo      :: GLuint,
  shaderProgram :: GLuint,
  cloudType     :: String
}

debug :: Bool
debug = True

dumpError :: String -> IO ()
dumpError str = do
  when debug $ do
    code <- glGetError
    unless (code == 0) $ do
      print code
      putStrLn str
      -- exitFailure
      throwIO (userError str)


checkShaderLinking :: GLuint -> IO ()
checkShaderLinking shaderProgram = do
  alloca $ \successPtr -> do
    alloca $ \infoLogPtr -> do
      glGetProgramiv shaderProgram GL_LINK_STATUS successPtr
      success <- peek successPtr
      if success <= 0
        then do
          glGetProgramInfoLog shaderProgram 512 nullPtr infoLogPtr
          putStrLn =<< peekCString infoLogPtr
          exitFailure
        else do
          putStrLn "Successfully linked shader program"


checkShaderCompilation :: GLuint -> IO ()
checkShaderCompilation shader = do
  alloca $ \successPtr ->
    alloca $ \infoLogPtr -> do
      glGetShaderiv shader GL_COMPILE_STATUS successPtr
      success <- peek successPtr
      glGetShaderInfoLog shader 512 nullPtr infoLogPtr
      mapM_ print =<< lines <$> peekCString infoLogPtr
      when (success <= 0) $ do
        putStrLn "Failed to compile shader "
        exitFailure
      putStrLn "Compiled shader successfully"


createShaderProgram
  :: GLuint
  -> GLuint
  -> IO GLuint
createShaderProgram vertexShader fragmentShader = do
  shaderProgram <- glCreateProgram
  dumpError "create program"
  glAttachShader shaderProgram vertexShader
  dumpError "attach1"
  glAttachShader shaderProgram fragmentShader
  dumpError "attach2"
  glLinkProgram shaderProgram
  dumpError "linking"
  checkShaderLinking shaderProgram
  dumpError "check linking"
  glDeleteShader vertexShader
  dumpError "delete vert shader"
  glDeleteShader fragmentShader
  dumpError "delete frag shader"
  pure shaderProgram


compileShader :: GLuint -> String -> IO GLuint
compileShader shaderType shaderFile = do
  putStrLn $ "Compiling " <> shaderFile
  shader <- glCreateShader shaderType
  shaderSource' <- readFile shaderFile
  putStrLn shaderSource'
  withCString shaderSource' $ \shaderSource ->
    alloca $ \shadersStr -> do
      shadersStr `poke` shaderSource
      glShaderSource shader 1 shadersStr nullPtr
      glCompileShader shader
      checkShaderCompilation shader
  pure shader


makeShaderProgram :: String -> String -> IO GLuint
makeShaderProgram vertShaderFile fragShaderFile = do
  v <- compileShader GL_VERTEX_SHADER vertShaderFile
  dumpError "vert shader"
  f <- compileShader GL_FRAGMENT_SHADER fragShaderFile
  dumpError "frag shader"
  createShaderProgram v f


getPointCloudShader :: IO GLuint
getPointCloudShader = makeShaderProgram "vert2.glsl" "frag2.glsl"


createBuffers :: GLuint -> String -> IO GLResources
createBuffers shaderProgram cloud = do
  vaoRef <- newIORef 0
  vboRef <- newIORef 0
  alloca $ \vaoPtr -> do
    alloca $ \vboPtr -> do
      glGenVertexArrays 1 vaoPtr
      glGenBuffers 1 vboPtr
      vao <- peek vaoPtr
      vbo <- peek vboPtr

      glBindVertexArray vao
      glBindBuffer GL_ARRAY_BUFFER vbo
      glVertexAttribPointer 0 3 GL_FLOAT GL_FALSE (fromIntegral (7 * sizeOf (undefined :: Float))) nullPtr
      glEnableVertexAttribArray 0
      glVertexAttribPointer 1 4 GL_FLOAT GL_FALSE (fromIntegral (7 * sizeOf (undefined :: Float))) (nullPtr `plusPtr` (3 * sizeOf (undefined :: Float)))
      glEnableVertexAttribArray 1
      glBindBuffer GL_ARRAY_BUFFER 0
      glBindVertexArray 0
      return (GLResources vao vbo shaderProgram cloud)


-- Update the point cloud data in the VBO
updatePointCloud :: (MonadIO m, MonadError CvException m) => GLResources -> Reconstruct -> m ()
updatePointCloud glResources recon = wrapException $ liftIO $ do
  let vao = sceneVao glResources
      vbo = sceneVbo glResources
      cloud = case (cloudType glResources) of
        "label" -> 0
        "labeltemp" -> 2
        "product" -> 1
        "producttemp" -> 3
        "render" -> 4
        "convplane" -> 5
      c'cloud = fromIntegral cloud

  glBindVertexArray vao
  glBindBuffer GL_ARRAY_BUFFER vbo

  withPtr recon $ \reconPtr -> do
    handleCvException (pure ()) $
      [cvExcept|
         GLint size;
         glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, &size);
         std::cout << "buffer size(): " << size << std::endl;

         std::vector<float> data = (**$(Ptr_Reconstruct * reconPtr)).exportPC($(int c'cloud));
         std::cout << "data.size(): " << data.size() << std::endl;

         glBufferData(GL_ARRAY_BUFFER, data.size() * sizeof(float), data.data(), GL_STATIC_DRAW);

         glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, &size);
         std::cout << "buffer size2(): " << size << std::endl;
         glBindBuffer(GL_ARRAY_BUFFER, 0);
  
      |]


renderPointCloud :: (MonadIO m, MonadError CvException m) => GLResources -> (GLuint -> String -> IO ()) -> Double -> m ()
renderPointCloud glResources setupShader granularity = wrapException $ liftIO $ do
  let vao = sceneVao glResources
      vbo = sceneVbo glResources
      myShader = shaderProgram glResources
      cloud = cloudType glResources

  glUseProgram myShader
  glBindVertexArray vao
  glBindBuffer GL_ARRAY_BUFFER vbo

  setupShader myShader cloud
  glPointSize $ realToFrac granularity
  glActiveTexture GL_TEXTURE0

  handleCvException (pure ()) $
     [cvExcept|
        GLint size;
        glGetBufferParameteriv(GL_ARRAY_BUFFER, GL_BUFFER_SIZE, &size);
        glDrawArrays(GL_POINTS, 0, size/(sizeof(float)*7));
        glBindVertexArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
     |]


initPointCloud :: GLuint -> String -> IO GLResources
initPointCloud = createBuffers


findPlane :: (MonadIO m, MonadError CvException m) => Reconstruct -> m ()
findPlane recon = wrapException $ liftIO $ do
  withPtr recon $ \reconPtr -> do
    handleCvException (pure ()) $
      [cvExcept|
        (**$(Ptr_Reconstruct * reconPtr)).findPlane();
      |]


labelAlignPairwise :: (MonadIO m, MonadError CvException m) => Reconstruct -> m ()
labelAlignPairwise recon = wrapException $ liftIO $ do
  withPtr recon $ \reconPtr -> do
    handleCvException (pure ()) $ do
      [cvExcept|
        (**$(Ptr_Reconstruct * reconPtr)).labelAlign();
      |]


productAlignPairwise :: (MonadIO m, MonadError CvException m) => Reconstruct -> m ()
productAlignPairwise recon = wrapException $ liftIO $ do
  withPtr recon $ \reconPtr -> do
    handleCvException (pure ()) $ do
      [cvExcept|
        (**$(Ptr_Reconstruct * reconPtr)).productAlign();
      |]


syncPointcloud :: (MonadIO m, MonadError CvException m) => Reconstruct -> m ()
syncPointcloud recon = wrapException $ liftIO $ do
  withPtr recon $ \reconPtr -> do
    handleCvException (pure ()) $ do
      [cvExcept|
        (**$(Ptr_Reconstruct * reconPtr)).syncPointcloud();
      |]


syntheticAlign :: (MonadIO m, MonadError CvException m) => Reconstruct -> (M44 Float) -> (M44 Float) -> (V3 Double) -> m ()
syntheticAlign recon labelbox productbox (V3 x y z) = wrapException $ liftIO $ do
  withPtr recon $ \reconPtr -> do
    labelPtr <- toModelMatrixPtr labelbox
    productPtr <- toModelMatrixPtr productbox
    withArray [realToFrac x, realToFrac y, realToFrac z] $ \axisPtr -> do
      handleCvException (pure ()) $ do
        [cvExcept|
          Eigen::Matrix4f label_matrix;
          Eigen::Matrix4f product_matrix;
          for (int j = 0; j < 4; ++j)
            for (int i = 0; i < 4; ++i) {
              label_matrix(i, j) = *($(const float* labelPtr) + j * 4 + i);
              product_matrix(i, j) = *($(const float* productPtr) + j * 4 + i);
            }

          Eigen::Vector3d axis_of_rotation;
          axis_of_rotation[0] = *($(const double* axisPtr) + 0);
          axis_of_rotation[1] = *($(const double* axisPtr) + 1);
          axis_of_rotation[2] = *($(const double* axisPtr) + 2);
          (**$(Ptr_Reconstruct * reconPtr)).syntheticAlign(label_matrix, product_matrix, axis_of_rotation);
        |]



setManuParams :: (MonadIO m, MonadError CvException m) => Reconstruct -> Int -> (M44 Float) -> (M44 Float) -> [V3 Double] -> [V3 Double] -> m ()
setManuParams recon thresh labelbox productbox pixels worlds = wrapException $ liftIO $ do
  let c'thresh = fromIntegral thresh
      npixels = fromIntegral $ length pixels
      nworlds = fromIntegral $ length worlds
      -- Flatten the lists: each V3 is converted to [x, y, 0] (ignore z)
      pixelList = concatMap (\(V3 a b _) -> [a, b, 0]) pixels
      worldList = concatMap (\(V3 a b _) -> [a, b, 0]) worlds
  withArray (map realToFrac pixelList) $ \pPixels ->
    withArray (map realToFrac worldList) $ \pWorlds ->
      withPtr recon $ \reconPtr -> do
        labelPtr <- toModelMatrixPtr labelbox
        productPtr <- toModelMatrixPtr productbox
        handleCvException (pure ()) $ do
          [cvExcept|
            Eigen::Matrix4f label_matrix;
            Eigen::Matrix4f product_matrix;
            for (int j = 0; j < 4; ++j)
              for (int i = 0; i < 4; ++i) {
                label_matrix(i, j) = *($(const float* labelPtr) + j * 4 + i);
                product_matrix(i, j) = *($(const float* productPtr) + j * 4 + i);
              }

            // Build std::vector<double> from the Haskell arrays.
            std::vector<double> pixelPts($(double* pPixels), $(double* pPixels) + $(int npixels)*3);
            std::vector<double> worldPts($(double* pWorlds), $(double* pWorlds) + $(int nworlds)*3);
            // Convert to vectors of cv::Point2d (using only the first two components).
            std::vector<cv::Point2d> pixelsVec, worldsVec;
            for (size_t i = 0; i < pixelPts.size(); i += 3) {
              pixelsVec.push_back(cv::Point2d(pixelPts[i], pixelPts[i+1]));
            }
            for (size_t i = 0; i < worldPts.size(); i += 3) {
              worldsVec.push_back(cv::Point2d(worldPts[i], worldPts[i+1]));
            }

            (**$(Ptr_Reconstruct * reconPtr)).setManuParams($(int c'thresh), label_matrix, product_matrix, pixelsVec, worldsVec);
          |]



directlyAlign :: (MonadIO m, MonadError CvException m) => Reconstruct -> (M44 Float) -> (M44 Float) -> [V3 Double] -> [V3 Double] -> m ()
directlyAlign recon labelbox productbox pixels worlds = wrapException $ liftIO $ do
  let npixels = fromIntegral $ length pixels
      nworlds = fromIntegral $ length worlds
      -- Flatten the lists: each V3 is converted to [x, y, 0] (ignore z)
      pixelList = concatMap (\(V3 a b _) -> [a, b, 0]) pixels
      worldList = concatMap (\(V3 a b _) -> [a, b, 0]) worlds
  withArray (map realToFrac pixelList) $ \pPixels ->
    withArray (map realToFrac worldList) $ \pWorlds ->
      withPtr recon $ \reconPtr -> do
        labelPtr <- toModelMatrixPtr labelbox
        productPtr <- toModelMatrixPtr productbox
        handleCvException (pure ()) $ do
          [cvExcept|
            Eigen::Matrix4f label_matrix;
            Eigen::Matrix4f product_matrix;
            for (int j = 0; j < 4; ++j)
              for (int i = 0; i < 4; ++i) {
                label_matrix(i, j) = *($(const float* labelPtr) + j * 4 + i);
                product_matrix(i, j) = *($(const float* productPtr) + j * 4 + i);
              }

            // Build std::vector<double> from the Haskell arrays.
            std::vector<double> pixelPts($(double* pPixels), $(double* pPixels) + $(int npixels)*3);
            std::vector<double> worldPts($(double* pWorlds), $(double* pWorlds) + $(int nworlds)*3);
            // Convert to vectors of cv::Point2d (using only the first two components).
            std::vector<cv::Point2d> pixelsVec, worldsVec;
            for (size_t i = 0; i < pixelPts.size(); i += 3) {
              pixelsVec.push_back(cv::Point2d(pixelPts[i], pixelPts[i+1]));
            }
            for (size_t i = 0; i < worldPts.size(); i += 3) {
              worldsVec.push_back(cv::Point2d(worldPts[i], worldPts[i+1]));
            }

            (**$(Ptr_Reconstruct * reconPtr)).directlyAlign(label_matrix, product_matrix, pixelsVec, worldsVec);
          |]


getMotionRevise :: (MonadIO m, MonadError CvException m) => Reconstruct -> m (Double, Double, Double)
getMotionRevise recon = wrapException $ liftIO $ do
  allocaArray 3 \revisePtr -> do
    withPtr recon $ \reconPtr -> do
      handleCvException
        (do
            [a,b,c] <- peekArray 3 revisePtr
            return (realToFrac a, realToFrac b, realToFrac c))
        [cvExcept|
          auto result = (**$(Ptr_Reconstruct * reconPtr)).getMotionRevise();
          $(double* revisePtr)[0] = std::get<0>(result);
          $(double* revisePtr)[1] = std::get<1>(result);
          $(double* revisePtr)[2] = std::get<2>(result);
        |]


gizmoAlignToPlane :: (MonadIO m, MonadError CvException m) => Reconstruct -> M44 Float -> m (M44 Float)
gizmoAlignToPlane recon mat = wrapException $ liftIO $ do
  withPtr recon $ \reconPtr -> do
    modelMatrixPtr <- toModelMatrixPtr mat
    newModelMatrixPtr <- mallocArray 16
    handleCvException (fromModelMatrixPtr newModelMatrixPtr) $ do
      [cvExcept|
        Eigen::Matrix4f model_matrix;
        for (int j = 0; j < 4; ++j)
          for (int i = 0; i < 4; ++i)
            model_matrix(i, j) = *($(const float* modelMatrixPtr) + j * 4 + i);
        Eigen::Matrix4f aligned_matrix = (**$(Ptr_Reconstruct * reconPtr)).gizmoAlign(model_matrix);
        for(int j = 0; j < 4; ++j)
          for(int i = 0; i < 4; ++i)
            *($(float* newModelMatrixPtr) + j * 4 + i) = aligned_matrix(i, j);
      |]


gizmoAlignToAxle :: (MonadIO m, MonadError CvException m) => Reconstruct -> M44 Float -> m (M44 Float)
gizmoAlignToAxle recon mat = wrapException $ liftIO $ do
  withPtr recon $ \reconPtr -> do
    modelMatrixPtr <- toModelMatrixPtr mat
    newModelMatrixPtr <- mallocArray 16
    handleCvException (fromModelMatrixPtr newModelMatrixPtr) $ do
      [cvExcept|
        Eigen::Matrix4f model_matrix;
        for (int j = 0; j < 4; ++j)
          for (int i = 0; i < 4; ++i)
            model_matrix(i, j) = *($(const float* modelMatrixPtr) + j * 4 + i);
        Eigen::Matrix4f aligned_matrix = (**$(Ptr_Reconstruct * reconPtr)).gizmoRotationAxle(model_matrix);
        for(int j = 0; j < 4; ++j)
          for(int i = 0; i < 4; ++i)
            *($(float* newModelMatrixPtr) + j * 4 + i) = aligned_matrix(i, j);
      |]



transformPointCloud :: (MonadIO m, MonadError CvException m) => Reconstruct -> M44 Float -> Int -> m ()
transformPointCloud recon mat index = wrapException $ liftIO $ do
  let c'index = fromIntegral index
  withPtr recon $ \reconPtr -> do
    handleCvException (pure ()) $ do
      modelMatrixPtr <- toModelMatrixPtr mat
      [cvExcept|
        Eigen::Matrix4f model_matrix;
        for (int j = 0; j < 4; ++j)
          for (int i = 0; i < 4; ++i)
            model_matrix(i, j) = *($(const float* modelMatrixPtr) + j * 4 + i);
        (**$(Ptr_Reconstruct * reconPtr)).applyTransform(model_matrix, $(int c'index));
      |]


-- The Haskell wrapper function
clipPointCloud :: (MonadIO m, MonadError CvException m) => Reconstruct -> M44 Float -> Int -> m ()
clipPointCloud recon mat index = wrapException $ liftIO $ do
  let c'index = fromIntegral index
  withPtr recon $ \reconPtr -> do
    handleCvException (pure ()) $ do
      modelMatrixPtr <- toModelMatrixPtr mat
      [cvExcept|
        Eigen::Matrix4f model_matrix;
        for (int j = 0; j < 4; ++j)
          for (int i = 0; i < 4; ++i)
            model_matrix(i, j) = *($(const float* modelMatrixPtr) + j * 4 + i);
        (**$(Ptr_Reconstruct * reconPtr)).clipPointCloud(model_matrix, $(int c'index));
      |]


-- Helper function to convert M44 Float to a raw pointer for use in C++
toModelMatrixPtr :: M44 Float -> IO (Ptr CFloat)
toModelMatrixPtr (Linear.V4 (Linear.V4 a b c d)
                            (Linear.V4 e f g h)
                            (Linear.V4 i j k l)
                            (Linear.V4 m n o p)) = newArray $ map realToFrac [a, b, c, d,
                                                                              e, f, g, h,
                                                                              i, j, k, l,
                                                                              m, n, o, p]


fromModelMatrixPtr :: Ptr CFloat -> IO (M44 Float)
fromModelMatrixPtr ptr = do
  values <- peekArray 16 ptr
  let [a,b,c,d,
       e,f,g,h,
       i,j,k,l,
       m,n,o,p] = map realToFrac values
  return $ V4 (V4 a b c d)
              (V4 e f g h)
              (V4 i j k l)
              (V4 m n o p)
