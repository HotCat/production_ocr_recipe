
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# language BlockArguments #-}
{-# language OverloadedStrings #-}
{-# language TypeFamilies #-}

module TextRecog where

import Foreign.C.Types
import Foreign.C.String
import Foreign.Ptr (nullPtr)
import Foreign.Marshal.Alloc (free)
import Data.Word
import Data.Char
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import qualified Data.ByteString as BS
import qualified Data.Text.Encoding as TE
import qualified Language.C.Inline as C
import qualified Language.C.Inline.Unsafe as CU
import qualified Language.C.Inline.Cpp as C
import Text.RawString.QQ
import OpenCV
import OpenCV.Core.Types
import OpenCV.Internal
import OpenCV.Internal.C.Inline ( openCvCtx )
import OpenCV.Internal.C.Types
import OpenCV.Internal.Core.ArrayOps
import OpenCV.Internal.Core.Types ( withArrayPtr, Scalar )
import OpenCV.Internal.Core.Types.Mat
import OpenCV.Internal.Exception ( cvExcept, cvExceptU, unsafeWrapException, handleCvException )
import OpenCV.TypeLevel

import System.Environment
import Control.Monad
import OcrTiming (timeOcrRequest)
import Control.Concurrent.STM
import Language.Scheme.Types
import qualified Control.Exception as E
import System.IO.Unsafe ( unsafePerformIO )
import qualified Data.Text as T


C.context openCvCtx

C.include "<stdlib.h>"

C.include "opencv2/opencv.hpp"

C.include "zmq.hpp"
C.include "<cstring>"
C.include "<cstdlib>"
C.include "<vector>"
C.include "<stdexcept>"

C.using "namespace cv"

-- Previous service transport (retained for reference).
-- C.verbatim [r|
-- static char* paddleServiceRequest(const cv::Mat& image, const char* endpoint) {
--   std::string response;
--   try {
--     static zmq::context_t context(1);
--     zmq::socket_t socket(context, ZMQ_REQ);
--     int timeoutMs = 60000;
--     int lingerMs = 0;
--     socket.set(zmq::sockopt::rcvtimeo, timeoutMs);
--     socket.set(zmq::sockopt::sndtimeo, timeoutMs);
--     socket.set(zmq::sockopt::linger, lingerMs);
--     socket.connect(endpoint);
-- 
--     std::string header = "{\"op\":\"recognize\",\"encoding\":\"png\"}";
--     std::vector<unsigned char> encoded;
--     if (!cv::imencode(".png", image, encoded)) {
--       response = "ERROR: could not encode image";
--     } else {
--       socket.send(zmq::buffer(header), zmq::send_flags::sndmore);
--       socket.send(zmq::buffer(encoded), zmq::send_flags::none);
--       zmq::message_t message;
--       if (!socket.recv(message)) {
--         response = "ERROR: PaddleOCR service timed out";
--       } else {
--         response.assign(static_cast<const char*>(message.data()), message.size());
--       }
--     }
--   } catch (const std::exception&) {
--     response = "ERROR: ZeroMQ request failed";
--   }
-- 
--   char* result = static_cast<char*>(std::malloc(response.size() + 1));
--   if (!result) return nullptr;
--   std::memcpy(result, response.c_str(), response.size() + 1);
--   return result;
-- }
-- |]

C.verbatim [r|
// Contexts can be shared by threads; each request owns its own REQ socket.
static char* requestPaddleOcr(const cv::Mat& image, const char* endpoint) {
  std::string response;
  try {
    std::vector<unsigned char> png;
    if (image.empty() || !cv::imencode(".png", image, png)) {
      throw std::runtime_error("could not encode the OCR image as PNG");
    }

    static zmq::context_t context(1);
    zmq::socket_t socket(context, zmq::socket_type::req);
    socket.set(zmq::sockopt::linger, 0);
    socket.set(zmq::sockopt::immediate, 1);
    socket.set(zmq::sockopt::sndtimeo, 5000);
    // The reply deadline includes time waiting behind other clients' inference.
    int replyTimeoutMs = 120000;
    if (const char* setting = std::getenv("PADDLEOCR_TIMEOUT_MS")) {
      char* end = nullptr;
      long parsed = std::strtol(setting, &end, 10);
      if (*setting && *end == '\0' && parsed > 0 && parsed <= 3600000)
        replyTimeoutMs = static_cast<int>(parsed);
    }
    socket.set(zmq::sockopt::rcvtimeo, replyTimeoutMs);
    socket.connect(endpoint);

    const std::string header = "{\"op\":\"recognize\",\"encoding\":\"png\",\"profile\":\"legacy_en\"}";
    if (!socket.send(zmq::buffer(header), zmq::send_flags::sndmore) ||
        !socket.send(zmq::buffer(png), zmq::send_flags::none)) {
      throw std::runtime_error("timed out sending to the PaddleOCR service");
    }
    zmq::message_t reply;
    if (!socket.recv(reply, zmq::recv_flags::none)) {
      throw std::runtime_error("timed out waiting for the PaddleOCR service");
    }
    response.assign(static_cast<const char*>(reply.data()), reply.size());
  } catch (const std::exception& error) {
    response = std::string("ERROR: ") + error.what();
  }

  char* result = static_cast<char*>(std::malloc(response.size() + 1));
  if (result) std::memcpy(result, response.c_str(), response.size() + 1);
  return result;
}
|]

data PPOCR = PPOCR { ppoEndpoint :: String }


prepareOcr :: IO PPOCR
prepareOcr = PPOCR . fromMaybe "tcp://127.0.0.1:5555" <$> lookupEnv "PADDLEOCR_ENDPOINT"


-- Previous handle-taking implementation (retained for reference).
-- predictOcr :: (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> PPOCR -> IO String
-- predictOcr img ocr = do
--   result <- withPtr img $ \imgPtr -> withCString (ppoEndpoint ocr) $ \endpointPtr ->
--     [CU.block| char* {
--       return paddleServiceRequest(*$(Mat * imgPtr), $(char* endpointPtr));
--     }|]
--   when (result == nullPtr) $ ioError (userError "PaddleOCR service returned no response buffer")
--   response <- E.bracket (pure result) free peekCAString
--   if "ERROR:" `isPrefixOf` response
--     then ioError (userError response)
--     else pure response

-- Use the shared service through the endpoint prepared at startup.
predictOcr :: (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> PPOCR -> IO String
predictOcr img ocr = timeOcrRequest $ do
  let endpoint = ppoEndpoint ocr
  -- A safe FFI call lets other Haskell threads run while ZeroMQ waits.
  let request = withPtr img $ \imgPtr -> withCString endpoint $ \endpointPtr ->
        [C.block| char* {
          return requestPaddleOcr(*$(Mat * imgPtr), $(char* endpointPtr));
        }|]
  E.bracket request free $ \result -> do
    when (result == nullPtr) $
      ioError (userError "PaddleOCR service returned no response buffer")
    bytes <- BS.packCString result
    text <- either E.throwIO pure (TE.decodeUtf8' bytes)
    let response = T.unpack text
    if "ERROR:" `isPrefixOf` response
      then ioError (userError response)
      else pure response

sumImage :: (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> Double
sumImage img = realToFrac $ unsafePerformIO $
  withPtr img $ \imgPtr -> 
    [CU.block| double {
        return cv::sum(*$(Mat * imgPtr))[0];
    }|]



procSerialNum :: PPOCR -> TChan (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> TChan String -> IO ()
procSerialNum ocr submit receive = forever $ do
  image <- atomically $ readTChan submit
  -- Requests already encode PNG in memory. The old debug dump used the
  -- hardwired 1/my.png path and killed this thread before reaching ZeroMQ.
  outcome <- tryPredictOcr image ocr
  let message = case outcome of
        Left failure -> "PaddleOCR识别失败：" ++ failure
        Right "" -> "PaddleOCR未识别到文字"
        Right raw -> T.unpack (T.filter (\n -> isNumber n || isAlpha n) (T.pack raw))
  atomically $ writeTChan receive (message ++ "\n")

-- Keep transport/encoding errors visible without killing the preview worker
-- or the GUI. Cancellation must still terminate a worker promptly.
tryPredictOcr :: Mat ('S ['D, 'D]) ('S 3) ('S Word8) -> PPOCR -> IO (Either String String)
tryPredictOcr image ocr = E.catch (Right <$> predictOcr image ocr) $ \failure ->
  case E.fromException failure :: Maybe E.SomeAsyncException of
    Just _ -> E.throwIO (failure :: E.SomeException)
    Nothing -> pure (Left (E.displayException failure))



