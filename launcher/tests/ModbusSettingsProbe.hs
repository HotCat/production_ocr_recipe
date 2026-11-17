module Main where
import Barcode (modbusInit, modbusOk)
-- Test entry point only: connect to a loopback stub, never initialize a camera.
main :: IO ()
main = modbusInit >> modbusOk
