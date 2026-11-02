;;; Self-contained tests for cl-jpeg: (asdf:test-system :cl-jpeg)
;;;
;;; The fixtures in data/ are small JPEGs made with libjpeg's cjpeg, and
;;; libjpeg's djpeg output for them (binary PPM/PGM, RGB order).

(defpackage #:cl-jpeg-tests
  (:use #:common-lisp)
  (:export #:run-tests))

(in-package #:cl-jpeg-tests)

(defvar *data* (asdf:system-relative-pathname :cl-jpeg "tests/data/"))
(defvar *tests* '())
(defvar *failures* '())

(defmacro deftest (name &body body)
  `(progn (defun ,name () ,@body)
          (pushnew ',name *tests*)))

(defun check (ok format &rest args)
  (unless ok
    (push (apply #'format nil format args) *failures*)))

(defun run-tests ()
  "Runs all tests, printing failures; returns true if all passed"
  (setf *failures* '())
  (dolist (test (reverse *tests*))
    (handler-case (funcall test)
      (error (e) (check nil "~(~a~): unexpected ~a: ~a" test (type-of e) e))))
  (format t "~&cl-jpeg: ~d tests, ~d failures~%" (length *tests*) (length *failures*))
  (dolist (f (reverse *failures*)) (format t "  FAIL ~a~%" f))
  (null *failures*))

;;; Helpers

(defun data (name) (merge-pathnames name *data*))

(defun fixtures ()
  (let ((names (mapcar #'pathname-name (directory (data "*.jpg")))))
    (assert names () "No test fixtures in ~a" *data*)
    names))

(defun file-bytes (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence v s)
      v)))

(defun read-pnm (path)
  "Returns the samples, width, height and number of components of a binary PPM/PGM"
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (labels ((token ()
               (let ((c (read-byte s)))
                 (loop while (member c '(9 10 13 32)) do (setf c (read-byte s)))
                 (coerce (loop until (member c '(9 10 13 32))
                               collect (code-char c) do (setf c (read-byte s)))
                         'string))))
      (let* ((ncomp (if (string= (token) "P6") 3 1))
             (w (parse-integer (token)))
             (h (parse-integer (token))))
        (token) ; maxval
        (let ((samples (make-array (* w h ncomp) :element-type '(unsigned-byte 8))))
          (read-sequence samples s)
          (values samples w h ncomp))))))

(defun max-difference (image reference ncomp)
  "Largest difference between a cl-jpeg image (BGR) and a djpeg one (RGB)"
  (loop for i below (length reference)
        for j = (if (= ncomp 3) (+ (* 3 (floor i 3)) (- 2 (mod i 3))) i)
        maximize (abs (- (aref image j) (aref reference i)))))

(defun decode-bytes (bytes &rest args)
  (let ((d (jpeg:make-descriptor)))
    (setf (jpeg:descriptor-source-cache d) bytes)
    (apply #'jpeg:decode-stream nil :cached-source-p t :descriptor d args)))

;;; Decoding

(deftest decodes-like-djpeg
  ;; the IDCTs differ slightly, so allow a few levels
  (dolist (name (fixtures))
    (multiple-value-bind (image h w nc) (jpeg:decode-image (data (format nil "~a.jpg" name)))
      (multiple-value-bind (ref rw rh rnc) (read-pnm (data (format nil "~a.ref" name)))
        (check (and (= w rw) (= h rh) (= nc rnc)) "~a: size ~dx~dx~d, djpeg ~dx~dx~d" name w h nc rw rh rnc)
        (when (= (length image) (length ref))
          (let ((d (max-difference image ref nc)))
            (check (<= d 4) "~a: differs from djpeg by up to ~d" name d)))))))

(deftest input-paths-agree
  ;; file stream, in-memory source and user byte reader
  (dolist (name (fixtures))
    (let* ((path (data (format nil "~a.jpg" name)))
           (bytes (file-bytes path))
           (image (jpeg:decode-image path)))
      (check (equalp image (decode-bytes bytes)) "~a: in-memory decoding differs" name)
      (let ((d (jpeg:make-descriptor)) (pos 0))
        (setf (jpeg:descriptor-byte-reader d) (lambda () (prog1 (aref bytes pos) (incf pos))))
        (check (equalp image (jpeg:decode-stream nil :descriptor d)) "~a: byte reader decoding differs" name)
        (check (= pos (length bytes)) "~a: byte reader read ~d of ~d bytes" name pos (length bytes))))))

(deftest row-callback-rows
  (dolist (name (fixtures))
    (multiple-value-bind (image h w nc) (jpeg:decode-image (data (format nil "~a.jpg" name)))
      (let ((copy (make-array (length image) :element-type '(unsigned-byte 8)))
            (next 0)
            (row-bytes (* w nc)))
        (multiple-value-bind (none ch cw)
            (jpeg:decode-image (data (format nil "~a.jpg" name))
                               :row-callback (lambda (buffer start y)
                                               (check (= y next) "~a: row ~d out of order" name y)
                                               (incf next)
                                               (replace copy buffer :start1 (* y row-bytes)
                                                                    :start2 start :end2 (+ start row-bytes))))
          (check (and (null none) (= ch h) (= cw w) (= next h)) "~a: row callback results" name)
          (check (equalp copy image) "~a: row callback rows differ" name))))))

(deftest scaled-sizes
  (dolist (name (fixtures))
    (multiple-value-bind (image h w nc) (jpeg:decode-image (data (format nil "~a.jpg" name)))
      (declare (ignore image))
      (dolist (scale '(1/2 1/4 1/8))
        (multiple-value-bind (scaled sh sw snc) (jpeg:decode-image (data (format nil "~a.jpg" name)) :scale scale)
          (check (and (= sh (ceiling (* h scale))) (= sw (ceiling (* w scale))) (= snc nc)
                      (= (length scaled) (* sh sw snc)))
                 "~a: size ~dx~d at scale ~a" name sw sh scale))))))

(deftest scaled-dc-like-djpeg
  ;; at 1/8 each 4:4:4 block is its DC value, exactly as djpeg computes it
  (let ((image (jpeg:decode-image (data "base_161x97_1x1_none.jpg") :scale 1/8)))
    (multiple-value-bind (ref w h nc) (read-pnm (data "base_161x97_1x1_none_scale8.ref"))
      (declare (ignore w h))
      (check (zerop (max-difference image ref nc)) "1/8 scale differs from djpeg -scale 1/8"))))

(deftest encoder-round-trip
  (let* ((w 64) (h 48)
         (image (make-array (* w h 3) :element-type '(unsigned-byte 8))))
    (dotimes (y h)
      (dotimes (x w)
        (let ((p (* 3 (+ x (* y w)))))
          (setf (aref image p) (* 4 x) (aref image (+ p 1)) (* 5 y) (aref image (+ p 2)) 128))))
    (let ((path (merge-pathnames (format nil "cl-jpeg-test-~d.jpg" (random 1000000))
                                 (uiop:temporary-directory))))
      (unwind-protect
           (progn
             (jpeg:encode-image path image 3 h w :q-factor 95)
             (multiple-value-bind (back bh bw) (jpeg:decode-image path)
               (check (and (= bh h) (= bw w)) "round trip size ~dx~d" bw bh)
               (let ((worst (loop for i below (length image) maximize (abs (- (aref back i) (aref image i))))))
                 (check (<= worst 24) "round trip differs by up to ~d" worst))))
        (when (probe-file path) (delete-file path))))))

;;; Malformed input: header values are validated before use (the decoder is
;;; compiled without runtime checks), so corrupt files must only signal
;;; JPEG-DECODER-ERROR conditions.

(defun segments (bytes)
  "Returns (marker . offset) for each marker segment before the first scan's data"
  (loop with pos = 2
        while (< (1+ pos) (length bytes))
        for marker = (aref bytes (1+ pos))
        collect (cons marker pos)
        until (= marker #xda)
        do (incf pos (+ 2 (* 256 (aref bytes (+ pos 2))) (aref bytes (+ pos 3))))))

(defun sos-offsets (bytes)
  "Returns the offsets of all SOS markers (FF DA cannot occur in scan data)"
  (loop for pos from 0 below (1- (length bytes))
        when (and (= (aref bytes pos) #xff) (= (aref bytes (1+ pos)) #xda))
          collect pos))

(defun segment-offset (bytes marker &optional (n 0))
  (cdr (nth n (remove marker (segments bytes) :key #'car :test #'/=))))

(defun splice (bytes start end &optional (insert #()))
  "BYTES with START..END replaced by INSERT"
  (concatenate '(vector (unsigned-byte 8)) (subseq bytes 0 start) insert (subseq bytes end)))

(defun decode-error (bytes)
  "Decodes BYTES, returning the condition signalled, or NIL"
  (handler-case (progn (decode-bytes bytes) nil)
    (error (e) e)))

(deftest rejects-invalid-headers
  (let ((baseline (file-bytes (data "base_33x17_1x1_3B.jpg")))
        (progressive (file-bytes (data "prog_33x17_2x2_none.jpg"))))
    (flet ((expect (condition-type bytes what)
             (let ((e (decode-error bytes)))
               (check (typep e condition-type) "~a: expected ~a, got ~a" what condition-type
                      (and e (type-of e))))))
      ;; sampling factor 0 (first component's HV byte in SOF)
      (let ((b (copy-seq baseline)) (sof (segment-offset baseline #xc0)))
        (setf (aref b (+ sof 11)) #x01)
        (expect 'jpeg:invalid-jpeg-data b "H = 0"))
      ;; more than 256 Huffman codes (all 16 counts of the first DHT table at 255)
      (let ((b (copy-seq baseline)) (dht (segment-offset baseline #xc4)))
        (fill b 255 :start (+ dht 5) :end (+ dht 21))
        (expect 'jpeg:invalid-jpeg-data b "DHT with too many codes"))
      ;; a scan using a Huffman table that was never defined
      (let* ((dht (segment-offset baseline #xc4))
             (len (+ 2 (* 256 (aref baseline (+ dht 2))) (aref baseline (+ dht 3)))))
        (expect 'jpeg:invalid-jpeg-data (splice baseline dht (+ dht len)) "undefined Huffman table"))
      ;; quantization table index out of range
      (let ((b (copy-seq baseline)) (sof (segment-offset baseline #xc0)))
        (setf (aref b (+ sof 12)) 9)
        (expect 'jpeg:invalid-jpeg-data b "quantization table 9"))
      ;; progressive AC scan with a spectral end beyond 63
      (let* ((b (copy-seq progressive))
             (sos (find-if (lambda (pos) (plusp (aref b (+ pos 5 (* 2 (aref b (+ pos 4))))))) ; Ss > 0
                           (sos-offsets b)))
             (ncomp (aref b (+ sos 4))))
        (setf (aref b (+ sos 6 (* 2 ncomp))) 149) ; Se
        (expect 'jpeg:invalid-jpeg-data b "progressive AC scan with Se = 149"))
      ;; truncated data
      (expect 'jpeg:truncated-jpeg-data (subseq baseline 0 (floor (length baseline) 2)) "truncated file"))))

(deftest ycck-marker-on-color-image
  ;; an Adobe APP14 marker claiming YCCK on a 3-component image used to
  ;; overflow the output buffer; it is now ignored for non-CMYK images
  (let* ((bytes (file-bytes (data "base_33x17_1x1_3B.jpg")))
         (app14 #(#xff #xee 0 14 65 100 111 98 101 0 100 0 0 0 0 2))
         (marked (splice bytes 2 2 app14)))
    (check (equalp (decode-bytes marked) (decode-bytes bytes)) "APP14 YCCK marker changes a YCbCr image")))

(deftest corrupt-files-signal-decoder-errors
  ;; deterministic random corruption of every fixture; any outcome but a
  ;; JPEG-DECODER-ERROR (or success) indicates an unchecked value
  (let ((seed 12345))
    (flet ((random* (n)
             ;; small deterministic generator, so the cases are the same everywhere
             (setf seed (mod (+ (* seed 1103515245) 12345) 2147483648))
             (mod (ash seed -8) n)))
     (dolist (name (fixtures))
      (let ((bytes (file-bytes (data (format nil "~a.jpg" name)))))
        (dotimes (i 40)
          (let ((b (copy-seq bytes)))
            (dotimes (k (1+ (random* 4)))
              (let ((pos (random* (length b))))
                (setf (aref b pos) (if (zerop (random* 2))
                                       (random* 256)
                                       (logxor (aref b pos) (ash 1 (random* 8)))))))
            (dolist (scale '(1 1/4))
              (handler-case (decode-bytes b :scale scale)
                (jpeg:jpeg-decoder-error () nil)
                (error (e)
                  (check nil "~a mutation ~d at scale ~a: ~a ~a" name i scale (type-of e) e)))))))))))
