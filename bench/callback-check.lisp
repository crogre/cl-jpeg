;;; Checks that decoding with a row callback yields the same rows, in order,
;;; as decoding to an image array, at full size and (where supported) scaled
(load (merge-pathnames "load.lisp" (directory-namestring *load-truename*)))
(defun rows-via-callback (f h w nc scale-args)
  "Decodes F with a row callback, collecting the rows into an image array.
Returns the array, or NIL if rows came out of order or the results differ."
  (let ((copy (make-array (* h w nc) :element-type '(unsigned-byte 8)))
        (next 0)
        (ok t))
    (multiple-value-bind (none ch cw)
        (apply #'jpeg:decode-image f
               :row-callback (lambda (buf start y)
                               (unless (= y next) (setf ok nil))
                               (incf next)
                               (replace copy buf :start1 (* y w nc) :start2 start
                                                 :end2 (+ start (* w nc))))
               scale-args)
      (and ok (null none) (= next h) (= ch h) (= cw w) copy))))

(let ((bad 0) (n 0)
      (scales (if (search "SCALE" (documentation 'jpeg:decode-stream 'function)) '(1 1/4) '(1))))
  (dolist (f (directory (merge-pathnames "check/*.jpg" (directory-namestring *load-truename*))))
    (dolist (scale scales)
      (let ((scale-args (if (= scale 1) '() (list :scale scale))))
        (incf n)
        (multiple-value-bind (image h w nc) (apply #'jpeg:decode-image f scale-args)
          (unless (equalp image (rows-via-callback f h w nc scale-args))
            (incf bad)
            (format t "differs: ~a at scale ~a~%" (file-namestring f) scale))))))
  (format t "~d decodes, ~d differ with a row callback~%" n bad))
