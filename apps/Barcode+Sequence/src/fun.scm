(begin
  (apply-vision-monad dear-rout-5)
  (apply-vision-monad dear-rout-3)

  (let ((frame (read-camera-mat mycam)))
    ;; Display the full captured image, as in Engraving+Sequence.
    ;; Recognition and previews may crop/rotate their own copies.
    (set! finalMat frame)
    (apply-vision-monad dear-rout-9 frame)
    (apply-vision-monad dear-rout-7 frame)
    (apply-vision-monad dear-rout-8 frame)
    )

  (apply-vision-monad dear-rout-6)
  )
