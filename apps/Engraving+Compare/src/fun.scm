(begin
  (apply-vision-monad dear-rout-5)
  (apply-vision-monad dear-rout-3)
  (let ((frame (read-camera-mat mycam)))
    (apply-vision-monad dear-rout-9 frame)
    (set! finalMat frame))
  (apply-vision-monad dear-rout-6))
