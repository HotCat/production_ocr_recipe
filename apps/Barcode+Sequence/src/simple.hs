
mya j = do
  i <- camera 3.3 6.3 >>= canny 0.3 0.8 >>= tessertact 0.5
  j <- return i >>= output >>= display "kk0"
  position j k


-- myb j = do
--   i <- camera 3.3 6.3 >>= canny 0.3 0.8
--   output i >>= display "kk0"

  
