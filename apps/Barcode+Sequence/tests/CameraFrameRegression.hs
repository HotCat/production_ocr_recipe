{-# LANGUAGE DataKinds #-}
module Main where

import Control.Exception (bracket, bracket_, finally)
import Control.Monad (forM_, unless)
import Data.Word (Word8)
import Data.IORef
import Control.Monad.Trans.Except (runExceptT)
import qualified Language.Scheme.Core as LSC
import qualified Language.Scheme.Variables as LSV
import qualified Data.ByteString as BS
import qualified Graphics.UI.GLFW as GLFW
import Graphics.GL
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (peek)
import qualified OpenCV as CV
import qualified Device.Camera.Hikvision as Hik
import qualified Language.Scheme.Types as Scheme
import OpenCV (Mat, matInfo, miShape)
import OpenCV.Internal.Core.Types.Mat (newEmptyMat, unsafeCoerceMat)
import OpenCV.Internal.Exception (exceptErrorIO)
import OpenCV.TypeLevel
import System.Environment (getArgs)

type Image = Mat ('S ['D, 'D]) ('S 3) ('S Word8)

main :: IO ()
main = do
  empty <- unsafeCoerceMat <$> newEmptyMat :: IO Image
  -- Previously this invoked the partial [h,w] pattern and terminated the app.
  Scheme.loadCamFrame empty
  putStrLn "PASS: shared renderer ignores an empty Mat without an OpenGL context"
  args <- getArgs
  case args of
    [] -> pure ()
    ["--upload", path] -> checkUpload path empty
    ["--pipeline", path, script] -> checkPipeline path script empty
    ["--probe", name] ->
      bracket (exceptErrorIO $ Hik.hv_init name)
              (exceptErrorIO . Hik.hv_close) $ \camera -> do
        exceptErrorIO $ Hik.hv_setProperties camera "ReverseY" 0
        forM_ [1..3 :: Int] $ \index -> do
          frame <- exceptErrorIO (Hik.hv_readFrame camera) :: IO Image
          let shape = miShape (matInfo frame)
          case shape of
            [height, width] -> unless (height > 0 && width > 0) $ fail "Empty camera image"
            _ -> fail ("Invalid camera image shape: " ++ show shape)
          putStrLn ("PASS: camera frame " ++ show index ++ " shape " ++ show shape)
    _ -> fail "Usage: CameraFrameRegression [--upload IMAGE | --probe Hikvision]"

-- Exercise a real texture upload, then confirm an empty frame preserves it.
checkUpload :: FilePath -> Image -> IO ()
checkUpload path empty = do
  encoded <- BS.readFile path
  let frame = unsafeCoerceMat (CV.imdecode CV.ImreadColor encoded) :: Image
  initialized <- GLFW.init
  unless initialized $ fail "GLFW initialization failed"
  flip finally GLFW.terminate $ do
    GLFW.windowHint (GLFW.WindowHint'Visible False)
    bracket (GLFW.createWindow 32 32 "frame regression" Nothing Nothing >>=
               maybe (fail "Could not create hidden OpenGL context") pure)
            GLFW.destroyWindow $ \window -> do
      GLFW.makeContextCurrent (Just window)
      alloca $ \texturePtr -> do
        glGenTextures 1 texturePtr
        texture <- peek texturePtr
        bracket_ (glBindTexture GL_TEXTURE_2D texture)
                 (glDeleteTextures 1 texturePtr) $ do
          Scheme.loadCamFrame frame
          original <- textureShape
          unless (original == miShape (matInfo frame)) $
            fail ("Unexpected uploaded texture shape: " ++ show original)
          Scheme.loadCamFrame empty
          after <- textureShape
          unless (after == original) $ fail "Empty frame replaced the valid texture"
          errorCode <- glGetError
          unless (errorCode == GL_NO_ERROR) $ fail ("OpenGL error: " ++ show errorCode)
          putStrLn "PASS: valid image uploads and empty image preserves the texture"
  where
    textureShape = alloca $ \heightPtr -> alloca $ \widthPtr -> do
      glGetTexLevelParameteriv GL_TEXTURE_2D 0 GL_TEXTURE_HEIGHT heightPtr
      glGetTexLevelParameteriv GL_TEXTURE_2D 0 GL_TEXTURE_WIDTH widthPtr
      height <- peek heightPtr
      width <- peek widthPtr
      pure [height, width]

-- Use the real Scheme runtime with simulated camera/ROI callbacks. Even when
-- every ROI callback returns an empty image, finalMat must retain the full frame.
checkPipeline :: FilePath -> FilePath -> Image -> IO ()
checkPipeline path script empty = do
  encoded <- BS.readFile path
  let frame = unsafeCoerceMat (CV.imdecode CV.ImreadColor encoded) :: Image
  env <- LSC.r5rsEnv
  calls <- newIORef ([] :: [Int])
  let register name value = LSV.defineVar env name value >> pure ()
      individual n = Scheme.Vision $ Scheme.Individual $
        modifyIORef' calls (++ [n])
      roi n = Scheme.Vision $ Scheme.DaisyChain $ \_ -> do
        modifyIORef' calls (++ [n])
        pure empty
  bindings <- runExceptT $ do
    register "camera-input" (Scheme.MatPipe frame)
    register "mycam" (Scheme.Number 0)
    register "finalMat" (Scheme.Number 0)
    mapM_ (\n -> register ("dear-rout-" ++ show n) (individual n)) [3, 5, 6]
    mapM_ (\n -> register ("dear-rout-" ++ show n) (roi n)) [7, 8, 9]
  either (fail . show) pure bindings
  _ <- LSC.evalString env "(define (read-camera-mat camera) camera-input)"
  source <- readFile script
  result <- LSC.evalString env source
  output <- runExceptT $ LSV.getVar env "finalMat"
  case output of
    Right (Scheme.MatPipe displayed) -> do
      unless (miShape (matInfo displayed) == miShape (matInfo frame)) $
        fail ("Display received a crop/empty frame: " ++ show (miShape (matInfo displayed)))
      original <- exceptErrorIO $ CV.imencode (CV.OutputPng CV.defaultPngParams) frame
      actual <- exceptErrorIO $ CV.imencode (CV.OutputPng CV.defaultPngParams) displayed
      unless (actual == original) $ fail "Display pixels differ from full camera frame"
    _ -> fail ("Display did not receive the captured frame: " ++ result)
  visited <- readIORef calls
  unless (7 `elem` visited) $ fail "Barcode callback was skipped"
  putStrLn ("PASS: full frame preserved with empty ROI callbacks: " ++ script ++
            "; callbacks " ++ show visited)
