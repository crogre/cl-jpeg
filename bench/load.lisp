;;; Loads cl-jpeg from this checkout, plus helpers shared by the bench scripts
(load "~/quicklisp/setup.lisp")
(push (merge-pathnames "../" (directory-namestring *load-truename*)) asdf:*central-registry*)
;; CL_JPEG_SIMD=1 in the environment selects the NEON build; always recompiled,
;; as ASDF does not notice feature changes
(if (let ((v (sb-ext:posix-getenv "CL_JPEG_SIMD"))) (and v (string/= v "") (string/= v "0")))
    (pushnew :cl-jpeg-simd *features*)
    (setf *features* (remove :cl-jpeg-simd *features*)))
(let ((*compile-verbose* nil) (*compile-print* nil))
  (handler-bind ((warning #'muffle-warning))
    (asdf:load-system :cl-jpeg :force t)))
(defun file-bytes (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s) v)))
(defun decode-mem (bytes)
  "Decodes JPEG data from memory, as decode-image would but without file I/O"
  (let ((d (jpeg:make-descriptor)))
    (setf (jpeg:descriptor-source-cache d) bytes)
    (jpeg:decode-stream nil :cached-source-p t :descriptor d)))
(defun script-args () (rest (member "--" sb-ext:*posix-argv* :test #'string=)))
