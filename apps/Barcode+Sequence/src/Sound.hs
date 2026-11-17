{-# LANGUAGE QuasiQuotes #-}
{-# language DeriveTraversable #-}
{-# LANGUAGE BangPatterns #-}

module Sound (
  playSound) where

import Control.Monad
import Control.Monad.Fix
import Graphics.UI.SDL as SDL
import Graphics.UI.SDL.Mixer as Mix


playSound = do
  SDL.init [SDL.InitAudio]
  result <- openAudio audioRate audioFormat audioChannels audioBuffers
  classicJungle <- Mix.loadWAV "ok.wav"
  realTech      <- Mix.loadWAV "ng.wav"
  -- ch1 <- Mix.playChannel anyChannel classicJungle 0
  -- SDL.delay 1000
  ch2 <- Mix.playChannel anyChannel realTech 0
  fix $ \loop -> do
    SDL.delay 50
    stillPlaying <- numChannelsPlaying
    when (stillPlaying /= 0) loop
  Mix.closeAudio
  SDL.quit

  where audioRate     = 22050
        audioFormat   = Mix.AudioS16LSB
        audioChannels = 2
        audioBuffers  = 4096
        anyChannel    = (-1)
