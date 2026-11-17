module Main where
import BarcodeGuard
import DualBarcode
import Control.Concurrent
import Control.Exception (throwIO)
import Control.Monad
import Data.IORef
import System.Timeout

assert name value = unless value (fail name)
within action = timeout 3000000 action >>= maybe (fail "async test timed out") pure
waitResult runtime = within loop where
  loop = pollBarcodePair runtime >>= maybe (threadDelay 1000 >> loop) pure
accepted enabled value = validateBarcode enabled value (Right ("Vendor " ++ value ++ " Lot 42"))
pair a b = BarcodePairResult (accepted True a) (accepted True b)
rejected result = case result of ProductionRejected _ -> True; _ -> False

main = do
  let code = "AB-00123456789012"
      correct = pair code code
      expected = Just ("0012", 3, 7)
  assert "exact full contents accepted" (decideBarcodePair True True expected correct == SequenceMatched)
  forM_ ["99" ++ code, "ab-00123456789012", "AB00123456789012", code ++ " "] $ \wrong ->
    assert ("verbatim rejection: " ++ wrong) (rejected (decideBarcodePair True True Nothing (pair code wrong)))
  assert "matching last16 cannot pass different full barcode" (rejected
    (decideBarcodePair True True Nothing (pair "1234567890123456" "991234567890123456")))
  let productBad = correct {productBarcode = validateBarcode True code (Right "WRONG")}
      packagingBad = correct {packagingBarcode = validateBarcode True code (Right "WRONG")}
  assert "product misprint blocks pair" (rejected (decideBarcodePair True True expected productBad))
  assert "packaging misprint blocks pair" (rejected (decideBarcodePair True True expected packagingBad))
  assert "no sequence never accepts a misprint" (rejected (decideBarcodePair True True Nothing packagingBad))
  assert "continuity still enforced" (decideBarcodePair True True (Just ("0013",3,7)) correct == SequenceMismatched)
  assert "unconfigured sequence never counts a passing pair" (decideBarcodePair True True Nothing correct == SequenceUnconfigured)
  let stale = correct {packagingBarcode = accepted False code}
  assert "enabling packaging guard rejects old unguarded result" (rejected (decideBarcodePair True True expected stale))
  assert "disabled packaging guard does not disable product guard" (rejected (decideBarcodePair True False expected productBad))
  assert "disabled product guard does not disable packaging guard" (rejected (decideBarcodePair False True expected packagingBad))
  putStrLn "PASS: verbatim comparison, independent guards, stale settings and continuity"

  calls <- newIORef []
  let inspect enabled image = do
        modifyIORef' calls (++ [(enabled,image)])
        pure (accepted enabled code)
  _ <- inspectBarcodePairWith inspect False True (1::Int) (Right 2)
  observed <- readIORef calls
  assert "each region uses its own image and setting" (observed == [(False,1),(True,2)])
  invalid <- inspectBarcodePairWith inspect True True 1 (Left "invalid region")
  assert "invalid packaging region rejected" (rejected (decideBarcodePair True True expected invalid))
  let broken enabled image = if image == 2 then throwIO (userError "offline") else inspect enabled image
  failure <- inspectBarcodePairWith broken True True 1 (Right 2)
  assert "service exception rejected" (barcodeVerdict (packagingBarcode failure) == BarcodeReadError)
  recovered <- inspectBarcodePairWith inspect True True 1 (Right 2)
  assert "next pair can succeed after service error" (decideBarcodePair True True expected recovered == SequenceMatched)
  putStrLn "PASS: separate ROI/settings, invalid crop, service failure and recovery"

  runtime <- newBarcodePairRuntime
  storePackagingImage runtime (Right (2::Int))
  first <- takePackagingImage runtime
  second <- takePackagingImage runtime
  assert "fresh packaging ROI consumed once" (first == Right 2 && either (const True) (const False) second)
  started <- newEmptyMVar
  release <- newEmptyMVar
  count <- newIORef (0::Int)
  let slow enabled image = do
        when (image == 1) $ modifyIORef' count (+1) >> putMVar started () >> takeMVar release
        pure (accepted enabled code)
      enqueue triggered = queueBarcodePairWith slow runtime True True triggered code 1 (Right 2)
  within (enqueue True)
  within (takeMVar started)
  enqueue True
  pending <- pollBarcodePair runtime
  active <- readIORef count
  assert "only one in-flight pair and nonblocking poll" (pending == Nothing && active == 1)
  putMVar release ()
  result <- waitResult runtime
  assert "async owns both results" (result == correct)
  enqueue True
  held <- readIORef count
  assert "held trigger not counted twice" (held == 1)
  enqueue False
  enqueue True
  within (takeMVar started)
  putMVar release ()
  _ <- waitResult runtime
  rearmed <- readIORef count
  assert "release re-arms next pair" (rearmed == 2)
  firstMessage <- encodeBarcodePairCompletion runtime correct
  secondMessage <- encodeBarcodePairCompletion runtime correct
  assert "identical completed pairs get distinct production events" (firstMessage /= secondMessage)
  assert "completion payload preserves both exact codes" ((read firstMessage :: (Integer,BarcodePairResult)) == (1,correct))
  putStrLn "PASS: fresh frame pairing, nonblocking inspection, bounded concurrency, trigger latch and unique completion events"
