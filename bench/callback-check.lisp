;;; Checks that decoding with a row callback yields the same rows, in order,
;;; as decoding to an image array
(load (merge-pathnames "load.lisp" (directory-namestring *load-truename*)))
(let ((bad 0) (n 0))
  (dolist (f (directory (merge-pathnames "check/*.jpg" (directory-namestring *load-truename*))))
    (incf n)
    (multiple-value-bind (image h w nc) (jpeg:decode-image f)
      (let ((copy (make-array (length image) :element-type '(unsigned-byte 8)))
            (next 0) (ok t))
        (multiple-value-bind (none ch cw) (jpeg:decode-image f :row-callback
                                                             (lambda (buf start y)
                                                               (unless (= y next) (setf ok nil))
                                                               (incf next)
                                                               (replace copy buf :start1 (* y w nc) :start2 start
                                                                                 :end2 (+ start (* w nc)))))
          (unless (and ok (null none) (= next h) (= ch h) (= cw w) (equalp copy image))
            (incf bad) (format t "differs: ~a~%" (file-namestring f)))))))
  (format t "~d images, ~d differ with a row callback~%" n bad))
