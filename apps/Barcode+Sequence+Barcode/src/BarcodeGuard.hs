module BarcodeGuard where

import Data.Char (isSpace)
import Data.List (isInfixOf)
import FRP.Yampa (SF, Event, edgeBy)

data BarcodeVerdict = BarcodeAccepted | BarcodeMismatch | BarcodeMissingText
                    | BarcodeMissingCode | BarcodeReadError
  deriving (Eq, Show, Read)

-- Keep the verdict separate from decoded data and human-readable log messages.
-- A mismatch must never be mistaken for an ordinary serial number.
data BarcodeResult = BarcodeResult
  { barcodeGuardEnabled :: Bool
  , barcodeVerdict :: BarcodeVerdict
  , barcodeDecoded :: String
  , barcodePrinted :: String
  , barcodeDetail :: String
  } deriving (Eq, Show, Read)

validateBarcode :: Bool -> String -> Either String String -> BarcodeResult
validateBarcode enabled decoded printed
  | null decoded || decoded == "ng" = result BarcodeMissingCode "" "未找到唯一条码"
  | not enabled = result BarcodeAccepted "" "仅解码条码；未校验印字"
  | otherwise = case printed of
      Left failure -> result BarcodeReadError "" failure
      Right raw
        | null (filter (not . isSpace) raw) -> result BarcodeMissingText raw "未识别到印字"
        | decoded `isInfixOf` filter (not . isSpace) raw -> result BarcodeAccepted raw "印字中包含条码内容"
        | otherwise -> result BarcodeMismatch raw "印字中未找到条码内容"
  where
    result verdict raw detail = BarcodeResult enabled verdict decoded raw detail

guardAllowsResult :: Bool -> BarcodeResult -> Bool
guardAllowsResult enabled result = barcodeVerdict result == BarcodeAccepted &&
                                  (not enabled || barcodeGuardEnabled result)

-- Guard rejection precedes the continuity comparison, even when no expected
-- sequence is configured. A stale unguarded result cannot pass an enabled guard.
data ProductionDecision = ProductionRejected String | SequenceUnconfigured
                        | SequenceMatched | SequenceMismatched
  deriving (Eq, Show)

decideProduction :: Bool -> Maybe (String, Int, Int) -> BarcodeResult -> ProductionDecision
decideProduction enabled expected result
  | not (guardAllowsResult enabled result) = ProductionRejected $
      if enabled && not (barcodeGuardEnabled result)
        then "设置已改变：该结果未校验印字，请重新检测"
        else barcodeDetail result
  | otherwise = case expected of
      Nothing -> SequenceUnconfigured
      Just (value, start, end) ->
        let actual = take (abs (end - start)) (drop (min start end) (barcodeDecoded result))
        in if actual == value then SequenceMatched else SequenceMismatched

formatBarcodeResult :: BarcodeResult -> String
formatBarcodeResult result =
  "[印字校验" ++ (if barcodeGuardEnabled result then "开启" else "关闭") ++ "] " ++
  (case barcodeVerdict result of
     BarcodeAccepted -> if barcodeGuardEnabled result then "MATCH" else "BARCODE ONLY"
     BarcodeMismatch -> "NG/MISMATCH"
     BarcodeMissingText -> "NG/NO TEXT"
     BarcodeMissingCode -> "NG/NO UNIQUE BARCODE"
     BarcodeReadError -> "NG/OCR ERROR") ++
  " 条码=" ++ show (barcodeDecoded result) ++
  (if barcodeGuardEnabled result then " 印字=" ++ show (barcodePrinted result) else "") ++
  "；" ++ barcodeDetail result ++ "\n"

-- A completion may remain visible for several FRP samples. Do not count it
-- twice, but never suppress a different result just because it arrived quickly.
inspectionCompletions :: Eq a => SF (Maybe a) (Event a)
inspectionCompletions = edgeBy changed Nothing
  where
    changed previous current = if previous == current then Nothing else current
