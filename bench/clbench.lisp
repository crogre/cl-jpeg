;;; Prints the median time to decode each file given after "--", in milliseconds
(load (merge-pathnames "load.lisp" (directory-namestring *load-truename*)))
(defun now-ms () (/ (get-internal-real-time) (/ internal-time-units-per-second 1000.0d0)))
(dolist (path (script-args))
  (let ((bytes (file-bytes path)) (times '()) (total 0))
    (decode-mem bytes)
    (loop while (and (< (length times) 32) (or (< total 3000) (< (length times) 5))) do
      (let ((t0 (now-ms)))
        (decode-mem bytes)
        (let ((dt (- (now-ms) t0))) (push dt times) (incf total dt))))
    (format t "~a ~,2f~%" (file-namestring path) (nth (floor (length times) 2) (sort times #'<)))
    (finish-output)))
