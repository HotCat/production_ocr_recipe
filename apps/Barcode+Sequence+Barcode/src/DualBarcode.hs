module DualBarcode where

import BarcodeGuard
import Control.Concurrent.Async (Async, async, poll)
import qualified Control.Exception as E
import Control.Monad (when)
import Data.IORef

data BarcodePairResult = BarcodePairResult
  { productBarcode :: BarcodeResult
  , packagingBarcode :: BarcodeResult
  } deriving (Eq, Show, Read)

-- Transport failures cannot escape as accepted strings or terminate a worker.
tryInspection :: Bool -> IO BarcodeResult -> IO BarcodeResult
tryInspection enabled action = E.catch action $ \failure ->
  case E.fromException failure :: Maybe E.AsyncException of
    Just _ -> E.throwIO (failure :: E.SomeException)
    Nothing -> pure (BarcodeResult enabled BarcodeReadError "" "" (E.displayException failure))

inspectBarcodePairWith :: (Bool -> image -> IO BarcodeResult)
                      -> Bool -> Bool -> image -> Either String image -> IO BarcodePairResult
inspectBarcodePairWith inspect productGuard packagingGuard productImage packagingImage = do
  productResult <- tryInspection productGuard (inspect productGuard productImage)
  packagingResult <- case packagingImage of
    Left reason -> pure (BarcodeResult packagingGuard BarcodeReadError "" "" reason)
    Right image -> tryInspection packagingGuard (inspect packagingGuard image)
  pure (BarcodePairResult productResult packagingResult)

-- Compare decoded data verbatim. OCR whitespace normalization applies only
-- inside each printed-text guard, never to the cross-barcode comparison.
decideBarcodePair :: Bool -> Bool -> Maybe (String, Int, Int)
                  -> BarcodePairResult -> ProductionDecision
decideBarcodePair productGuard packagingGuard expected result
  | not (guardAllowsResult productGuard productResult) =
      ProductionRejected ("产品条码: " ++ barcodeDetail productResult)
  | not (guardAllowsResult packagingGuard packagingResult) =
      ProductionRejected ("包装条码: " ++ barcodeDetail packagingResult)
  | barcodeDecoded packagingResult /= barcodeDecoded productResult =
      ProductionRejected "包装条码与产品条码内容不完全一致"
  | otherwise = decideProduction productGuard expected productResult
  where
    productResult = productBarcode result
    packagingResult = packagingBarcode result

formatBarcodePair :: BarcodePairResult -> String
formatBarcodePair result = "[产品] " ++ formatBarcodeResult (productBarcode result) ++
                           "[包装] " ++ formatBarcodeResult (packagingBarcode result)

formatGuardSetting :: String -> Bool -> String
formatGuardSetting region enabled = "[设置][" ++ region ++ "] 印字校验" ++
  (if enabled then "开启：印字必须包含完整条码内容" else "关闭：仅解码条码") ++ "\n"

-- Both regions are captured before starting a job. At most one full production
-- inspection runs at once; each asynchronous result owns both of its ROIs.
data BarcodePairRuntime image = BarcodePairRuntime
  { pairPending :: IORef (Maybe (Bool, Bool, Async BarcodePairResult))
  , pairLastLabel :: IORef (Maybe (Bool, Bool, String))
  , pairCompletionSequence :: IORef Integer
  , pairPackagingImage :: IORef (Maybe (Either String image))
  }

newBarcodePairRuntime :: IO (BarcodePairRuntime image)
newBarcodePairRuntime = BarcodePairRuntime <$> newIORef Nothing <*> newIORef Nothing <*> newIORef 0 <*> newIORef Nothing

storePackagingImage :: BarcodePairRuntime image -> Either String image -> IO ()
storePackagingImage runtime = writeIORef (pairPackagingImage runtime) . Just

-- Consume, rather than reuse, the other ROI. If a custom Scheme script omits
-- the packaging callback, stale frames cannot accidentally pass a later product.
takePackagingImage :: BarcodePairRuntime image -> IO (Either String image)
takePackagingImage runtime = atomicModifyIORef' (pairPackagingImage runtime) $ \image ->
  (Nothing, maybe (Left "当前帧未提供包装条码区域") id image)

resetBarcodePair :: BarcodePairRuntime image -> IO ()
resetBarcodePair runtime = writeIORef (pairLastLabel runtime) Nothing

queueBarcodePairWith :: (Bool -> image -> IO BarcodeResult) -> BarcodePairRuntime image
                     -> Bool -> Bool -> Bool -> String -> image -> Either String image -> IO ()
queueBarcodePairWith inspect runtime productGuard packagingGuard triggered decoded productImage packagingImage = do
  let label = if triggered
                then Just (productGuard, packagingGuard, decoded) else Nothing
  previous <- readIORef (pairLastLabel runtime)
  pending <- readIORef (pairPending runtime)
  case pending of
    Just _ -> when (label == Nothing) $ resetBarcodePair runtime
    Nothing -> do
      writeIORef (pairLastLabel runtime) label
      when (label /= Nothing && label /= previous) $ do
        task <- async (inspectBarcodePairWith inspect productGuard packagingGuard productImage packagingImage)
        writeIORef (pairPending runtime) (Just (productGuard, packagingGuard, task))

pollBarcodePair :: BarcodePairRuntime image -> IO (Maybe BarcodePairResult)
pollBarcodePair runtime = do
  pending <- readIORef (pairPending runtime)
  case pending of
    Nothing -> pure Nothing
    Just (productGuard, packagingGuard, task) -> do
      outcome <- poll task
      case outcome of
        Nothing -> pure Nothing
        Just (Right result) -> writeIORef (pairPending runtime) Nothing >> pure (Just result)
        Just (Left failure) -> do
          writeIORef (pairPending runtime) Nothing
          let errorResult enabled = BarcodeResult enabled BarcodeReadError "" "" (E.displayException failure)
          pure (Just (BarcodePairResult (errorResult productGuard) (errorResult packagingGuard)))

encodeBarcodePairCompletion :: BarcodePairRuntime image -> BarcodePairResult -> IO String
encodeBarcodePairCompletion runtime result = do
  token <- atomicModifyIORef' (pairCompletionSequence runtime) $ \n -> (n + 1, n + 1)
  pure (show (token, result))
