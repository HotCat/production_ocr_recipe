{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE ViewPatterns        #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE CPP                 #-}
{-# language DeriveTraversable #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE Arrows #-}

module Main where

import qualified ProductionLog as PL
import qualified RuntimePerformance as PF

import RuntimePaths
import EngravingCompare

import           Codec.Picture
import           Codec.Picture.Extra    (flipVertically)
import           Codec.Picture.Types
import qualified Codec.Picture.Types    as CPTI
import           Control.Monad
import           Control.DeepSeq (NFData, force)
import           Control.Monad.IO.Class (MonadIO(liftIO))
import           Data.Bits
import           Data.ByteString        (ByteString)
import qualified Data.ByteString        as B
import qualified Data.ByteString.Char8  as B8
import           Data.ByteString.Unsafe
import qualified Data.Foldable          as F
import           Data.IORef
import           Data.List              (intercalate, isSuffixOf, isPrefixOf)
import qualified Data.List              as DL
import           Data.Vector.Storable   (Vector)
import qualified Data.Vector.Storable   as V
import           Data.Word
import           Foreign                hiding (void)
import           Foreign.C.String
import           Foreign.Marshal.Alloc
import           Foreign.Ptr
import           Foreign.Storable
import           Graphics.GL
import           Graphics.UI.GLFW
import           Prelude                hiding (init)
import           System.Exit
import           System.IO
import           System.Random

import           Linear

import           FRP.Yampa hiding ((^/), normalize)
import           Control.Monad
import           Control.Concurrent
import           Animate
import           Object
import           ObjectBehavior
import           Parser

import           DearImGui
import           DearImGui.GLFW
import           DearImGui.GLFW.OpenGL
import           DearImGui.OpenGL3
import           Device.Camera.Mindvision
import qualified DearImGui.FontAtlas as FontAtlas
import qualified Data.Map.Strict as Map
import qualified Data.Text as T

import           Control.Exception

import qualified OpenCV
import           OpenCV.TypeLevel
import           OpenCV.Internal.Core.Types.Mat
import           System.Environment

import           System.Directory
import           Language.Scheme.Types
import qualified Language.Scheme.Core as LSC
import qualified Language.Scheme.Variables as LSV

import           Control.Monad.Except
import           IdentityList

import           Text.RawString.QQ
import           Text.Printf
import           OpenCV.Video.MotionAnalysis
import           TextRecog
import           Barcode

import Data.StateVar
  ( HasGetter(get), HasSetter, ($=!) )


-- a = YP.embed (YP.sscan (\(b,c) a -> (a,a-b)) (0,0)) (YP.deltaEncode 1 [1,6,11,5])

-- Vector length, euclidean distance
pythagoras :: (Floating c, Foldable t, Functor t) => t c -> c
pythagoras = sqrt . sum . fmap (^2)

len :: (Floating c, Foldable t, Functor t) => t c -> c
len = pythagoras

unitVector :: (Functor t, Floating c, Foldable t) => t c -> t c
unitVector v = v ^/ pythagoras v

-- | Dot product over a vector space
-- λ> dotp [V2 1.2 3.4, V2 5.6 7.8]
-- 33.24
dotp :: (Foldable t, Num a, Num (t a)) => [t a] -> a
dotp = sum . product

-- | Dot product
-- λ> dotp' [1.2,3.4] [5.6,7.8]
-- 33.24
dotp' :: Num a => [a] -> [a] -> a
dotp' xs ys = sum (zipWith (*) xs ys)

crossP :: Num a => V3 a -> V3 a -> V3 a
crossP = cross
  where
    foo = [4 + read "3"]

distance (x1,y1) (x2,y2) = sqrt (x + y)
  where
    y = (y2 - y1) ^ 2
    x = (x2 - x1) ^ 2

degreesToRadians 0 = 0
degreesToRadians x = pi / (180 / x)

height, width :: Int
height = 600
width  = 800

lastX, lastY :: Float
lastX = fromIntegral width / 2
lastY = fromIntegral height / 2


cursorPosCallback
  :: IORef WinInput
  -> Window
  -> Double
  -> Double
  -> IO ()
cursorPosCallback wi win xpos ypos = do
  -- print $ "(x,y)-> " ++ show xpos ++ " " ++ show ypos
  modifyIORef' wi (\a -> a {cursorInput = Event $ CursorPos $ V2 xpos ypos})
  return ()



mouseButtonCallback
  :: IORef WinInput
  -> Window
  -> MouseButton
  -> MouseButtonState
  -> ModifierKeys
  -> IO ()
mouseButtonCallback wi win mb mbs mk = do
  print $ "button: " ++ show mb ++ " state: " ++ show mbs
  modifyIORef' wi (\a -> a {buttonInput = Event $ MouseButton mb mbs})
  return ()



keyCallback
  :: IORef WinInput
  -> Window
  -> Key
  -> Int
  -> KeyState
  -> ModifierKeys
  -> IO ()
keyCallback wi win key code ks mk = do
  print $ "key: " ++ show key ++ " code: " ++ show code ++ " ks: " ++ show ks ++ " mk: " ++ show mk
  modifyIORef' wi (\a -> a {keyInput = KeyStroke (Map.insert key (Keyboard key ks mk) ((keyInput >>> allKeys) a))})
  return ()


main99 :: IO ()
main99 = do
  let s = [r|
            o<nozzlealign> sub

            G54
            G64
            
            G90
            G1 A42.564 F1000
            G91

            #31=%d
            #32=0.1600
            #51=0.42343

            #33=-0.000671380
            #34=%f
            #53=0.94343

            o<nozzleAlign> endsub
            M02
          |]
  -- printf s (23::Int) (4.432432::Float)

  withFile "/dev/shm/111.scm" WriteMode $ \handle -> do
    let a = T.unpack $ T.unlines $ fmap T.strip (T.lines $ T.pack s)
    -- let a = T.unpack $ T.strip $ T.pack s
    hPrintf handle a (23::Int) (4.432432::Float)
    return ()


-- main :: IO ()
-- main = do
--   playSound


main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--runtime-info"] -> PF.initializeRuntime >> pure ()
    [] -> mainGui
    ["--help"] -> putStrLn usage
    ["--ocr-image", path] -> loadImage path >>= (\image -> prepareOcr >>= predictOcr image) >>= putStrLn
    ["--compare-image", path, expected] -> do
      image <- loadImage path
      ocr <- prepareOcr
      result <- inspectEngravingWith (predictOcr image ocr) expected
      putStr (formatComparison result)
      unless (comparisonPassed result) exitFailure
    _ -> die usage
  where
    usage = "Usage: Camera [--runtime-info | --ocr-image IMAGE | --compare-image IMAGE PRESET | --help]\nENGRAVING_COMPARE_CAMERA defaults to Hikvision; PADDLEOCR_ENDPOINT defaults to tcp://127.0.0.1:5555."
    loadImage path = unsafeCoerceMat . OpenCV.imdecode OpenCV.ImreadColor <$> B.readFile path

mainGui :: IO ()
mainGui = do
  performance <- PF.initializeRuntime
  PL.initializeProductionLog "Engraving+Compare"
  modbusInit
  runtimeDir <- getRuntimeDirectory
  createDirectoryIfMissing True runtimeDir
  configDir <- getConfigurationDirectory
  createDirectoryIfMissing True configDir
  forM_ ["fun.scm", "my.scm", "config1.scm", "config2.scm", "config3.scm"] $ \name -> do
    let target = configDir ++ "/" ++ name
    exists <- doesFileExist target
    unless exists $ copyFile ("src/" ++ name) target
  copyFile (configDir ++ "/fun.scm") (runtimeDir ++ "/fun.scm")
  copyFile (configDir ++ "/my.scm") (runtimeDir ++ "/my.scm")
  copyFile (configDir ++ "/config1.scm") (runtimeDir ++ "/config1.scm")
  copyFile (configDir ++ "/config2.scm") (runtimeDir ++ "/config2.scm") 
  copyFile (configDir ++ "/config3.scm") (runtimeDir ++ "/config3.scm")

  init
  windowHint (WindowHint'ContextVersionMajor 3)
  windowHint (WindowHint'ContextVersionMinor 3)
  windowHint (WindowHint'OpenGLProfile OpenGLProfile'Core)
  windowHint (WindowHint'OpenGLForwardCompat True)
  windowHint (WindowHint'OpenGLDebugContext True)
  getmaybeWindow <- createWindow width height "产品刻字预设文字比对工具" Nothing Nothing
  newInput <- newIORef (WinInput NoEvent NoEvent (KeyStroke Map.empty) (CtrlData Map.empty))

  case getmaybeWindow of
    Nothing -> do
      putStrLn "Failed to create GLFW window"
      terminate
      exitFailure

    Just window -> do
      makeContextCurrent (Just window)

      createContext

      setFramebufferSizeCallback window (Just frameBufferSizeCallback)
      setCursorPosCallback window (Just $ cursorPosCallback newInput)
      setMouseButtonCallback window (Just $ mouseButtonCallback newInput)
      setKeyCallback window (Just $ keyCallback newInput)

      ctrlMaps <- newIORef Map.empty

      glfwInitForOpenGL window True
      openGL3Init

      printGLVersion
      dumpError "gl version"

      glEnable GL_DEPTH_TEST
      dumpError "glEnable"
      shaderProgram <- makeShaderProgram "vert.glsl" "frag.glsl"
      dumpError "shader"

      fontSet <- FontAtlas.rebuild FontSet {
       -- The first mentioned font is loaded first
        -- and set as a global default.
        droidFont =
          FontAtlas.FromTTF
            --"./imgui/misc/fonts/DroidSans.ttf"
            -- "/home/test/Downloads/dear-imgui.hs/examples/fonts/NotoSansJP-Regular.otf"
            "font/DroidSans.ttf"
            15
            Nothing
            FontAtlas.Cyrillic

      , droidFont2 =
          FontAtlas.FromTTF
            --"./imgui/misc/fonts/DroidSans.ttf"
            -- "/home/test/Downloads/dear-imgui.hs/examples/fonts/NotoSansJP-Regular.otf"
            "font/DroidSans.ttf"
            24
            Nothing
            FontAtlas.Cyrillic

        -- You also may use a default hardcoded font for
        -- some purposes (i.e. as fallback)
      , defaultFont =
          FontAtlas.DefaultFont

        -- To optimize atlas size, use ranges builder and
        -- provide source localization data.
      , notoFont =
          FontAtlas.FromTTF
            "font/7s.ttf"
            60
            Nothing
            ( FontAtlas.RangesBuilder $ mconcat
                [ FontAtlas.addRanges FontAtlas.Latin
                --   FontAtlas.addText "8738"-- "私をクリックしてください"
                -- , FontAtlas.addText "123456" -- "こんにちは"
                ]
            )

      , myFont =
          FontAtlas.FromTTF
            "font/7s.ttf"
            72
            Nothing
            ( FontAtlas.RangesBuilder $ mconcat
                [ --FontAtlas.addRanges FontAtlas.Latin
                  FontAtlas.addText "8738"-- "私をクリックしてください"
                , FontAtlas.addText "123456" -- "こんにちは"
                ]
            )            

        , rabbitFont =
          FontAtlas.FromTTF
            "font/Rabbit.ttf"
            60
            Nothing
            ( FontAtlas.RangesBuilder $ mconcat
                [ FontAtlas.addRanges FontAtlas.Latin
                , FontAtlas.addText "8738"-- "私をクリックしてください"
                , FontAtlas.addText "123456" -- "こんにちは"
                ]
            )


        , msyhlFont =
          FontAtlas.FromTTF
            "font/msyhl.ttc"
            18
            Nothing
            ( FontAtlas.RangesBuilder $ mconcat
                [ FontAtlas.addRanges FontAtlas.ChineseFull
                ]
            )

      }

      let FontSet{..} = fontSet
      selected <- newIORef 0

      initBuffers $ \vaoPtr vboPtr containerPtr awesomeFacePtr -> do
        glUseProgram shaderProgram
        dumpError "use program"
        setInt shaderProgram "texture1" 0
        dumpError "set texture1"
        setInt shaderProgram "texture2" 1
        dumpError "set texture2"
        hFlush stdout

        env <- LSC.r5rsEnv
        comparisonRuntime <- newComparisonRuntime
        (init, getTimeInput, isClosed) <- mkInitAndGetTimeInput comparisonRuntime env newInput ctrlMaps

        pos <- newIORef $ ImVec2 64 64
        size' <- newIORef $ ImVec2 512 200

        pos2 <- newIORef $ ImVec2 427 209
        size2' <- newIORef $ ImVec2 300 512

        cameraName <- maybe "Hikvision" id <$> lookupEnv "ENGRAVING_COMPARE_CAMERA"
        result <- LSC.evalString env $ "(begin (define finalMat 0) (set! finalMat 0) (define yy 0) (define zz 0) (define xx #f) (define mycam 0) (set! mycam (init-my-camera " ++ show cameraName ++ ")))"
        -- result <- LSC.evalString env $ "(begin (define finalMat 0) (set! finalMat 0) (define yy 0) (define zz 0) (define xx #f) (define mycam 0) (set! mycam (init-my-camera \"MV-SUA131GC#0\")))"
        -- result <- LSC.evalString env $ "(begin (define finalMat 0) (set! finalMat 0) (define yy 0) (define zz 0) (define xx #f) (define mycam 0) (set! mycam (init-my-camera \"MV-SUA131GC#0\")))"
        -- result <- LSC.evalString env $ "(begin (define finalMat 0) (set! finalMat 0) (define yy 0) (define zz 0) (define xx #f) (define mycam 0) (set! mycam (init-my-camera \"GE500M\")))"
        -- result <- LSC.evalString env $ "(begin (define finalMat 0) (set! finalMat 0) (define yy 0) (define zz 0) (define xx #f) (define mycam 0) (set! mycam (init-my-camera \"Hikvision\")))"
        print result

        runState <- runExceptT $ do
          LSV.defineVar env "dear-rout-1" (String "")
          LSV.defineVar env "dear-rout-2" (String "")
          LSV.defineVar env "dear-rout-3" (String "")
          LSV.defineVar env "dear-rout-4" (String "")
          LSV.defineVar env "dear-rout-5" (String "")
          LSV.defineVar env "dear-rout-6" (String "")
          LSV.defineVar env "dear-rout-7" (String "")
          LSV.defineVar env "dear-rout-8" (String "")
          LSV.defineVar env "dear-rout-9" (String "")
          LSV.defineVar env "dear-rout-10" (String "")
          LSV.defineVar env "dear-rout-11" (String "")

          LSV.defineVar env "all-controls-references" (String "")
          LSV.setVar env "all-controls-references" (AllConfigs ctrlMaps)

        g <- newStdGen
        bs <- newBackgroundSubtractorMOG2 Nothing Nothing Nothing
        ocr <- prepareOcr

        reactimate init
                   (\refresh -> PF.measure performance "input" (getTimeInput refresh))
                   (\_ (a,b,c,d,e,f,g,h,i,j,k) -> do
                       shouldClose <- windowShouldClose window
                       runState <- PF.measure performance "frp+bindings" $ runExceptT $ do
                         LSV.setVar env "dear-rout-1" (Vision (Individual ((force a `seq` a) env shaderProgram ctrlMaps fontSet)))
                         LSV.setVar env "dear-rout-2" (Vision (Individual ((force b `seq` b) env ctrlMaps fontSet)))
                         LSV.setVar env "dear-rout-3" (Vision (Individual ((force c `seq` c) env ctrlMaps fontSet)))
                         LSV.setVar env "dear-rout-4" (Vision (Individual ((force d `seq` d) env)))
                         LSV.setVar env "dear-rout-5" (Vision (Individual ((force e `seq` e) env ctrlMaps fontSet)))
                         LSV.setVar env "dear-rout-6" (Vision (Individual ((force f `seq` f) env ctrlMaps fontSet)))
                         LSV.setVar env "dear-rout-7" (Vision (DaisyChain (\frame -> PF.measure performance "barcode" ((force g `seq` g) env ctrlMaps fontSet frame))))
                         LSV.setVar env "dear-rout-8" (Vision (DaisyChain (\frame -> PF.measure performance "image-filter" ((force h `seq` h) env ctrlMaps fontSet frame))))
                         LSV.setVar env "dear-rout-9" (Vision (DaisyChain (\frame -> PF.measure performance "serial" ((force i `seq` i) env ctrlMaps fontSet bs ocr frame))))
                         LSV.setVar env "dear-rout-10" (Vision (Individual ((force j `seq` j) env ctrlMaps fontSet)))
                         LSV.setVar env "dear-rout-11" (Vision (DaisyChain (\frame -> PF.measure performance "motion" ((force k `seq` k) env ctrlMaps fontSet bs frame))))

                       openGL3NewFrame
                       glfwNewFrame
                       newFrame

                       -- showDemoWindow
                       setNextWindowPos pos ImGuiCond_Once Nothing
                       setNextWindowSize size' ImGuiCond_Once

                       bracket_ (begin2 "Hello, tutu!") end do

                         withRuntimeConfigFile "my.scm" ReadMode $ \handle -> do
                           xs <- hGetContents handle
                           LSC.evalString env xs
 
                       setNextWindowPos pos2 ImGuiCond_Once Nothing
                       setNextWindowSize size2' ImGuiCond_Once

                       pushFont msyhlFont
                       bracket_ (begin "参数设置") end do

                         PF.measure performance "script+vision" $ withRuntimeConfigFile "fun.scm" ReadMode $ \handle -> do
                           xs <- hGetContents handle
                           r <- LSC.evalString env xs
                           -- when (take 27 r == "An internal error occurred:") $ void $ LSC.evalString env "(set! mycam 0)"
                           return ()

                       popFont

                       PF.measure performance "display-upload" $ render2 env shaderProgram vaoPtr containerPtr awesomeFacePtr window

                       -- showDemoWindow

                       -- glClear GL_COLOR_BUFFER_BIT
                       render
                       PF.measure performance "imgui-draw" $ openGL3RenderDrawData =<< getDrawData
                       PF.measure performance "present" $ swapBuffers window
                       pollEvents
                       PF.endFrame performance
                       if shouldClose == True
                         then do
                           copyFile (runtimeDir ++ "/fun.scm") (configDir ++ "/fun.scm")
                           copyFile (runtimeDir ++ "/my.scm") (configDir ++ "/my.scm")
                           copyFile (runtimeDir ++ "/config1.scm") (configDir ++ "/config1.scm")
                           copyFile (runtimeDir ++ "/config2.scm") (configDir ++ "/config2.scm")
                           copyFile (runtimeDir ++ "/config3.scm") (configDir ++ "/config3.scm")
                           return True
                         else return False
                   )
                   (parseKeyInput >>> combineAll g comparisonRuntime)
 
        glDeleteProgram shaderProgram
        glDeleteVertexArrays 1 vaoPtr
        glDeleteBuffers 1 vboPtr
        terminate
        exitSuccess

  return ()


getMyViewMatrix :: M44 Float
getMyViewMatrix = lookAt (V3 0 0 2) (V3 0 0 0) (V3 0 1 0)




render2
  -- :: CameraMv
  :: Env
  -> GLuint
  -> VAO
  -> TEXTURE
  -> TEXTURE
  -> Window
  -> IO ()
render2 env shaderProgram vaoPtr containerPtr awesomePtr window = do

  -- glPolygonMode GL_FRONT_AND_BACK GL_LINE
  glClearColor 0.2 0.3 0.3 1.0
  glClear (GL_COLOR_BUFFER_BIT .|. GL_DEPTH_BUFFER_BIT)

  glActiveTexture GL_TEXTURE0
  dumpError "glActiveTexture GL_TEXTURE0"

  glBindTexture GL_TEXTURE_2D =<< peek containerPtr
  dumpError "glDrawArrays GL_TRIANGLES 0 36"

  -- updateTexture

  -- result <- LSC.evalString env $ "(let ((k (read-camera-mat mycam))) (if (eq? xx #t) (load-camera-frame k) #f))"

  result <- LSC.evalString env $ "(load-camera-frame finalMat)"
  -- print result

  -- img <- mv_readFrame cam
  -- loadCamFrame img

  glActiveTexture GL_TEXTURE1
  dumpError "glActiveTexture GL_TEXTURE1"

  glBindTexture GL_TEXTURE_2D =<< peek awesomePtr
  dumpError "glBindTexture GL_TEXTURE_2D =<< peek containerPtr"

  glUseProgram shaderProgram
  dumpError "glUseProgram shaderProgram"

  -- setFloat shaderProgram "mixValue" 0.5

  peek vaoPtr >>= glBindVertexArray

  result <- LSC.evalString env $ "zz"
  let myi = read result :: Float
      view = getMyViewMatrix

      projection :: M44 Float
      projection =
        perspective
          (degreesToRadians myi)
          (fromIntegral width / fromIntegral height)
          0.1
          100.0

  setMatrix False shaderProgram "view" view
  setMatrix False shaderProgram "projection" projection

  result <- LSC.evalString env $ "yy"
  let myi = read result :: Float

  forM_ (zip [1..] positions) $ \(i :: Int,position) -> do
    Just (realToFrac -> time) <- getTime
    setMatrix False shaderProgram "model" $
      translated position !*!
        rotated (if i == 1 then myi
                   else time * 0.1 * fromIntegral (i * 5))
        (V3 0.7 0.5 0.3)
    glDrawArrays GL_TRIANGLES 0 36

  dumpError "glDrawArrays GL_TRIANGLES 0 36"






main2 :: IO ()
main2 = do
  init
  -- dumpError "init"
  windowHint (WindowHint'ContextVersionMajor 3)
  windowHint (WindowHint'ContextVersionMinor 3)
  windowHint (WindowHint'OpenGLProfile OpenGLProfile'Core)
  windowHint (WindowHint'OpenGLForwardCompat True)
  windowHint (WindowHint'OpenGLDebugContext True)
  getmaybeWindow <- createWindow width height "Learn OpenGL" Nothing Nothing
  cameraRef <- newIORef defaultCamera { position = V3 0 0 3 }
  firstMouseRef <- newIORef True
  lastXRef <- newIORef lastX
  lastYRef <- newIORef lastY
  case getmaybeWindow of
    Nothing -> do
      putStrLn "Failed to create GLFW window"
      terminate
      exitFailure
    Just window -> do
      makeContextCurrent (Just window)
      printGLVersion
      dumpError "gl version"
      setFramebufferSizeCallback window (Just frameBufferSizeCallback)
      setScrollCallback window (Just (scrollCallback cameraRef))
      setCursorPosCallback window (Just (mousePosCallback cameraRef firstMouseRef lastXRef lastYRef))
      setCursorInputMode window CursorInputMode'Disabled
      glEnable GL_DEPTH_TEST
      dumpError "glEnable"
      shaderProgram <- makeShaderProgram "vert.glsl" "frag.glsl"
      dumpError "shader"
      initBuffers $ \vaoPtr vboPtr containerPtr awesomeFacePtr -> do
        glUseProgram shaderProgram
        dumpError "use program"
        setInt shaderProgram "texture1" 0
        dumpError "set texture1"
        setInt shaderProgram "texture2" 1
        dumpError "set texture2"
        hFlush stdout
        ref <- newIORef (0.2 :: Float)
        lastFrameRef <- newIORef 0.0
        deltaRef <- newIORef 0.0
        forever $ do
          shouldClose <- windowShouldClose window
          if shouldClose
            then do
              glDeleteProgram shaderProgram
              glDeleteVertexArrays 1 vaoPtr
              glDeleteBuffers 1 vboPtr
              terminate
              exitSuccess
            else do
              process window ref cameraRef deltaRef
              render3 shaderProgram vaoPtr containerPtr awesomeFacePtr window ref
                cameraRef lastFrameRef deltaRef
              swapBuffers window
              pollEvents

debug :: Bool
debug = True

dumpError :: String -> IO ()
dumpError str = do
  when debug $ do
    code <- glGetError
    unless (code == 0) $ do
      print code
      putStrLn str
      exitFailure

proxySizeOf :: forall a p. Storable a => p a -> Int
proxySizeOf _ = sizeOf (undefined :: a)

printGLVersion :: IO ()
printGLVersion =
  putStrLn =<<
    peekCString =<<
      castPtr <$>
        glGetString GL_VERSION

makeShaderProgram :: String -> String -> IO GLuint
makeShaderProgram vertShaderFile fragShaderFile = do
  v <- compileShader GL_VERTEX_SHADER vertShaderFile
  dumpError "vert shader"
  f <- compileShader GL_FRAGMENT_SHADER fragShaderFile
  dumpError "frag shader"
  createShaderProgram v f

type VAO = Ptr GLuint
type VBO = Ptr GLuint
type EBO = Ptr GLuint
type TEXTURE = Ptr GLuint

floatSize :: Int
floatSize = sizeOf (undefined :: Float)

initBuffers :: (VBO -> VAO -> TEXTURE -> TEXTURE -> IO ()) -> IO ()
initBuffers callback = do
  alloca $ \vaoPtr -> do
   alloca $ \vboPtr -> do
    glGenVertexArrays 1 vaoPtr
    dumpError "glGenVertexArrays 1 vaoPtr"
    glGenBuffers 1 vboPtr
    dumpError "glGenBuffers 1 vboPtr"
    peek vaoPtr >>= glBindVertexArray
    peek vboPtr >>= glBindBuffer GL_ARRAY_BUFFER
    V.unsafeWith verts $ \vertsPtr ->
      glBufferData
        GL_ARRAY_BUFFER
        (fromIntegral (V.length verts * proxySizeOf verts))
        (castPtr vertsPtr)
        GL_STATIC_DRAW
    dumpError "glBufferData 1"

    glVertexAttribPointer 0 3 GL_FLOAT GL_FALSE
      (fromIntegral (floatSize * 5))
        nullPtr
    dumpError "glVertexAttribPointer 0 3"

    glEnableVertexAttribArray 0
    dumpError "glEnableVertexAttribArray 0"

    glVertexAttribPointer 1 2 GL_FLOAT GL_FALSE
      (fromIntegral (floatSize * 5))
        (nullPtr `plusPtr` (3 * floatSize))
    dumpError "glVertexAttribPointer 0"

    glEnableVertexAttribArray 1
    dumpError "glEnableVertexAttribArray 1"

    loadTexture "img/container.jpg" GL_REPEAT $ \container ->
      loadTexture "img/feitian.png" GL_REPEAT $ \face ->
        callback vaoPtr vboPtr container face

toImage
  :: String
  -> ByteString
  -> (Ptr Word8 -> GLint -> GLint -> IO ())
  -> IO ()
toImage name bytes go =
  case decodeImage bytes of
    Right (ImageYCbCr8 i) ->
      V.unsafeWith (imageData (convertImage i :: CPTI.Image PixelRGB8)) $ \ptr ->
        go ptr (fromIntegral (imageWidth i)) (fromIntegral (imageHeight i))
    Right (ImageRGBA8 i) ->
      V.unsafeWith (imageData (flipVertically (convertImage i :: CPTI.Image PixelRGBA8))) $ \ptr ->
        go ptr (fromIntegral (imageWidth i)) (fromIntegral (imageHeight i))
    _  -> do
      putStrLn name
      exitFailure


updateTexture :: IO ()
updateTexture = do
  let name = "src/window.png"
  bytes <- B.readFile name
  let typ | ".png" `isSuffixOf` name = GL_RGBA | otherwise = GL_RGB
  toImage name bytes $ \ptr w h -> do
      glTexImage2D GL_TEXTURE_2D 0
        GL_RGB w h
          0 typ GL_UNSIGNED_BYTE
            (castPtr ptr)
      glGenerateMipmap GL_TEXTURE_2D
  return ()


loadTexture :: String -> GLint -> (TEXTURE -> IO ()) -> IO ()
loadTexture name style f = do
  putStrLn ("loading texture: " <> name)
  alloca $ \texturePtr -> do
    glGenTextures 1 texturePtr
    dumpError "glGenTextures 1 texturePtr"
    glBindTexture GL_TEXTURE_2D =<< peek texturePtr
    dumpError "glBindTexture GL_TEXTURE_2D =<< peek texturePtr"
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_S style
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_WRAP_T style
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MIN_FILTER GL_LINEAR
    glTexParameteri GL_TEXTURE_2D GL_TEXTURE_MAG_FILTER GL_LINEAR
    bytes <- B.readFile name
    let typ | ".png" `isSuffixOf` name = GL_RGBA | otherwise = GL_RGB
    toImage name bytes $ \ptr w h -> do
      glTexImage2D GL_TEXTURE_2D 0
        GL_RGB w h
          0 typ GL_UNSIGNED_BYTE
            (castPtr ptr)
      dumpError "glTexImage2D"
      glGenerateMipmap GL_TEXTURE_2D
      dumpError "glGenMipmap"
      f texturePtr

withPtr
  :: (Functor f, Storable a, Floating a, Foldable f, Foldable g)
  => f (g a)
  -> (Ptr a -> IO ())
  -> IO ()
withPtr
  = V.unsafeWith
  . V.fromList
  . concat
  . DL.transpose
  . F.toList
  . fmap F.toList

translated :: V3 Float -> M44 Float
translated = mkTransformation (axisAngle (V3 0 0 0) 0)

rotated :: Float -> V3 Float -> M44 Float
rotated degrees vec = mkTransformation (axisAngle vec degrees) (V3 0 0 0)

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

verts :: Vector Float
verts
  = V.fromList
  [ -0.5, -0.5, -0.5,  0.0, 0.0,
     0.5, -0.5, -0.5,  1.0, 0.0,
     0.5,  0.5, -0.5,  1.0, 1.0,
     0.5,  0.5, -0.5,  1.0, 1.0,
    -0.5,  0.5, -0.5,  0.0, 1.0,
    -0.5, -0.5, -0.5,  0.0, 0.0,
    -0.5, -0.5,  0.5,  0.0, 0.0,
     0.5, -0.5,  0.5,  1.0, 0.0,
     0.5,  0.5,  0.5,  1.0, 1.0,
     0.5,  0.5,  0.5,  1.0, 1.0,
    -0.5,  0.5,  0.5,  0.0, 1.0,
    -0.5, -0.5,  0.5,  0.0, 0.0,
    -0.5,  0.5,  0.5,  1.0, 0.0,
    -0.5,  0.5, -0.5,  1.0, 1.0,
    -0.5, -0.5, -0.5,  0.0, 1.0,
    -0.5, -0.5, -0.5,  0.0, 1.0,
    -0.5, -0.5,  0.5,  0.0, 0.0,
    -0.5,  0.5,  0.5,  1.0, 0.0,
     0.5,  0.5,  0.5,  1.0, 0.0,
     0.5,  0.5, -0.5,  1.0, 1.0,
     0.5, -0.5, -0.5,  0.0, 1.0,
     0.5, -0.5, -0.5,  0.0, 1.0,
     0.5, -0.5,  0.5,  0.0, 0.0,
     0.5,  0.5,  0.5,  1.0, 0.0,
    -0.5, -0.5, -0.5,  0.0, 1.0,
     0.5, -0.5, -0.5,  1.0, 1.0,
     0.5, -0.5,  0.5,  1.0, 0.0,
     0.5, -0.5,  0.5,  1.0, 0.0,
    -0.5, -0.5,  0.5,  0.0, 0.0,
    -0.5, -0.5, -0.5,  0.0, 1.0,
    -0.5,  0.5, -0.5,  0.0, 1.0,
     0.5,  0.5, -0.5,  1.0, 1.0,
     0.5,  0.5,  0.5,  1.0, 0.0,
     0.5,  0.5,  0.5,  1.0, 0.0,
    -0.5,  0.5,  0.5,  0.0, 0.0,
    -0.5,  0.5, -0.5,  0.0, 1.0
  ]

render3
  :: GLuint
  -> VAO
  -> TEXTURE
  -> TEXTURE
  -> Window
  -> IORef Float
  -> IORef Camera
  -> IORef Float
  -> IORef Float
  -> IO ()
render3 shaderProgram vaoPtr containerPtr awesomePtr window ref cameraRef lastFrameRef deltaRef = do

  -- glPolygonMode GL_FRONT_AND_BACK GL_LINE
  glClearColor 0.2 0.3 0.3 1.0
  glClear (GL_COLOR_BUFFER_BIT .|. GL_DEPTH_BUFFER_BIT)

  glActiveTexture GL_TEXTURE0
  dumpError "glActiveTexture GL_TEXTURE0"

  glBindTexture GL_TEXTURE_2D =<< peek containerPtr
  dumpError "glDrawArrays GL_TRIANGLES 0 36"

  glActiveTexture GL_TEXTURE1
  dumpError "glActiveTexture GL_TEXTURE1"

  glBindTexture GL_TEXTURE_2D =<< peek awesomePtr
  dumpError "glBindTexture GL_TEXTURE_2D =<< peek containerPtr"

  glUseProgram shaderProgram
  dumpError "glUseProgram shaderProgram"

  setFloat shaderProgram "mixValue" =<< readIORef ref

  let radius = 10.0 :: Float
  Just (realToFrac -> time) <- getTime

  lastFrame <- readIORef lastFrameRef
  modifyIORef' deltaRef (\_ -> time - lastFrame)
  writeIORef lastFrameRef time

  view' <- getViewMatrix <$> readIORef cameraRef
  zoom' <- zoom <$> readIORef cameraRef

  let
    view :: M44 Float
    view = view'

    projection :: M44 Float
    projection =
      perspective
        (degreesToRadians zoom')
        (fromIntegral width / fromIntegral height)
        0.1
        100.0

  setMatrix False shaderProgram "view" view
  setMatrix False shaderProgram "projection" projection

  peek vaoPtr >>= glBindVertexArray

  forM_ (zip [1..] positions) $ \(i :: Int,position) -> do
    Just (realToFrac -> time) <- getTime
    setMatrix False shaderProgram "model" $
      translated position !*!
        -- rotated (if i `mod` 3 == 0 || i == 1
        --          then time * fromIntegral i / 2
        --          else fromIntegral $ i * 20)
        rotated (if i == 1 then 0
                   else time * fromIntegral (i * 5))
          -- (V3 1 0.3 0.5)
        --(V3 0.7 0.2 1)
        (V3 1 0.3 0.5)
    glDrawArrays GL_TRIANGLES 0 36

  dumpError "glDrawArrays GL_TRIANGLES 0 36"

positions :: [V3 Float]
positions =
  [ V3  0.0  0.0  0.0
  , V3  2.0  5.0 (-15.0)
  , V3 (-1.5) (-2.2) (-2.5)
  , V3 (-3.8) (-2.0) (-12.3)
  , V3  2.4 (-0.4) (-3.5)
  , V3 (-1.7)  3.0 (-7.5)
  , V3  1.3 (-2.0) (-2.5)
  , V3  1.5  2.0 (-2.5)
  , V3  1.5  0.2 (-1.5)
  , V3 (-1.3)  1.0 (-1.5)
  ]

setFloat :: GLuint -> String -> GLfloat -> IO ()
setFloat id' name val = do
  withCString name $ \cstr -> do
    location <- glGetUniformLocation id' cstr
    glUniform1f location val

setInt :: GLuint -> String -> GLint -> IO ()
setInt id' name val = do
  withCString name $ \cstr -> do
    location <- glGetUniformLocation id' cstr
    glUniform1i location val

setMatrix :: Bool -> GLuint -> String -> M44 Float -> IO ()
setMatrix flipped id' name val = do
  withCString name $ \cstr -> do
    location <- glGetUniformLocation id' cstr
    withPtr val
      $ glUniformMatrix4fv location 1
      $ fromIntegral (popCount flipped)

process
  :: Window
  -> IORef Float
  -> IORef Camera
  -> IORef Float
  -> IO ()
process window ref cameraRef deltaRef = do
  delta <- readIORef deltaRef
  keyState <- getKey window Key'Escape
  case keyState of
    KeyState'Pressed ->
      setWindowShouldClose window True
    _ -> pure ()

  keyState <- getKey window Key'Up
  case keyState of
    KeyState'Pressed -> do
      modifyIORef' ref $ \x -> do
        case x + 0.01 of
          newX | newX >= 1.0 -> 1.0
               | otherwise -> newX
    _ -> pure ()

  keyState <- getKey window Key'Down
  case keyState of
    KeyState'Pressed -> do
      modifyIORef' ref $ \x -> do
        case x - 0.01 of
          newX | newX <= 0.0 -> 0.0
               | otherwise -> newX
    _ -> pure ()

  keyState <- getKey window Key'W
  case keyState of
    KeyState'Pressed -> do
      modifyIORef' cameraRef $ \camera -> do
        processKeyboard CameraForward delta camera
    _ -> pure ()

  keyState <- getKey window Key'A
  case keyState of
    KeyState'Pressed -> do
      modifyIORef' cameraRef $ \camera -> do
        processKeyboard CameraLeft delta camera
    _ -> pure ()

  keyState <- getKey window Key'S
  case keyState of
    KeyState'Pressed -> do
      modifyIORef' cameraRef $ \camera -> do
        processKeyboard CameraBackward delta camera
    _ -> pure ()

  keyState <- getKey window Key'D
  case keyState of
    KeyState'Pressed -> do
      modifyIORef' cameraRef $ \camera -> do
        processKeyboard CameraRight delta camera
    _ -> pure ()

frameBufferSizeCallback
  :: Window
  -> Int
  -> Int
  -> IO ()
frameBufferSizeCallback _ width height =
  glViewport 0 0
    (fromIntegral width)
    (fromIntegral height)

mousePosCallback
  :: IORef Camera
  -> IORef Bool
  -> IORef Float
  -> IORef Float
  -> Window
  -> Double
  -> Double
  -> IO ()
mousePosCallback cameraRef mouseRef lastXRef lastYRef window xpos ypos = do
  firstMouse <- readIORef mouseRef

  when firstMouse $ do
    writeIORef lastXRef (realToFrac xpos)
    writeIORef lastYRef (realToFrac ypos)
    writeIORef mouseRef False

  lastX <- readIORef lastXRef
  lastY <- readIORef lastYRef

  let
    xOffset  = xpos - realToFrac lastX
    yOffset  = ypos - realToFrac lastY

  writeIORef lastXRef (realToFrac xpos)
  writeIORef lastYRef (realToFrac ypos)

  modifyIORef' cameraRef
    (processMouseMovement
       (realToFrac xOffset) (realToFrac yOffset)
          True)

scrollCallback
  :: IORef Camera
  -> Window
  -> Double
  -> Double
  -> IO ()
scrollCallback cameraRef _ _ yOffset =
  modifyIORef' cameraRef (processMouseScroll (realToFrac yOffset))

data Camera
  = Camera
  { position
  , front
  , up
  , right2
  , worldUp :: V3 Float
  , yaw
  , pitch
  , speed
  , sensitivity
  , zoom :: Float
  } deriving (Show, Eq)

defaultCamera :: Camera
defaultCamera = do
  let
    worldUp     = V3 0 1 0
    front       = V3 0 0 (-1)
    position    = V3 0 0 0
    yaw         = (-90)
    pitch       = 0
    speed       = 2.5
    sensitivity = 0.1
    zoom        = 45
    right2       = normalize (cross front worldUp)
  updateCameraVectors
    Camera
      { up = normalize (cross right2 front)
      , ..
      }

calcFront
  :: Float
  -- ^ yaw
  -> Float
  -- ^ pitch
  -> V3 Float
calcFront yaw pitch = do
  let
    x = cos (degreesToRadians yaw) * cos (degreesToRadians pitch)
    y = sin (degreesToRadians pitch)
    z = sin (degreesToRadians yaw) * cos (degreesToRadians pitch)
  normalize (V3 x y z)

updateCameraVectors
  :: Camera
  -> Camera
updateCameraVectors camera = do
  let
    newCamera =
      camera
      { front = calcFront (yaw camera) (pitch camera)
      }
  newCamera
    { right2 = normalize $ cross (front newCamera) (worldUp newCamera)
    , up = normalize $ cross (right2 newCamera) (front newCamera)
    }

processMouseScroll
  :: Float
  -> Camera
  -> Camera
processMouseScroll yoffset camera = do
  let updated = camera { zoom = zoom camera - yoffset }
      updatedCamera
        | zoom updated < 1  = updated { zoom = 1 }
        | zoom updated > 45 = updated { zoom = 45 }
        | otherwise         = updated
  updatedCamera

processMouseMovement :: Float -> Float -> Bool -> Camera -> Camera
processMouseMovement xOffset yOffset constraint c = do
  let
    xOffset' = sensitivity c * xOffset
    yOffset' = sensitivity c * yOffset
    yaw'     = xOffset' + yaw c
    pitch'   = yOffset' + pitch c
    pitch''  =
      if constraint
      then do
        let pitch''
              | pitch' > 89    = 89
              | pitch' < (-89) = (-89)
              | otherwise      = pitch'
        pitch''
      else
        pitch'
  updateCameraVectors c
    { yaw = yaw'
    , pitch = pitch''
    }

getViewMatrix
  :: Camera
  -> M44 Float
getViewMatrix c
  = lookAt (position c) (position c + front c) (up c)

processKeyboard
  :: CameraDirection
  -> Float
  -> Camera
  -> Camera
processKeyboard direction deltaTime c = do
  let
    velocity = speed c * deltaTime
  case direction of
    CameraForward ->
      c { position = position c + (front c ^* velocity) }
    CameraBackward ->
      c { position = position c - (front c ^* velocity) }
    CameraLeft ->
      c { position = position c - (right2 c ^* velocity) }
    CameraRight ->
      c { position = position c + (right2 c ^* velocity) }

data CameraDirection
  = CameraForward
  | CameraBackward
  | CameraLeft
  | CameraRight
  deriving (Show, Eq)



loadCamFrame :: (Mat ('S [height, width]) ('S 3) ('S Word8)) -> IO ()
loadCamFrame img = do
  withMatData img $ (\step ptr-> do
                        let [h,w] = miShape $ matInfo img
                        glTexImage2D GL_TEXTURE_2D 0
                          GL_RGB 
                          w h
                          0 GL_RGB GL_UNSIGNED_BYTE
                          (castPtr ptr)
                        glGenerateMipmap GL_TEXTURE_2D
                    )
                        




