;;; NEON SIMD through sb-simd is used where available (SBCL on ARM64)
#+(and sbcl arm64)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (and (ignore-errors (require :sb-simd) t)
             (find-package "SB-SIMD-NEON"))
    (pushnew :cl-jpeg-neon *features*)))

(defpackage #:jpeg
  (:use #:common-lisp)
  #+cl-jpeg-neon (:local-nicknames (#:neon #:sb-simd-neon))
  (:nicknames #:cl-jpeg)
  (:export #:encode-image
	   #:encode-image-stream
           #:decode-stream
           #:decode-image
	   #:jpeg-error #:jpeg-encoder-error #:jpeg-decoder-error #:unsupported-jpeg-format #:unrecognized-file-format
	   #:convert-cmyk-to-rgb
	   #:allocate-buffer
	   #:jpeg-file-dimensions
           #:jpeg-to-bmp
	   #:descriptor-source-cache
	   #:read-dht
	   #:inverse-llm-dct #:llm-dct
	   #:make-descriptor #:descriptor-byte-reader))
