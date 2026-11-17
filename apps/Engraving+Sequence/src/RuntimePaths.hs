module RuntimePaths (getRuntimeDirectory, withRuntimeConfigFile) where

import Data.Maybe (fromMaybe)
import System.Environment (lookupEnv)
import System.IO (Handle, IOMode, withFile)

-- The installed launcher supplies a private directory for each user's session.
-- Keep the original location when running directly through Stack.
getRuntimeDirectory :: IO FilePath
getRuntimeDirectory = fromMaybe "/dev/shm/sequence3" <$> lookupEnv "SEQUENCE_RUNTIME_DIR"

withRuntimeConfigFile :: FilePath -> IOMode -> (Handle -> IO a) -> IO a
withRuntimeConfigFile name mode action = do
  directory <- getRuntimeDirectory
  withFile (directory ++ "/" ++ name) mode action
