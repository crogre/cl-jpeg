;;; Checks that IDCT-BLOCK (NEON and the sparse/DC-only paths, where present)
;;; matches the scalar IDCT exactly on random blocks
(load (merge-pathnames "load.lisp" (directory-namestring *load-truename*)))
(in-package :jpeg)
(defun last-index (block)
  "zigzag index of the last nonzero coefficient"
  (loop for k from 63 downto 0
        when (/= 0 (aref block (aref +zigzag-natural+ k))) return k
        finally (return 0)))
(defun run-idct (block ws plane)
  ;; idct-block takes the last coefficient index on some branches
  (if (search "LAST is" (documentation 'idct-block 'function))
      (funcall #'idct-block block ws plane 8 32 (last-index block))
      (funcall #'idct-block block ws plane 8 32)))
(let ((bad 0) (n 300000)
      (block (make-array 64 :element-type '(signed-byte 32)))
      (ws (make-array 64 :element-type 'fixnum))
      (p1 (make-array (* 64 4) :element-type 'uint8))
      (p2 (make-array (* 64 4) :element-type 'uint8)))
  (dotimes (i n)
    (fill block 0)
    (case (random 4)
      (0 (setf (aref block 0) (- (random 4095) 2047)))                 ; DC only
      (1 (dotimes (j (1+ (random 6)))                                   ; top left 4x4
           (setf (aref block (aref +zigzag-natural+ (random 10))) (- (random 4095) 2047))))
      (2 (dotimes (j (1+ (random 6)))                                   ; sparse anywhere
           (setf (aref block (random 64)) (- (random 4095) 2047))))
      (3 (dotimes (j 64) (setf (aref block j) (- (random 4095) 2047))))) ; dense
    (idct-block-scalar block ws p1 8 32)
    (run-idct block ws p2)
    (unless (equalp p1 p2)
      (incf bad)
      (when (< bad 3) (format t "mismatch: ~a~% scalar ~a~% idct   ~a~%" block (subseq p1 8 16) (subseq p2 8 16)))))
  (format t "~d random blocks, ~d mismatches~%" n bad))

;;; The NEON 4x4 reduced IDCT against the scalar one, where both exist
(when (fboundp 'idct-4x4-neon)
  (let ((bad 0) (n 200000)
        (block (make-array 64 :element-type '(signed-byte 32)))
        (ws (make-array 64 :element-type 'fixnum))
        (p1 (make-array 256 :element-type 'uint8))
        (p2 (make-array 256 :element-type 'uint8)))
    (dotimes (i n)
      (fill block 0)
      (dotimes (u 4) (dotimes (v 4) (setf (aref block (+ (* u 8) v)) (- (random 4095) 2047))))
      (idct-4x4-scalar block ws p1 4 16)
      (funcall 'idct-4x4-neon block p2 4 16)
      (unless (equalp p1 p2) (incf bad)))
    (format t "~d random blocks, ~d mismatches (NEON vs scalar 4x4)~%" n bad)))
