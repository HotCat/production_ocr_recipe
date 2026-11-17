(begin
  ;; (set! mycam (init-my-camera "MV-SUA131GC#0"))
  ;; (read-camera-mat mycam)

  (set! xx #t)
  ;; (set! yy 0.1)
  ;; (set! zz 30)
  (apply-vision-monad dear-rout-1)
  (apply-vision-monad dear-rout-2)
  ;; (apply-vision-monad dear-rout-3)
  (apply-vision-monad dear-rout-4)
  (apply-vision-monad dear-rout-10)

  ;; (set-camera-property mycam "Grain" 4.0)
  ;; (set-camera-property mycam "Gamma" 120.0)
  ;; (set-camera-property mycam "Contrast" 80.0)
  ;; (set-camera-property mycam "Exposure" 8000.0)
  ;; (set-camera-property mycam "Sharpness" 10.0)

  ;; (set-camera-property mycam "ReverseX" 0.0)
  ;; (set-camera-property mycam "ReverseY" 1.0)
  )
