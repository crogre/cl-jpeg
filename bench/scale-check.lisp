;;; Compares scaled decoding (1/2, 1/4, 1/8) with djpeg -scale, and with the
;;; full-size decode averaged over 2x2, 4x4 or 8x8 pixels. Prints the worst
;;; maximum and mean differences per scale.
(load (merge-pathnames "load.lisp" (directory-namestring *load-truename*)))
(defun read-pnm (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (labels ((tok () (let ((c (read-byte s)))
                       (loop while (member c '(32 10 13 9)) do (setf c (read-byte s)))
                       (coerce (loop while (not (member c '(32 10 13 9))) collect (code-char c)
                                     do (setf c (read-byte s))) 'string))))
      (let* ((magic (tok)) (w (parse-integer (tok))) (h (parse-integer (tok))) (nc (progn (tok) (if (string= magic "P6") 3 1)))
             (d (make-array (* w h nc) :element-type '(unsigned-byte 8))))
        (read-sequence d s) (values d w h nc)))))
(defun box (full w h nc d sw sh)
  "Averages DxD boxes of the full image (partial boxes at the edges)"
  (let ((out (make-array (* sw sh nc) :element-type '(unsigned-byte 8))))
    (dotimes (y sh out)
      (dotimes (x sw)
        (dotimes (c nc)
          (let ((sum 0) (n 0))
            (loop for yy from (* y d) below (min h (* (1+ y) d)) do
              (loop for xx from (* x d) below (min w (* (1+ x) d)) do
                (incf sum (aref full (+ c (* nc (+ xx (* yy w)))))) (incf n)))
            (setf (aref out (+ c (* nc (+ x (* y sw))))) (round sum n))))))))
(let* ((dir (merge-pathnames "check/" (directory-namestring *load-truename*)))
       (names (with-open-file (l (merge-pathnames "list.txt" dir)) (loop for x = (read-line l nil) while x collect x))))
  (dolist (d '(2 4 8))
    (let ((worst-djpeg 0) (mean-djpeg 0) (worst-box 0) (mean-box 0) (errors 0) (n 0))
      (dolist (name names)
        (handler-case
            (multiple-value-bind (full h w nc) (jpeg:decode-image (merge-pathnames (concatenate 'string name ".jpg") dir))
              (multiple-value-bind (img sh sw snc) (jpeg:decode-image (merge-pathnames (concatenate 'string name ".jpg") dir)
                                                                      :scale (/ 1 d))
                (multiple-value-bind (ref rw rh) (read-pnm (merge-pathnames (format nil "scaled/~a_~d.ref" name d) dir))
                  (assert (and (= sw rw) (= sh rh) (= snc nc)))
                  (let ((boxed (box full w h nc d sw sh)) (m1 0) (s1 0) (m2 0) (s2 0))
                    (dotimes (i (length img))
                      (let* ((j (if (= nc 3) (+ (* 3 (floor i 3)) (- 2 (mod i 3))) i)) ; BGR vs RGB
                             (e1 (abs (- (aref img j) (aref ref i))))
                             (e2 (abs (- (aref img i) (aref boxed i)))))
                        (setf m1 (max m1 e1) m2 (max m2 e2)) (incf s1 e1) (incf s2 e2)))
                    (incf n)
                    (setf worst-djpeg (max worst-djpeg m1) worst-box (max worst-box m2)
                          mean-djpeg (max mean-djpeg (/ s1 (length img) 1.0))
                          mean-box (max mean-box (/ s2 (length img) 1.0)))))))
          (error (e) (incf errors) (when (< errors 4) (format t "~a 1/~d: ~a~%" name d e)))))
      (format t "1/~d: ~d images, ~d errors; vs djpeg max ~d, worst mean ~,2f; vs box-filtered full decode max ~d, worst mean ~,2f~%"
              d n errors worst-djpeg mean-djpeg worst-box mean-box))))
