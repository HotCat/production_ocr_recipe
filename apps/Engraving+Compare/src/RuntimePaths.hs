module RuntimePaths
  ( getRuntimeDirectory, getConfigurationDirectory, withRuntimeConfigFile
  , persistRuntimeProfile, getStartupProfile
  ) where

import Control.Exception (bracketOnError)
import Control.Monad (when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import Data.Maybe (fromMaybe)
import System.Directory
import System.Environment (lookupEnv)
import System.IO (Handle, IOMode, withFile, hSetEncoding, utf8, openBinaryTempFile, hClose)
import Text.Read (readMaybe)

getRuntimeDirectory :: IO FilePath
getRuntimeDirectory = fromMaybe "/dev/shm/engraving-compare" <$> lookupEnv "ENGRAVING_COMPARE_RUNTIME_DIR"

getConfigurationDirectory :: IO FilePath
getConfigurationDirectory = do
  override <- lookupEnv "ENGRAVING_COMPARE_CONFIG_DIR"
  case override of
    Just directory -> pure directory
    Nothing -> (++ "/ocrconfigs/engraving-compare") <$> getHomeDirectory

withRuntimeConfigFile :: FilePath -> IOMode -> (Handle -> IO a) -> IO a
withRuntimeConfigFile name mode action = do
  directory <- getRuntimeDirectory
  withFile (directory ++ "/" ++ name) mode $ \handle -> do
    hSetEncoding handle utf8
    action handle

-- Write into the destination directory, then rename: a failed/interrupted copy
-- must not truncate an existing saved profile. The runtime file is closed first.
writeConfigurationFile :: FilePath -> B.ByteString -> IO ()
writeConfigurationFile name bytes = do
  directory <- getConfigurationDirectory
  createDirectoryIfMissing True directory
  bracketOnError (openBinaryTempFile directory (name ++ ".tmp"))
    (\(temporary, handle) -> do
      -- hClose is idempotent for an already closed handle.
      hClose handle
      exists <- doesFileExist temporary
      when exists $ removeFile temporary)
    (\(temporary, handle) -> do
      B.hPut handle bytes
      hClose handle
      renameFile temporary (directory ++ "/" ++ name))

persistRuntimeProfile :: Int -> IO ()
persistRuntimeProfile profile
  | profile < 0 || profile > 2 = ioError (userError "Invalid configuration profile")
  | otherwise = do
      runtime <- getRuntimeDirectory
      let name = "config" ++ show (profile + 1) ++ ".scm"
      B.readFile (runtime ++ "/" ++ name) >>= writeConfigurationFile name
      writeConfigurationFile "startup-profile" (B8.pack (show profile ++ "\n"))

getStartupProfile :: IO Int
getStartupProfile = do
  directory <- getConfigurationDirectory
  let path = directory ++ "/startup-profile"
  exists <- doesFileExist path
  if not exists then pure 0 else do
    raw <- B.readFile path
    let parsed = readMaybe (B8.unpack raw) :: Maybe Int
    pure $ case parsed of
      Just profile | profile >= 0 && profile <= 2 -> profile
      _ -> 0
