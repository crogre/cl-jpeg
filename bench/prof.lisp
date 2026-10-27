;;; Statistical CPU profile of decoding a file N times: sbcl --load prof.lisp -- file.jpg N
(require :sb-sprof)
(load (merge-pathnames "load.lisp" (directory-namestring *load-truename*)))
(let* ((args (script-args)) (bytes (file-bytes (first args))))
  (decode-mem bytes)
  (sb-sprof:with-profiling (:max-samples 100000 :sample-interval 0.0005 :report nil :mode :cpu)
    (dotimes (i (parse-integer (second args))) (decode-mem bytes)))
  (sb-sprof:report :type :flat :max 12))
