
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
import System.IO (hPutStrLn, stderr)
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

    std::string header = "{\"op\":\"recognize\",\"encoding\":\"png\",\"profile\":\"chinese\"}";
    const char* dispatch = std::getenv("PADDLEOCR_DISPATCH");
    if (!dispatch) dispatch = "cpu";
    if (std::strcmp(dispatch, "cpu") != 0 && std::strcmp(dispatch, "gpu") != 0 &&
        std::strcmp(dispatch, "auto") != 0)
      throw std::runtime_error("PADDLEOCR_DISPATCH must be cpu, gpu or auto");
    header.pop_back();
    header += std::string(",\"dispatch\":\"") + dispatch + "\"}";
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



-- Preserve the old helper used by motion detection.
sumImage2 :: Mat ('S ['D, 'D]) ('S 3) ('S Word8) -> Double
sumImage2 = sumImage

-- Preview workers preserve the complete multilingual OCR response.
procSerialNum :: PPOCR -> TChan (Mat ('S ['D, 'D]) ('S 3) ('S Word8)) -> TChan String -> IO ()
procSerialNum ocr submit receive = forever $ do
  image <- atomically $ readTChan submit
  result <- E.catch (predictOcr image ocr) $ \failure ->
    case E.fromException failure :: Maybe E.AsyncException of
      Just _ -> E.throwIO (failure :: E.SomeException)
      Nothing -> pure ("NG PaddleOCR: " ++ E.displayException failure)
  atomically $ writeTChan receive (result ++ "\n")
