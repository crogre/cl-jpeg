;;; ANSI Common Lisp (mostly) baseline JPEG encoder/decoder implementation
;;; Copyright [c] 1999,2015-2017 Eugene Zaikonnikov <eugene@funcall.org>
;;;               
;;; This software is distributed under the terms of BSD-like license
;;; [see LICENSE for details]

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; This software was sponsored by Kelly E. Murray
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; Two main functions available:
;;;
;;; (encode-image filename image ncomp h w &key sampling q-tabs q-factor), where:
;;; filename - output file name
;;; ncomp - number of components (1-4)
;;; h, w - source image height and width respectively
;;; image - array of B, G, R pixels in case of three component image,
;;;         array of grayscale pixels in case of single component,
;;;         array of 2 or 4 pixels in the case of two or four component image respectively
;;; :q-tabs - specifies quantization tables vector, should be 1 for 1,
;;;           2 for 2, 2 for 3 and 4 entries for 4 components
;;; :sampling - sampling frequency for ncomp components by X and Y axis,
;;;             e.g. '((2 2) (1 1) (1 1)) for three components, can be omitted
;;;             for grayscale and RGB images
;;; :q-factor - quality specifier (1-64), default is 64
;;; Returns nothing of practical use
;;;
;;; (decode-image filename &key buffer (colorspace-conversion t))
;;; filename - jpeg file name
;;; Returns (multiple-valued) IMAGE array in the same format as encoder source image,
;;; image HEIGHT and image WIDTH
;;; A pre-allocated BUFFER can be specified (see JPEG:ALLOCATE-BUFFER).
;;; If :colorspace-conversion is NIL, no conversion from YUV space is performed.
;;;
;;; For those impatient additional function defined:
;;; (jpeg-to-bmp &key infile outfile)
;;; Converts JPEG image specified by infile into Microsoft Windows 24-bit BMP format (outfile),
;;; returns NIL
;;;
;;; Additionaly, you may use more user-friendly version of encode-image: encode-wrapper.
;;; (encoding-wrapper filename image ncomp h w &key quality)
;;; All parameters have the same meaning as in encode-image, except quality.
;;; It is an integer value ranging 1 to 5 which specifies
;;; subjective quality of a resulting image.

;;; Technical details: encoder produces interleaved jpeg file, without restarts.
;;; In a case of 3 components image will be written in JFIF format.

;;; Decoder can deal with *almost* all baseline jpeg files, regardless JFIF or not.

;;; It supports restarts, interleaved/noninterleaved files, multiscan images, 1 to 4 color
;;; channels, up to 4 quantization tables and two sets of huffman tables with random order
;;; of their definition inside the image. Decoder *does not* support DNL marker, due to
;;; it's rarity and amount of work needed to implement it, so decoder isn't baseline in a
;;; strict sense.

;;; Both encoder and decoder utilize Loeffer, Ligtenberg and Moschytz integer discrete
;;; cosine transform algorithms with 12 multiplications in each loop.

;;; Based on CCITT Rec. T.81
;;; "Information technology - digital compression and coding of continious-tone still images
;;; - requirements and guidelines".
;;; Credits:
;;; to the Independent JPEG Group -
;;; colorspace conversion and DCT algorithms were adopted from their sources;
;;; to Jeff Dalton for his wise paper "Common Lisp Pitfalls".

(in-package #:jpeg)

(declaim (inline csize quantize get-average zigzag read-jpeg-byte
                 llm-dct descale crunch colorspace-convert subsample inverse-llm-dct
                 dequantize extend peek-bits skip-bits get-bits huff-decode
                 decode-block idct-block
                 write-bits limit))

(deftype uint8 () '(unsigned-byte 8))
(deftype uint8-array () '(simple-array uint8 (*)))
(deftype uint8-2d-array () '(simple-array uint8-array (*)))

(deftype suint8 () '(signed-byte 8))
(deftype sint8-array () '(simple-array sint8 (*)))
(deftype sint8-2d-array () '(simple-array sint8-array (*)))

(deftype sint16 () '(signed-byte 16))
(deftype sint16-array () '(simple-array sint16 (*)))
(deftype sint16-2d-array () '(simple-array sint16-array (*)))

(deftype uint16 () '(unsigned-byte 16))
(deftype uint16-array () '(simple-array uint16 (*)))
(deftype uint16-2d-array () '(simple-array uint16-array (*)))

(deftype fixnum-array () '(simple-array fixnum (*)))
(deftype sint32-array () '(simple-array (signed-byte 32) (*)))
(deftype fixnum-2d-array () '(simple-array fixnum-array (*)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *optimize* '(optimize (safety 0) (space 0) (debug 0) (speed 3))))

(eval-when (:compile-toplevel :load-toplevel :execute)
;;; For ease of reference
(defmacro u8ref (data x y)
  `(the uint8 (aref (the uint8-array (aref (the uint8-2d-array ,data) ,y)) ,x)))

(defmacro s16ref (data x y)
  `(the sint16 (aref (the sint16-array (aref (the sint16-2d-array ,data) ,y)) ,x)))

(defmacro u16ref (data x y)
  `(the uint16 (aref (the uint16-array (aref (the uint16-2d-array ,data) ,y)) ,x)))

(defmacro fixref (data x y)
  `(the fixnum (aref (the fixnum-array (aref (the fixnum-2d-array ,data) ,y)) ,x)))

;;; Integer arithmetic wrappers
(defmacro plus (a b)
  `(the fixnum (+ (the fixnum ,a) (the fixnum ,b))))

(defmacro minus (a b)
  #+(or clisp abcl)
  `(- ,a ,b)
  #-(or clisp abcl)
  `(the fixnum (- (the fixnum ,a) (the fixnum ,b))))

(defmacro mul (a b)
  `(the fixnum (* (the fixnum ,a) (the fixnum ,b))))

(defmacro plus3 (x y z)
  `(plus (plus ,x ,y) ,z))

(defmacro mul3 (x y z)
  `(mul (mul ,x ,y) ,z)))

;;; Somewhat silly, but who knows...
(when (/= (integer-length most-positive-fixnum)
          (integer-length most-negative-fixnum))
  (error "Can't compile with asymmetric fixnums!"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Here we define some constants (markers, quantization and huffman tables etc.)

(defmacro define-constant (name value &optional doc)
  `(defconstant ,name (if (boundp ',name) (symbol-value ',name) ,value)
     ,@(when doc (list doc))))

(eval-when (:compile-toplevel :load-toplevel)

(defun uint8-array (&rest contents)
  (the uint8-array (make-array (length contents) :element-type 'uint8
			       :initial-contents contents)))
  
(defun 2d-uint8-array (&rest contents)
  (let ((nrow (length contents)))
    (the uint8-2d-array
	 (make-array nrow
		:element-type 'uint8-array
		:initial-contents
                (loop for row in contents
                      collecting (make-array (length row) :element-type 'uint8
                                             :initial-contents row))))))

(defun 2d-sint16-array (&rest contents)
  (let ((nrow (length contents)))
    (the sint16-2d-array
	 (make-array nrow
		:element-type 'sint16-array
		:initial-contents
                (loop for row in contents
                      collecting (make-array (length row) :element-type 'sint16
                                             :initial-contents row))))))

;;; Source huffman tables for the encoder
(define-constant +luminance-dc-bits+
    (uint8-array #x00 #x01 #x05 #x01 #x01 #x01 #x01 #x01
		 #x01 #x00 #x00 #x00 #x00 #x00 #x00 #x00))

(define-constant +luminance-dc-values+
    (uint8-array #x00 #x01 #x02 #x03 #x04 #x05 #x06 #x07 #x08 #x09 #x0a #x0b))

(define-constant +chrominance-dc-bits+
    (uint8-array #x00 #x03 #x01 #x01 #x01 #x01 #x01 #x01
		 #x01 #x01 #x01 #x00 #x00 #x00 #x00 #x00))

(define-constant +chrominance-dc-values+
    (uint8-array #x00 #x01 #x02 #x03 #x04 #x05 #x06 #x07 #x08 #x09 #x0a #x0b))

(define-constant +luminance-ac-bits+
    (uint8-array #x00 #x02 #x01 #x03 #x03 #x02 #x04 #x03
		 #x05 #x05 #x04 #x04 #x00 #x00 #x01 #x7d))

(define-constant +luminance-ac-values+
    (uint8-array
     #x01 #x02 #x03 #x00 #x04 #x11 #x05 #x12
     #x21 #x31 #x41 #x06 #x13 #x51 #x61 #x07
     #x22 #x71 #x14 #x32 #x81 #x91 #xa1 #x08
     #x23 #x42 #xb1 #xc1 #x15 #x52 #xd1 #xf0
     #x24 #x33 #x62 #x72 #x82 #x09 #x0a #x16
     #x17 #x18 #x19 #x1a #x25 #x26 #x27 #x28
     #x29 #x2a #x34 #x35 #x36 #x37 #x38 #x39
     #x3a #x43 #x44 #x45 #x46 #x47 #x48 #x49
     #x4a #x53 #x54 #x55 #x56 #x57 #x58 #x59
     #x5a #x63 #x64 #x65 #x66 #x67 #x68 #x69
     #x6a #x73 #x74 #x75 #x76 #x77 #x78 #x79
     #x7a #x83 #x84 #x85 #x86 #x87 #x88 #x89
     #x8a #x92 #x93 #x94 #x95 #x96 #x97 #x98
     #x99 #x9a #xa2 #xa3 #xa4 #xa5 #xa6 #xa7
     #xa8 #xa9 #xaa #xb2 #xb3 #xb4 #xb5 #xb6
     #xb7 #xb8 #xb9 #xba #xc2 #xc3 #xc4 #xc5
     #xc6 #xc7 #xc8 #xc9 #xca #xd2 #xd3 #xd4
     #xd5 #xd6 #xd7 #xd8 #xd9 #xda #xe1 #xe2
     #xe3 #xe4 #xe5 #xe6 #xe7 #xe8 #xe9 #xea
     #xf1 #xf2 #xf3 #xf4 #xf5 #xf6 #xf7 #xf8
     #xf9 #xfa))

(define-constant +chrominance-ac-bits+
    (uint8-array #x00 #x02 #x01 #x02 #x04 #x04 #x03 #x04
		#x07 #x05 #x04 #x04 #x00 #x01 #x02 #x77))

(define-constant +chrominance-ac-values+
    (uint8-array
     #x00 #x01 #x02 #x03 #x11 #x04 #x05 #x21
     #x31 #x06 #x12 #x41 #x51 #x07 #x61 #x71
     #x13 #x22 #x32 #x81 #x08 #x14 #x42 #x91
     #xa1 #xb1 #xc1 #x09 #x23 #x33 #x52 #xf0
     #x15 #x62 #x72 #xd1 #x0a #x16 #x24 #x34
     #xe1 #x25 #xf1 #x17 #x18 #x19 #x1a #x26
     #x27 #x28 #x29 #x2a #x35 #x36 #x37 #x38
     #x39 #x3a #x43 #x44 #x45 #x46 #x47 #x48
     #x49 #x4a #x53 #x54 #x55 #x56 #x57 #x58
     #x59 #x5a #x63 #x64 #x65 #x66 #x67 #x68
     #x69 #x6a #x73 #x74 #x75 #x76 #x77 #x78
     #x79 #x7a #x82 #x83 #x84 #x85 #x86 #x87
     #x88 #x89 #x8a #x92 #x93 #x94 #x95 #x96
     #x97 #x98 #x99 #x9a #xa2 #xa3 #xa4 #xa5
     #xa6 #xa7 #xa8 #xa9 #xaa #xb2 #xb3 #xb4
     #xb5 #xb6 #xb7 #xb8 #xb9 #xba #xc2 #xc3
     #xc4 #xc5 #xc6 #xc7 #xc8 #xc9 #xca #xd2
     #xd3 #xd4 #xd5 #xd6 #xd7 #xd8 #xd9 #xda
     #xe2 #xe3 #xe4 #xe5 #xe6 #xe7 #xe8 #xe9
     #xea #xf2 #xf3 #xf4 #xf5 #xf6 #xf7 #xf8
     #xf9 #xfa))

;;;Zigzag encoding matrix
(define-constant +zigzag-index+
  (2d-uint8-array '(0  1  5  6 14 15 27 28)
                  '(2  4  7 13 16 26 29 42)
                  '(3  8 12 17 25 30 41 43)
                  '(9 11 18 24 31 40 44 53)
                  '(10 19 23 32 39 45 52 54)
                  '(20 22 33 38 46 51 55 60)
                  '(21 34 37 47 50 56 59 61)
                  '(35 36 48 49 57 58 62 63)))

;;;JPEG file markers
(defconstant +M_COM+ #xfe)
(defconstant +M_SOF0+ #xc0)
(defconstant +M_SOF2+ #xc2)
(defconstant +M_DHT+ #xc4)
(defconstant +M_RST0+ #xd0)
(defconstant +M_RST7+ #xd7)
(defconstant +M_SOI+ #xd8)
(defconstant +M_EOI+ #xd9)
(defconstant +M_SOS+ #xda)
(defconstant +M_DQT+ #xdb)
(defconstant +M_DNL+ #xdc)
(defconstant +M_DRI+ #xdd)
(defconstant +M_DAC+ #xcc)
(defconstant +M_APP0+ #xe0)
(defconstant +M_APP14+ #xee)

;;; Default quantization tables
(define-constant +q-luminance+
  (2d-uint8-array '(16 11 10 16 24 40 51 61)
                  '(12 12 14 19 26 58 60 55)
                  '(14 13 16 24 40 57 69 56)
                  '(14 17 22 29 51 87 80 62)
                  '(18 22 37 56 68 109 103 77)
                  '(24 35 55 64 81 104 113 92)
                  '(49 64 78 87 103 121 120 101)
                  '(72 92 95 98 112 100 103 99)))

(define-constant +q-chrominance+
  (2d-uint8-array '(17 18 24 47 99 99 99 99)
                  '(18 21 26 66 99 99 99 99)
                  '(24 26 56 99 99 99 99 99)
                  '(47 66 99 99 99 99 99 99)
                  '(99 99 99 99 99 99 99 99)
                  '(99 99 99 99 99 99 99 99)
                  '(99 99 99 99 99 99 99 99)
                  '(99 99 99 99 99 99 99 99)))

(define-constant +q-luminance-hi+
  (2d-uint8-array '(10 7 6 10 15 25 32 38)
                  '(8 8 9 12 16 36 38 34)
                  '(9 8 10 15 25 36 43 35)
                  '(9 11 14 18 32 54 50 39)
                  '(11 14 23 35 42 68 64 48)
                  '(15 22 34 40 51 65 71 58)
                  '(31 40 49 54 64 76 75 63)
                  '(45 58 59 61 70 62 64 62)))

(define-constant +q-chrominance-hi+
  (2d-uint8-array '(11 11 15 29 62 62 62 62)
                  '(11 13 16 41 62 62 62 62)
                  '(15 16 35 62 62 62 62 62)
                  '(29 41 62 62 62 62 62 62)
                  '(62 62 62 62 62 62 62 62)
                  '(62 62 62 62 62 62 62 62)
                  '(62 62 62 62 62 62 62 62)
                  '(62 62 62 62 62 62 62 62)))

(defconstant +max-sample+ 255)

)

;;; Quantization performance test, each branch quantizes 30000 random matrixes
(eval-when (:compile-toplevel)

  (defconstant +quantize-calibration-loops+ 30000)
  
  (format t "Performing compile-time optimization.. please wait.~%")
  (finish-output)

  (defun qat1 ()
    (loop for i fixnum from 1 to +quantize-calibration-loops+ do
		(loop for row across +q-luminance+ do
		      (loop for q-coef fixnum across row
			    maximize (round (random 128) q-coef)))))

  (defun qat2 ()
    (loop for i fixnum from 1 to +quantize-calibration-loops+ do
		(loop for q-row across +q-luminance+ do
		      (loop for val fixnum = (random 128)
			    for absval fixnum = (abs val)
			    for qc fixnum across q-row
			    maximize
			    (cond ((< absval (ash qc -1))
				   0)
				  ((<= absval qc)
				   (if (minusp val)
				       -1
				     1))
				  ((<= (ash absval -1) qc)
				   (if (zerop (logand absval 1))
				       (if (minusp val)
					   -1
					 1)
				     (if (minusp val)
					 -2
				       2)))
				  (t
				   (round val qc)))))))

  (compile 'qat1)
  (compile 'qat2)
  
  (defvar *quantize-optimization*
    (<= (let ((time1 (get-internal-run-time)))
	  (qat1)
	  (minus (get-internal-run-time) time1))
	(let ((time1 (get-internal-run-time)))
	  (qat2)
	  (minus (get-internal-run-time) time1))))
  (format t "Done.~%")
  (finish-output))

(define-constant +q-tables+ (vector +q-luminance+ +q-chrominance+))

;;; This table is used to map coefficients into SSSS value
(define-constant +csize+ (make-array 2047
                                 :initial-contents
                                 (loop for i fixnum from 0 to 2046
                                       collecting (integer-length (abs (minus i 1023))))))

;;; Some constants for colorspace mapper
(defconstant shift (1- (integer-length (ash most-positive-fixnum -7))))
(defconstant +.299+ (round (+ (* 0.299 (ash 1 shift)) 0.5)))
(defconstant +.587+ (round (+ (* 0.587 (ash 1 shift)) 0.5)))
(defconstant +.114+ (round (+ (* 0.114 (ash 1 shift)) 0.5)))
(defconstant +-.1687+ (round (+ (* -0.1687 (ash 1 shift)) 0.5)))
(defconstant +-.3313+ (round (+ (* -0.3313 (ash 1 shift)) 0.5)))
(defconstant +-.4187+ (round (+ (* -0.4187 (ash 1 shift)) 0.5)))
(defconstant +-.0813+ (round (+ (* -0.0813 (ash 1 shift)) 0.5)))
(defconstant +.5+ (round (+ (* 0.5 (ash 1 shift)) 0.5)))
(defconstant +uvoffset+ (ash 128 shift))
(defconstant +one-half+ (1- (ash 1 (1- shift))))
(defconstant +r-y-off+ 0)
(defconstant +g-y-off+ 256)
(defconstant +b-y-off+ (* 2 256))
(defconstant +r-u-off+ (* 3 256))
(defconstant +g-u-off+ (* 4 256))
(defconstant +b-u-off+ (* 5 256))
(defconstant +r-v-off+ +b-u-off+)
(defconstant +g-v-off+ (* 6 256))
(defconstant +b-v-off+ (* 7 256))

(declaim (type fixnum-array +ctab+ +cr-r-tab+ +cb-g-tab+ +cr-g-tab+ +cb-b-tab+))

;;;Direct color conversion table
(define-constant +ctab+
    (let ((table (make-array 2048 :element-type 'fixnum :initial-element 0)))
      (loop for i fixnum from 0 to 255 do
           (setf (aref table (plus i +r-y-off+))
                 (mul +.299+ i))
           (setf (aref table (plus i +g-y-off+))
                 (mul +.587+ i))
           (setf (aref table (plus i +b-y-off+))
                 (mul +.114+ i))
           (setf (aref table (plus i +r-u-off+))
                 (mul +-.1687+ i))
           (setf (aref table (plus i +g-u-off+))
                 (mul +-.3313+ i))
           (setf (aref table (plus i +b-u-off+))
                 (+ (mul +.5+ i) +uvoffset+ +one-half+))
           (setf (aref table (plus i +r-v-off+))
                 (+ (mul +.5+ i) +uvoffset+ +one-half+))
           (setf (aref table (plus i +g-v-off+))
                 (mul +-.4187+ i))
           (setf (aref table (plus i +b-v-off+))
                 (mul +-.0813+ i)))
      table))

;;; Constantsants for the inverse colorspace conversion
(defconstant +1.40200+ (round (+ (* 1.40200 (ash 1 shift)) 0.5)))
(defconstant +1.77200+ (round (+ (* 1.77200 (ash 1 shift)) 0.5)))
(defconstant +-0.71414+ (round (+ (* -0.71414 (ash 1 shift)) 0.5)))
(defconstant +-0.34414+ (round (+ (* -0.34414 (ash 1 shift)) 0.5)))

;;; Inverse color conversion tables
(define-constant +cr-r-tab+ (make-array 256
                                        :element-type 'fixnum
                                        :initial-contents
                                        (loop for i from 0 to 255
                                              for x from -127
                                              collect (ash (plus (mul +1.40200+ x) +one-half+) (- shift)))))
(define-constant +cb-g-tab+ (make-array 256
                                        :element-type 'fixnum
                                        :initial-contents
                                        (loop for i from 0 to 255
                                              for x from -127
                                              collect (plus (mul +-0.34414+ x) +one-half+))))
(define-constant +cr-g-tab+ (make-array 256
                                        :element-type 'fixnum
                                        :initial-contents
                                        (loop for i from 0 to 255
                                              for x from -127
                                              collect (mul +-0.71414+ x))))
(define-constant +cb-b-tab+ (make-array 256
                                        :element-type 'fixnum
                                        :initial-contents
                                        (loop for i from 0 to 255
                                              for x from -127
                                              collect (ash (plus (mul +1.77200+ x) +one-half+) (- shift)))))

;;; Constants for LLM DCT
(defconstant dct-shift  ; defining DCT scaling
  (if (<= (integer-length most-positive-fixnum) 31)
      (minus 13 (round (minus 31 (integer-length most-positive-fixnum)) 2))
    13))

(defconstant +shift-1+ (1- dct-shift))
(defconstant +shift+1+ (1+ dct-shift))
(defconstant +shift+4+ (+ dct-shift 4))
(defconstant +FIX-0-298631336+ (round (+ (* 0.298631336 (ash 1 dct-shift)) 0.5)))
(defconstant +FIX-0-390180644+ (round (+ (* 0.390180644 (ash 1 dct-shift)) 0.5)))
(defconstant +FIX-0-541196100+ (round (+ (* 0.541196100 (ash 1 dct-shift)) 0.5)))
(defconstant +FIX-0-765366865+ (round (+ (* 0.765366865 (ash 1 dct-shift)) 0.5)))
(defconstant +FIX-0-899976223+ (round (+ (* 0.899976223 (ash 1 dct-shift)) 0.5)))
(defconstant +FIX-1-175875602+ (round (+ (* 1.175875602 (ash 1 dct-shift)) 0.5)))
(defconstant +FIX-1-501321110+ (round (+ (* 1.501321110 (ash 1 dct-shift)) 0.5)))
(defconstant +FIX-1-847759065+ (round (+ (* 1.847759065 (ash 1 dct-shift)) 0.5)))
(defconstant +FIX-1-961570560+ (round (+ (* 1.961570560 (ash 1 dct-shift)) 0.5)))
(defconstant +FIX-2-053119869+ (round (+ (* 2.053119869 (ash 1 dct-shift)) 0.5)))
(defconstant +FIX-2-562915447+ (round (+ (* 2.562915447 (ash 1 dct-shift)) 0.5)))
(defconstant +FIX-3-072711026+ (round (+ (* 3.072711026 (ash 1 dct-shift)) 0.5)))

(declaim (type uint8-array *idct-limit-array*))
;;; Post-IDCT limiting array
(defvar *idct-limit-array* (make-array 512 :initial-element 0 :element-type 'uint8))
(loop for n from 0
      for i from 128 to 383 do
      (setf (aref *idct-limit-array* i) n))
(loop for i from 384 to 511 do
      (setf (aref *idct-limit-array* i) 255))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Error conditions

(define-condition jpeg-error (error)
  ())

(define-condition jpeg-encoder-error (jpeg-error)
  ())

(define-condition internal-jpeg-encoder-error (jpeg-encoder-error)
  ()
  (:report (lambda (condition stream)
	     (declare (ignorable condition))
	     (format stream "Internal error"))))

(define-condition illegal-number-of-components (jpeg-encoder-error)
  ()
  (:report (lambda (condition stream)
	     (declare (ignorable condition))
	     (format stream "Illegal number of components specified"))))

(define-condition invalid-sampling-list (jpeg-encoder-error)
  ((components :reader components :initarg :ncomp))
  (:report (lambda (condition stream)
	     (format stream "Wrong sampling list for ~D component(s)" (components condition)))))

(define-condition invalid-quantization-tables (jpeg-encoder-error)
  ()
  (:report (lambda (condition stream)
	     (declare (ignorable condition))
	     (format stream "Too many quantization tables specified"))))

(define-condition invalid-q-factor (jpeg-encoder-error)
  ()
  (:report (lambda (condition stream)
	     (declare (ignorable condition))
	     (format stream "Invalid Q factor!"))))

(define-condition invalid-sampling (jpeg-encoder-error)
  ()
  (:report (lambda (condition stream)
	     (declare (ignorable condition))
	     (format stream "Invalid sampling specification!"))))

(define-condition jpeg-decoder-error (jpeg-error)
  ())

(define-condition unsupported-jpeg-frame-marker (jpeg-decoder-error)
  ()
  (:report (lambda (condition stream)
	     (declare (ignorable condition))
	     (format stream "Unsupported marker in the frame header"))))

(define-condition unsupported-jpeg-format (jpeg-decoder-error) 
  ((code :reader marker-code :initarg :code))
  (:report (lambda (condition stream)
	     (format stream "Unsupported JPEG format: ~X" (marker-code condition)))))

(define-condition unrecognized-file-format (jpeg-decoder-error)
  ()
  (:report (lambda (condition stream)
	     (declare (ignorable condition))
	     (format stream "Unrecognized JPEG format"))))

(define-condition invalid-buffer-supplied (jpeg-decoder-error)
  ((buffer :reader buffer :initarg :buffer))
  (:report (lambda (condition stream)
	     (declare (ignorable condition))
	     (format stream "Invalid buffer supplied: ~A" (buffer condition)))))

(define-condition unsupported-arithmetic-encoding (jpeg-decoder-error)
  ()
  (:report (lambda (condition stream)
	     (declare (ignorable condition))
	     (format stream "Arithmetic encoding not supported"))))

(define-condition unsupported-dnl-marker (jpeg-decoder-error)
  ()
  (:report (lambda (condition stream)
	     (declare (ignorable condition))
	     (format stream "DNL marker is not supported"))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Encoder part

;;; Subsamples inbuf into outbuf
(defun subsample (inbuf outbuf H V xlim ylim iH iV)
  (declare #.*optimize*
           (type fixnum H V xlim ylim iV iH)
           (type sint16-2d-array inbuf)
	   (type (simple-array sint16-2d-array (*)) outbuf))
  (loop for by fixnum from 0 below V do
        (loop for bx fixnum from 0 below H
              for block = (aref outbuf (plus bx (mul by H))) do
              (loop for y fixnum from (the fixnum (ash by 3)) by iV
                    for yp fixnum from 0 to 7 do
                    (loop for x fixnum from (the fixnum (ash bx 3)) by iH
                          for xp fixnum from 0 to 7 do
                          (setf (s16ref block xp yp)
                                (the sint16 (cond ((and (<= x xlim) (<= y ylim))
                                                   (s16ref inbuf x y))
                                                  ((and (> x xlim) (> y ylim))
                                                   (s16ref inbuf xlim ylim))
                                                  ((> x xlim)
                                                   (s16ref inbuf xlim y))
                                                  ((> y ylim)
                                                   (s16ref inbuf x ylim))
                                                  (t
                                                   (error 'internal-jpeg-encoder-error))
                                                   ))))))))

;;; Returns sum of Vi*Hi
(defun count-relation (smp)
  (loop for entry in smp
        summing (mul (first entry) (second entry))))

;;; Cutting specified part of image (used for non-RGB images)
(defun crop-image (inbuf outbuf dx dy h w height width ncomp)
  (let ((xend (plus dx (1- width)))
        (yend (plus dy (1- height))))
    (declare #.*optimize*
             (type fixnum dx dy h w height width ncomp xend yend)
	     (type simple-array inbuf)
	     (type (simple-array sint16-2d-array (*)) outbuf))
    (setf xend (min xend (1- w)))
    (setf yend (min yend (1- h)))
    (loop for yd fixnum from dy to yend
          for ypos fixnum = (* w yd ncomp) do
          (loop for xd fixnum from dx to xend
                for pos fixnum = (plus (mul xd ncomp) ypos)
                for cx fixnum = (minus xd dx)
                for cy fixnum = (minus yd dy) do
                (loop for i fixnum from 0 below ncomp do
                      (setf (s16ref (aref outbuf i) cx cy)
                            (minus (aref inbuf (plus pos i)) 128)))))
    (values xend yend)))

;;; Direct color mapping
(defun colorspace-convert (RGB YUV dx dy h w height width)
  (let ((xend (plus dx (1- width)))
        (yend (plus dy (1- height)))
        (Y (aref YUV 0))
        (U (aref YUV 1))
        (V (aref YUV 2)))
    (declare #.*optimize*
             (type fixnum dx dy h w height width xend yend)
	     (type sint16-2d-array Y U V)
	     (type fixnum-array +ctab+)
             (type uint8-array RGB))
    (setf xend (min xend (1- w)))
    (setf yend (min yend (1- h)))
    (loop for yd fixnum from dy to yend
          for ypos fixnum = (mul3 w yd 3) do
          (loop for xd fixnum from dx to xend
                for pos fixnum = (plus (mul xd 3) ypos)
                for r fixnum = (aref rgb (plus pos 2))
                for g fixnum = (aref rgb (1+ pos))
                for b fixnum = (aref rgb pos)
                for cx fixnum = (minus xd dx)
                for cy fixnum = (minus yd dy) do
	       (setf (s16ref Y cx cy) (minus (ash (the fixnum (+ (aref +ctab+ (plus r +r-y-off+))
								 (aref +ctab+ (plus g +g-y-off+))
								 (aref +ctab+ (plus b +b-y-off+))))
						  (- shift))
                                             128))
                (setf (s16ref U cx cy) (minus (ash (the fixnum (+ (aref +ctab+ (plus r +r-u-off+))
								  (aref +ctab+ (plus g +g-u-off+))
								  (aref +ctab+ (plus b +b-u-off+))))
						   (- shift))
                                             128))
	       (setf (s16ref V cx cy) (minus (ash (the fixnum (+ (aref +ctab+ (plus r +r-v-off+))
								 (aref +ctab+ (plus g +g-v-off+))
								 (aref +ctab+ (plus b +b-v-off+))))
						  (- shift))
                                             128))))
    (values xend yend)))

;;; Converts given image sampling into frequencies of pixels of components
(defun convert-sampling (s Hmax Vmax)
  (declare (type fixnum Hmax Vmax))
  (make-array (length s)
              :initial-contents (loop for entry in s
                                      collecting (list (the fixnum (/ Hmax (first entry)))
                                                       (the fixnum (/ Vmax (second entry)))))))

;;; Quantization (also removes factor of 8 after DCT)

(defmacro quantize-block ()
  (if *quantize-optimization*
      '(loop for block-row across block
             for q-row across q-table do
             (loop for x fixnum from 0 to 7
                   for val fixnum = (ash (aref block-row x) -3)
                   for qc fixnum = (aref q-row x) do
                   (setf (aref block-row x) (the fixnum (round val qc)))))
    '(loop for block-row across block
           for q-row across q-table do
           (loop for x fixnum from 0 to 7
                 for val fixnum = (ash (aref block-row x) -3)
                 for absval fixnum = (abs val)
                 for qc fixnum = (aref q-row x) do
                 (cond ((< absval (ash qc -1))
                        ;; you won't believe, but under LWW 4.1 such ugly hack gives
                        ;; very sufficient speedup
                        (setf (aref block-row x) 0))
                       ((<= absval qc)
                        (if (minusp val)
                            (setf (aref block-row x) -1)
                         (setf (aref block-row x) 1)))
                       ((<= (ash absval -1) qc)
                        (if (zerop (logand absval 1))
                            (if (minusp val)
                                (setf (aref block-row x) -1)
                              (setf (aref block-row x) 1))
                          (if (minusp val)
                              (setf (aref block-row x) -2)
                            (setf (aref block-row x) 2))))
                       (t
                        (setf (aref block-row x) (the fixnum (round val qc)))))))))

(defun quantize (block q-table)
  (declare #.*optimize*
	   (type sint16-2d-array block)
	   (type uint8-2d-array q-table))
  (quantize-block))

;;; LLM DCT aux definitions
(defun descale (x n)
  (declare #.*optimize* (type fixnum x n))
  (the fixnum (ash (plus x (ash 1 (1- n))) (- n))))

;;; Implementation of Loeffer, Ligtenberg and Moschytz forward DCT
(defun llm-dct (data)
  (declare #.*optimize* (type sint16-2d-array data))
  (loop with tmp0 fixnum and tmp1 fixnum and tmp2 fixnum
        and tmp3 fixnum and tmp4 fixnum and tmp5 fixnum
        and tmp6 fixnum and tmp7 fixnum and tmp10 fixnum
        and tmp11 fixnum and tmp12 fixnum and tmp13 fixnum
        and z1 fixnum and z2 fixnum and z3 fixnum
        and z4 fixnum and z5 fixnum do
        (loop for dptr across data do   ; iterating over rows
              (setf tmp0 (plus (aref dptr 0) (aref dptr 7)))
              (setf tmp7 (minus (aref dptr 0) (aref dptr 7)))
              (setf tmp1 (plus (aref dptr 1) (aref dptr 6)))
              (setf tmp6 (minus (aref dptr 1) (aref dptr 6)))
              (setf tmp2 (plus (aref dptr 2) (aref dptr 5)))
              (setf tmp5 (minus (aref dptr 2) (aref dptr 5)))
              (setf tmp3 (plus (aref dptr 3) (aref dptr 4)))
              (setf tmp4 (minus (aref dptr 3) (aref dptr 4)))
              (setf tmp10 (plus tmp0 tmp3))
              (setf tmp13 (minus tmp0 tmp3))
              (setf tmp11 (plus tmp1 tmp2))
              (setf tmp12 (minus tmp1 tmp2))
              (setf (aref dptr 0) (ash (plus tmp10 tmp11) 1))
              (setf (aref dptr 4) (ash (minus tmp10 tmp11) 1))
              (setf z1 (mul (plus tmp12 tmp13) +FIX-0-541196100+))
              (setf (aref dptr 2) (descale (plus z1 (mul tmp13 +FIX-0-765366865+)) +shift-1+))
              (setf (aref dptr 6) (descale (plus z1 (mul tmp12 (- +FIX-1-847759065+))) +shift-1+))
              (setf z1 (plus tmp4 tmp7))
              (setf z2 (plus tmp5 tmp6))
              (setf z3 (plus tmp4 tmp6))
              (setf z4 (plus tmp5 tmp7))
              (setf z5 (mul (plus z3 z4) +FIX-1-175875602+))
              (setf tmp4 (mul tmp4 +fix-0-298631336+))
              (setf tmp5 (mul tmp5 +fix-2-053119869+))
              (setf tmp6 (mul tmp6 +fix-3-072711026+))
              (setf tmp7 (mul tmp7 +fix-1-501321110+))
              (setf z1 (mul z1 (- +fix-0-899976223+)))
              (setf z2 (mul z2 (- +fix-2-562915447+)))
              (setf z3 (mul z3 (- +fix-1-961570560+)))
              (setf z4 (mul z4 (- +fix-0-390180644+)))
              (incf z3 z5)
              (incf z4 z5)
              (setf (aref dptr 7) (descale (plus3 tmp4 z1 z3) +shift-1+))
              (setf (aref dptr 5) (descale (plus3 tmp5 z2 z4) +shift-1+))
              (setf (aref dptr 3) (descale (plus3 tmp6 z2 z3) +shift-1+))
              (setf (aref dptr 1) (descale (plus3 tmp7 z1 z4) +shift-1+)))
        (loop for cnt fixnum from 7 downto 0 do ; second pass: on columns
              (setf tmp0 (plus (s16ref data cnt 0) (s16ref data cnt 7)))
              (setf tmp7 (minus (s16ref data cnt 0) (s16ref data cnt 7)))
              (setf tmp1 (plus (s16ref data cnt 1) (s16ref data cnt 6)))
              (setf tmp6 (minus (s16ref data cnt 1) (s16ref data cnt 6)))
              (setf tmp2 (plus (s16ref data cnt 2) (s16ref data cnt 5)))
              (setf tmp5 (minus (s16ref data cnt 2) (s16ref data cnt 5)))
              (setf tmp3 (plus (s16ref data cnt 3) (s16ref data cnt 4)))
              (setf tmp4 (minus (s16ref data cnt 3) (s16ref data cnt 4)))
              (setf tmp10 (plus tmp0 tmp3))
              (setf tmp13 (minus tmp0 tmp3))
              (setf tmp11 (plus tmp1 tmp2))
              (setf tmp12 (minus tmp1 tmp2))
              (setf (s16ref data cnt 0) (descale (plus tmp10 tmp11) 1))
              (setf (s16ref data cnt 4) (descale (minus tmp10 tmp11) 1))
              (setf z1 (mul (plus tmp12 tmp13) +fix-0-541196100+))
              (setf (s16ref data cnt 2) (descale (plus z1 (mul tmp13 +fix-0-765366865+)) +shift+1+))
              (setf (s16ref data cnt 6) (descale (plus z1 (mul tmp12 (- +fix-1-847759065+))) +shift+1+))
              (setf z1 (plus tmp4 tmp7))
              (setf z2 (plus tmp5 tmp6))
              (setf z3 (plus tmp4 tmp6))
              (setf z4 (plus tmp5 tmp7))
              (setf z5 (mul (plus z3 z4) +fix-1-175875602+))
              (setf tmp4 (mul tmp4 +fix-0-298631336+))
              (setf tmp5 (mul tmp5 +fix-2-053119869+))
              (setf tmp6 (mul tmp6 +fix-3-072711026+))
              (setf tmp7 (mul tmp7 +fix-1-501321110+))
              (setf z1 (mul z1 (- +fix-0-899976223+)))
              (setf z2 (mul z2 (- +fix-2-562915447+)))
              (setf z3 (mul z3 (- +fix-1-961570560+)))
              (setf z4 (mul z4 (- +fix-0-390180644+)))
              (incf z3 z5)
              (incf z4 z5)
              (setf (s16ref data cnt 7) (descale (plus3 tmp4 z1 z3) +shift+1+))
              (setf (s16ref data cnt 5) (descale (plus3 tmp5 z2 z4) +shift+1+))
              (setf (s16ref data cnt 3) (descale (plus3 tmp6 z2 z3) +shift+1+))
              (setf (s16ref data cnt 1) (descale (plus3 tmp7 z1 z4) +shift+1+)))
        (return)))

;;; Forward DCT and quantization
(defun crunch (buf pos table)
  (declare #.*optimize*
           (type fixnum pos)
           (type (simple-array sint16-2d-array (*)) buf))
  (llm-dct (aref buf pos))
  (quantize (aref buf pos) table))

;;; Q-tables scaling
(defun q-scale (table q-factor)
  (declare #.*optimize*
	   (type uint8-2d-array table)
	   (type uint8 q-factor))
  (when (/= q-factor 64)
    (let ((factor (the uint8 (/ q-factor 64))))
      (loop for q-row of-type uint8-array across table do
            (loop for x fixnum from 0 to 7 do
                  (setf (aref q-row x)
                        (the fixnum (round (* (aref q-row x) factor)))))))))

;;; Function that maps value into SSSS
(defun csize (n)
    (declare #.*optimize* (type fixnum n))
    (aref +csize+ (plus n 1023)))

;;; zigzag ordering
(defun zigzag (buffer zz-result)
  (declare #.*optimize*
	   (type sint16-2d-array buffer))
  (loop for row of-type sint16-array across buffer
     for z-row of-type uint8-array across +zigzag-index+ do
       (loop for x fixnum from 0 to 7 do
	    (setf (aref zz-result (aref z-row x))
		  (the sint16 (aref row x)))))
  zz-result)

(defun zigzag8 (buffer zz-result)
  (declare #.*optimize*
           (type uint8-2d-array buffer)
           (type uint8-array zz-result))
  (loop for row of-type uint8-array across buffer
     for z-row of-type uint8-array across +zigzag-index+ do
       (loop for x fixnum from 0 to 7 do
            (setf (aref zz-result (aref z-row x))
                  (the fixnum (aref row x)))))
  zz-result)

;;; Writes frame header
(defun write-frame-header (maxX maxY cn q-tables sampling tqv out-stream)
  (declare #.*optimize* (type fixnum maxX maxY cn)
	   (type (simple-array uint8-2d-array (*)) q-tables)
	   ;;(type uint8-array tqv)
	   )
  (write-huffman-tables out-stream)
  (write-quantization-tables q-tables out-stream)
  ;; writing frame header
  (write-marker +M_SOF0+ out-stream)
  (write-byte 0 out-stream) ; length
  (write-byte (plus 8 (mul 3 cn)) out-stream)
  (write-byte 8 out-stream) ; sample precision
  (write-byte (ash maxY -8) out-stream) ; max height
  (write-byte (logand maxY #xff) out-stream)
  (write-byte (ash maxX -8) out-stream) ; max width
  (write-byte (logand maxX #xff) out-stream)
  (write-byte cn out-stream) ; number of components
  (loop for entry in sampling
        for i fixnum from 0 by 1 do
        (write-byte i out-stream)
        (write-byte         ; H and V
         (deposit-field (second entry) (byte 4 0)(ash (first entry) 4))
         out-stream)
        (write-byte (aref tqv i) out-stream))) ; Tq

;;; Writes byte with stuffing (adds zero after FF code)
(defun write-stuffed (b s)
  (declare #.*optimize* (type uint8 b)
           (type stream s))
   (write-byte b s)
   (if (= b #xFF)
      (write-byte 0 s)))

;;; A function for bit streaming
;;; NB: probably it's a good idea to encapsulate this behavior into a class, but I'm
;;; afraid that method dispatch would be too slow

(defstruct (write-bits-state (:conc-name write-bits-))
  (prev-byte 0 :type uint8)
  (prev-length 0 :type fixnum))

(defun write-bits (bi ni s write-bits-state)
  (declare #.*optimize*
           (type fixnum bi ni)
           (type stream s))
  (loop with lim fixnum = (if (> ni 8) 1 0)
        for i fixnum from lim downto 0 do
        (let ((b (ldb (byte 8 (ash i 3)) bi))
              (n (cond ((and (= i 1) (= ni 16)) 8)
                       ((and (= i 0) (/= lim 0)) 8)
                       ((= ni 8) 8)
                       (t (logand ni 7)))))
          (declare (type fixnum b n)
                   (dynamic-extent b n))
          (cond ((zerop n))
                ((>= (plus n (write-bits-prev-length write-bits-state)) 8)
                 (let* ((result (ash (write-bits-prev-byte write-bits-state)
                                     (minus 8 (write-bits-prev-length write-bits-state))))
                        (total-length (plus n (write-bits-prev-length write-bits-state)))
                        (overflow (minus total-length 8)))
                   (declare (type fixnum overflow total-length result)
                            (dynamic-extent overflow total-length result))
                   (setf (write-bits-prev-byte write-bits-state) (ldb (byte overflow 0) b))
                   (write-stuffed (deposit-field
                                   (ldb (byte (minus n overflow) overflow) b)
                                   (byte (minus 8 (write-bits-prev-length write-bits-state)) 0)
                                   result)
                                  s)
                   (setf (write-bits-prev-length write-bits-state) overflow)))
                (t  (setf (write-bits-prev-byte write-bits-state)
                          (deposit-field b
                                         (byte n 0)
                                         (ash (write-bits-prev-byte write-bits-state) n)))
                    (incf (write-bits-prev-length write-bits-state) n))))))

;;; Encodes block using specified huffman tables, returns new pred (DC prediction value)
;;; and last code written to stream for padding
(defun encode-block (block tables pred s write-bits-state)
  (declare #.*optimize* (type fixnum pred)
           (type sint16-array block))
  (let* ((ehufsi-dc (first (first tables)))
         (ehufco-dc (second (first tables)))
         (ehufsi-ac (first (second tables)))
         (ehufco-ac (second (second tables)))
         (newpred (aref block 0))
         (diff (minus newpred pred))
         (dcpos (csize diff)))
    (declare (type fixnum pred newpred diff dcpos)
	     (type fixnum-array ehufco-ac ehufco-dc ehufsi-dc ehufsi-ac)
             (dynamic-extent diff dcpos))
    ;; writing dc code first
    (write-bits (aref ehufco-dc dcpos) (aref ehufsi-dc dcpos) s write-bits-state)
    (cond ((minusp diff) (write-bits (1- diff) (csize diff) s write-bits-state))
          (t (write-bits diff (csize diff) s write-bits-state)))
    ;; writing ac sequence
    (loop with r fixnum = 0 for k fixnum from 1 to 63 do
          (if (zerop (aref block k))
              (if (= k 63)
                  (progn
                    (write-bits (aref ehufco-ac 0) (aref ehufsi-ac 0) s write-bits-state) ; writing EOB
                    (return))
                (incf r))
            (progn
              (loop while (> r 15) do
                    (write-bits (aref ehufco-ac #xf0) (aref ehufsi-ac #xf0) s write-bits-state)
                    (decf r 16))
              (let* ((ssss (csize (aref block k)))
                     (rs (plus ssss (ash r 4))))
                (write-bits (aref ehufco-ac rs) (aref ehufsi-ac rs) s write-bits-state)
                (when (minusp (aref block k))
                  (decf (aref block k) 1))
                (write-bits (aref block k) ssss s write-bits-state))
              (setf r 0))))
    newpred))

;;; Emits q-tables
(defun write-quantization-tables (tables s)
  (let ((len (plus 2 (mul 65 (length tables))))
        (zz-result (make-array 64 :element-type 'uint8)))
    (write-marker +M_DQT+ s)
    (write-byte (ash len -8) s) ; MSB
    (write-byte (logand len #xff) s) ; LSB
    (loop for table across tables
          for i fixnum from 0 do
          (write-byte i s)
          (write-sequence (zigzag8 table zz-result) s))))

;;; Emits huffman tables in the following order:
;;; luminance DC
;;; luminance AC
;;; chrominance DC
;;; chrominance AC
(defun write-huffman-tables (s)
  (let ((len (+ 2 (* 17 4)
                (length +luminance-dc-values+)
                (length +luminance-ac-values+)
                (length +chrominance-dc-values+)
                (length +chrominance-ac-values+))))
    (write-marker +M_DHT+ s)
    (write-byte (ash len -8) s) ; MSB
    (write-byte (logand len #xff) s) ; LSB
    (write-hufftable +luminance-dc-bits+ +luminance-dc-values+ 0 s)
    (write-hufftable +luminance-ac-bits+ +luminance-ac-values+ 16 s)
    (write-hufftable +chrominance-dc-bits+ +chrominance-dc-values+ 1 s)
    (write-hufftable +chrominance-ac-bits+ +chrominance-ac-values+ 17 s)))

;;; Writes single huffman table
(defun write-hufftable (bits vals tcti s)
  (declare (type fixnum tcti))
    (write-byte tcti s) ; Tc/Th
    (write-sequence bits s)
    (write-sequence vals s))

;;; Drops specified marker into the stream
(defun write-marker (code to)
   (write-byte #xFF to)
   (write-byte code to))

;;; Writing some markers into the stream
(defun prepare-JFIF-stream (out-stream)
   (write-marker +M_SOI+ out-stream)
   (write-marker +M_APP0+ out-stream)
   (write-byte 0 out-stream) ; length
   (write-byte 16 out-stream)
   (write-byte #x4a out-stream)
   (write-byte #x46 out-stream)
   (write-byte #x49 out-stream)
   (write-byte #x46 out-stream)
   (write-byte 0 out-stream)
   (write-byte 1 out-stream) ; version
   (write-byte 2 out-stream)
   (write-byte 0 out-stream) ; units
   (write-byte 0 out-stream) ; density
   (write-byte 1 out-stream)
   (write-byte 0 out-stream)
   (write-byte 1 out-stream)
   (write-byte 0 out-stream) ; thumbnail
   (write-byte 0 out-stream))

;;; Builds common decoding and encoding tables
(defun build-universal-tables (bits)
  (let ((huffsize (make-array 256 :element-type 'fixnum))
        (huffcode (make-array 256 :element-type 'fixnum))
        (lastk 0))
    (declare #.*optimize* (type fixnum lastk)
             (type fixnum-array huffcode huffsize)
	     (type uint8-array bits))
    ;; generating huffsize
      (loop for i fixnum from 1 to 16
            with k fixnum = 0 and j fixnum = 1 do
            (loop until (> j (aref bits (1- i))) do
                  (setf (aref huffsize k) i)
                  (incf k)
                  (incf j)
                  finally (setf j 1))
            finally (progn (setf lastk k) (setf (aref huffsize lastk) 0)))

      ;; generating huffcode
      (loop with k fixnum = 0 and code fixnum = 0 and si fixnum = (aref huffsize 0) do
            (loop do
                  (setf (aref huffcode k) code)
                  (incf code)
                  (incf k)
                  when (/= (aref huffsize k) si) do (return))
            when (zerop (aref huffsize k)) do
            (return)
            else do
            (loop do
                  (setf code (ash code 1))
                  (incf si)
                  when (= (aref huffsize k) si) do (return)))
      (values huffcode huffsize lastk)))

;;;Builds ordered code tables for encoder
(defun build-tables (bits huffval)
  (let ((ehufco (make-array 256 :element-type 'fixnum))
        (ehufsi (make-array 256 :element-type 'fixnum)))
    (multiple-value-bind (huffcode huffsize lastk)
        (build-universal-tables bits)
      (declare (type fixnum-array huffsize huffcode)
               (type fixnum lastk))
      (loop with i fixnum for k from 0 below lastk do
            (setf i (aref huffval k))
            (setf (aref ehufco i) (aref huffcode k))
            (setf (aref ehufsi i) (aref huffsize k)))
      (list ehufsi ehufco))))

;;; Main encoder function (user interface)
(defun encode-image-stream (out-stream image ncomp h w
                            &key (q-tabs +q-tables+) (sampling '((2 2)(1 1)(1 1))) (q-factor 64))
  (declare #.*optimize*
           (type fixnum ncomp h w q-factor)
           (type uint8-array image))
  (when (= ncomp 1)
    (setq sampling '((1 1))))
  (let* ((wd (loop for entry in sampling maximize (the fixnum (first entry))))
         (ht (loop for entry in sampling maximize (the fixnum (second entry))))
	 (zz-result (make-array 64 :element-type 'sint16))
         (write-bits-state (make-write-bits-state))
         (isampling (convert-sampling sampling wd ht))
         (height (the fixnum (ash ht 3)))
         (width (the fixnum (ash wd 3)))
         (YUV (make-array ncomp
			  :element-type 'sint16-2d-array
                          :initial-contents
                          (loop for i fixnum from 0 below ncomp collecting
                               (make-array height
					   :element-type 'sint16-array
                                           :initial-contents
                                           (loop for j fixnum from 0 below height
                                              collecting (make-array width :element-type 'sint16))))))
         (sampled-buf (make-array (mul ht wd)
				  :element-type 'sint16-2d-array
                                  :initial-contents
                                  (loop for b fixnum from 0 below (mul ht wd)
                                     collecting (make-array 8
							    :element-type 'sint16-array
                                                            :initial-contents
                                                            (loop for i fixnum from 0 to 7
                                                               collecting (make-array 8 :element-type 'sint16))))))
         (preds (make-array ncomp :initial-element 0))
         (tqv (case ncomp
                (3 #(0 1 1)) ; q-tables destinations for various component numbers
                (1 #(0))
                (2 #(0 1))
                (4 #(0 1 2 3))
                (otherwise (error 'illegal-number-of-components)))))
    (declare (type (simple-array sint16-2d-array (*)) YUV sampled-buf))
    (cond ((/= ncomp (length sampling))
           (error 'invalid-sampling-list :ncomp ncomp))
          ((> (length q-tabs) ncomp)
           (error 'invalid-quantization-tables))
          ((zerop q-factor)
           (error 'invalid-q-factor))
          ((> (count-relation sampling) 10)
           (error 'invalid-sampling)))
    (when (< q-factor 64)
      (let ((q-tabs2 (make-array (length q-tabs)
				 :element-type 'uint8-2d-array
                                 :initial-contents
                                 (loop for k fixnum from 0 below (length q-tabs)
                                    collecting (make-array 8 :element-type 'uint8-array
							   :initial-contents
                                                           (loop for i fixnum from 0 to 7
                                                              collecting (make-array 8 :element-type 'uint8)))))))
	(declare (type (simple-array uint8-2d-array (*)) q-tabs2))
        (loop for entry across q-tabs
           for entry2 across q-tabs2 do
           (loop for x fixnum from 0 to 7 do
                (loop for y fixnum from 0 to 7 do
                     (setf (u8ref entry2 x y) (the fixnum (u8ref entry x y))))))
        (setq q-tabs q-tabs2))
      (loop for entry across q-tabs do  ; scaling all q-tables
           (q-scale entry q-factor)))
    (if (and (/= ncomp 1) (/= ncomp 3))
        (write-marker +M_SOI+ out-stream)
        (prepare-JFIF-stream out-stream))
    (write-frame-header w h ncomp q-tabs sampling tqv out-stream) ; frame header
    ;; writing scan header
    (write-marker +M_SOS+ out-stream)
    (write-byte 0 out-stream)           ; length
    (write-byte (plus 6 (ash ncomp 1)) out-stream)
    (write-byte ncomp out-stream)    ; number of components in the scan
    (loop for Cj from 0 below ncomp do
         (write-byte Cj out-stream)     ; component ID
         (write-byte (if (zerop Cj) 0 17) out-stream)) ; TdTa
    (write-byte 0 out-stream)                          ; Ss
    (write-byte 63 out-stream)                         ; Se
    (write-byte 0 out-stream)                          ; AhAl

    (let ((luminance-tabset (list
                             (build-tables +luminance-dc-bits+ +luminance-dc-values+)
                             (build-tables +luminance-ac-bits+ +luminance-ac-values+)))
          (chrominance-tabset (list (build-tables +chrominance-dc-bits+ +chrominance-dc-values+)
                                    (build-tables +chrominance-ac-bits+ +chrominance-ac-values+))))
      (loop for dy fixnum from 0 below h by height do
           (loop for dx fixnum from 0 below w by width do
                (multiple-value-bind (xlim ylim)
                    (if (= ncomp 3)
                       (colorspace-convert image YUV dx dy h w height width)
                        (crop-image image YUV dx dy h w height width ncomp))
                  (declare (type fixnum xlim ylim)
                           (dynamic-extent xlim ylim))
                  (loop for comp across YUV
                     for freq in sampling
                     for ifreq across isampling
                     for iH fixnum = (first ifreq)
                     for iV fixnum = (second ifreq)
                     for cn fixnum from 0
                     for hufftabs = (if (zerop cn)
                                        luminance-tabset
                                        chrominance-tabset)
                     ;; choosing appropriate q-table for a component
                     for q-tab = (aref q-tabs (aref tqv cn))
                     for H fixnum = (first freq)
                     for V fixnum = (second freq) do
                     (subsample comp sampled-buf H V (minus xlim dx) (minus ylim dy) iH iV)
                     (loop for y fixnum from 0 below V
                        for ypos fixnum = (if (> (plus dy (ash y 3)) ylim)
                                              (mul (rem (ash ylim -3) V) H)
                                              (mul y H)) do
                        (loop for x fixnum from 0 below H
                           for pos fixnum = (if (> (plus dx (ash x 3)) xlim)
                                                (plus (rem (ash xlim -3) H) ypos)
                                                (plus x ypos)) do
                           (crunch sampled-buf pos q-tab)
                           (setf (aref preds cn)
                                 (encode-block (zigzag (aref sampled-buf pos) zz-result)
                                               hufftabs (aref preds cn) out-stream
                                               write-bits-state)))))))))
    (unless (zerop (write-bits-prev-length write-bits-state))
      (write-stuffed (deposit-field #xff ; byte padding & flushing
                                    (byte (minus 8 (write-bits-prev-length write-bits-state)) 0)
                                    (the fixnum (ash (the uint8 (write-bits-prev-byte write-bits-state))
                                                     (the uint8 (minus 8 (write-bits-prev-length write-bits-state))))))
                     out-stream))
    (write-marker +M_EOI+ out-stream)))

(defun encode-image (filename image ncomp h w &rest args)
  (with-open-file (out-stream filename
                              :direction :output
                              :element-type 'uint8
                              :if-exists :supersede)
    (apply #'encode-image-stream out-stream image ncomp h w args)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Decoder part

;;; Contains all information about a single scan
(defstruct scan
  (ncomp 1 :type fixnum) ; number of image components in the scan
  (x 0 :type fixnum) ; current processing
  (y 0 :type fixnum) ; positions
  (cdesc (make-array 4
                     :initial-contents (loop repeat 4 collect (list 0 0)))
         :type (simple-array t (*))) ; descriptors of all components in the scan
  (ss 0 :type fixnum)   ; spectral selection start
  (se 63 :type fixnum)  ; spectral selection end
  (ah 0 :type fixnum)   ; successive approximation high
  (al 0 :type fixnum))  ; successive approximation low

;;; Contains huffman decoding tables
(defstruct huffstruct
  mincode
  maxcode
  (bits (make-array 16 :element-type 'uint8) :type uint8-array)
  huffval
  huffcode
  valptr
  ;; 9-bit lookahead: (code length << 8) | value for codes up to 9 bits, 0 otherwise
  (lookup (make-array 512 :element-type 'uint16 :initial-element 0)
   :type (simple-array uint16 (512)))
  ;; 9-bit lookahead for AC codes whose code and value bits together fit in 9 bits:
  ;; (value << 8) | (run << 4) | total length, 0 otherwise
  (fast-ac (make-array 512 :element-type 'sint16 :initial-element 0)
   :type (simple-array sint16 (512))))

;;; This structure contains all neccessary information about the decoded image
(defstruct descriptor
  (restart-interval 0 :type fixnum)
  (width 0 :type fixnum)
  (height 0 :type fixnum)
  buffer
  (qtables
   (make-array 4 :initial-contents
               (loop for j fixnum from 0 to 3
                     collecting
                        (make-array 8 :initial-contents
                                    (loop for i fixnum from 0 to 7
                                          collecting (make-array 8 :element-type 'uint8))))) :type (simple-array uint8-2d-array (*)))
  (huff-ac (make-array 2 :initial-contents
                       (list (make-huffstruct) (make-huffstruct))) :type (simple-array t (*)))
  (huff-dc (make-array 2 :initial-contents
                       (list (make-huffstruct) (make-huffstruct))) :type (simple-array t (*)))
  (cid (make-array 4) :type (simple-array t (*)))
  (scans (make-array 4 :initial-contents
                     (loop for i fixnum from 0 to 3 collecting (make-scan))) :type (simple-array t (*)))
  (H (make-array 4) :type (simple-array t (*)))
  (V (make-array 4) :type (simple-array t (*)))
  (iH (make-array 4) :type (simple-array t (*)))
  (iV (make-array 4) :type (simple-array t (*)))
  (qdest (make-array 4) :type (simple-array t (*)))
  (coefs (make-array 64 :element-type '(signed-byte 32)) :type sint32-array) ; block being decoded
  (idct-ws (make-array 64 :element-type 'fixnum) :type fixnum-array) ; IDCT workspace
  (ncomp 0 :type fixnum)
  (ws (2d-sint16-array
       '(0  0  0  0  0  0  0  0)
       '(0  0  0  0  0  0  0  0)
       '(0  0  0  0  0  0  0  0)
       '(0  0  0  0  0  0  0  0)
       '(0  0  0  0  0  0  0  0)
       '(0  0  0  0  0  0  0  0)
       '(0  0  0  0  0  0  0  0)
       '(0  0  0  0  0  0  0  0))
      :type sint16-2d-array)	; Temporary workspace for IDCT
  ;; Input: bytes SOURCE-POS below SOURCE-END of SOURCE are next. BYTE-READER
  ;; refills SOURCE and returns the new end, or 0 when there is no more data.
  (byte-reader #'(lambda () ;in case setup fails somehow
		   (error 'jpeg-decoder-error)) :type function)
  (source (make-array 0 :element-type 'uint8) :type uint8-array)
  (source-pos 0 :type fixnum)
  (source-end 0 :type fixnum)
  (stream-buffer nil)       ; chunk buffer for reading file streams
  (source-cache)
  (adobe-app14-transform nil)
  (progressive-p nil)       ; t when decoding SOF2 (progressive) frame
  (coef-buffers nil)        ; vector of per-component sint16 arrays for DCT coefficients
  (blocks-per-row nil)      ; vector of per-component block-row counts
  (blocks-per-col nil)      ; vector of per-component block-column counts
  (planes nil)              ; vector of per-component sample planes, (* 8 blocks-per-row) wide
  (hmax 1 :type fixnum)     ; maximum sampling factors
  (vmax 1 :type fixnum)
  (mcus-x 0 :type fixnum)   ; MCUs per row and column
  (mcus-y 0 :type fixnum))

(defun read-frame-components (image)
  "Reads the component specifications of the frame header and sets up the
frame geometry and the component planes."
  (let ((ncomp (descriptor-ncomp image)))
    (loop for i fixnum from 0 below ncomp
          with hv fixnum do
          (setf (aref (descriptor-cid image) i) (read-jpeg-byte image)) ; Cj
          (setf hv (read-jpeg-byte image))                              ; HV
          (setf (aref (descriptor-H image) i) (ash hv -4))
          (setf (aref (descriptor-V image) i) (logand hv 7))
          (setf (aref (descriptor-qdest image) i) (read-jpeg-byte image)))
    (let* ((hmax (loop for i from 0 below ncomp maximize (aref (descriptor-H image) i)))
           (vmax (loop for i from 0 below ncomp maximize (aref (descriptor-V image) i)))
           (mcus-x (ceiling (descriptor-width image) (* hmax 8)))
           (mcus-y (ceiling (descriptor-height image) (* vmax 8)))
           (bpr (make-array ncomp))
           (bpc (make-array ncomp))
           (planes (make-array ncomp)))
      (setf (descriptor-hmax image) hmax
            (descriptor-vmax image) vmax
            (descriptor-mcus-x image) mcus-x
            (descriptor-mcus-y image) mcus-y)
      (dotimes (c ncomp)
        (setf (aref bpr c) (* mcus-x (aref (descriptor-H image) c))
              (aref bpc c) (* mcus-y (aref (descriptor-V image) c))
              (aref planes c) (make-array (+ 16 (* 64 (aref bpr c) (aref bpc c))) ; room for 16-byte loads
                                            :element-type 'uint8)))
      (setf (descriptor-blocks-per-row image) bpr
            (descriptor-blocks-per-col image) bpc
            (descriptor-planes image) planes))))

(defun allocate-coef-buffers (image)
  "Allocate per-component coefficient buffers for progressive decoding."
  (let ((buffers (make-array (descriptor-ncomp image))))
    (dotimes (c (descriptor-ncomp image))
      (setf (aref buffers c)
            (make-array (* 64 (aref (descriptor-blocks-per-row image) c)
                           (aref (descriptor-blocks-per-col image) c))
                        :element-type 'sint16 :initial-element 0)))
    (setf (descriptor-coef-buffers image) buffers)))

(defun component-blocks (image c)
  "Returns the number of block columns and rows actually covered by component C,
i.e. the extent of a non-interleaved scan of it (A.2.2 of the spec)."
  (values (ceiling (ceiling (* (descriptor-width image) (aref (descriptor-H image) c))
                            (descriptor-hmax image))
                   8)
          (ceiling (ceiling (* (descriptor-height image) (aref (descriptor-V image) c))
                            (descriptor-vmax image))
                   8)))

(defun read-jpeg-byte (image)
  (declare #.*optimize*)
  (let ((pos (descriptor-source-pos image)))
    (declare (type fixnum pos))
    (when (>= pos (descriptor-source-end image))
      (setf pos (refill-source image)))
    (setf (descriptor-source-pos image) (1+ pos))
    (aref (descriptor-source image) pos)))

(defun refill-source (image)
  "Refills the input buffer and returns the position of its first byte"
  (let ((end (funcall (descriptor-byte-reader image))))
    (declare (type fixnum end))
    (when (zerop end)
      (error 'end-of-file :stream nil))
    (setf (descriptor-source-end image) end
          (descriptor-source-pos image) 0)))

(defun set-source (image stream cached-source-p)
  "Sets up the input of IMAGE: the source cache, a file stream read in
chunks, or another stream read byte by byte"
  (cond (cached-source-p
         (when (or (not (typep (descriptor-source-cache image) 'uint8-array))
                   (and (typep stream 'file-stream)
                        (< (length (descriptor-source-cache image)) (file-length stream))))
           (setf (descriptor-source-cache image) (make-array (file-length stream) :element-type 'uint8)))
         (when stream ;; NULL stream means the cache in descriptor is already read
           (read-sequence (descriptor-source-cache image) stream))
         (setf (descriptor-source image) (descriptor-source-cache image)
               (descriptor-source-end image) (length (descriptor-source-cache image))
               (descriptor-byte-reader image) (lambda () 0)))
        ;; Seekable streams are read in chunks; RELEASE-SOURCE moves the
        ;; position back to just after the data used
        ((and (typep stream 'file-stream) (file-position stream))
         (unless (descriptor-stream-buffer image)
           (setf (descriptor-stream-buffer image) (make-array 32768 :element-type 'uint8)))
         (let ((buffer (descriptor-stream-buffer image)))
           (setf (descriptor-source image) buffer
                 (descriptor-source-end image) 0
                 (descriptor-byte-reader image) (lambda () (read-sequence buffer stream)))))
        (t
         (let ((buffer (make-array 1 :element-type 'uint8)))
           (setf (descriptor-source image) buffer
                 (descriptor-source-end image) 0
                 (descriptor-byte-reader image)
                 (lambda () (setf (aref buffer 0) (read-byte stream)) 1)))))
  (setf (descriptor-source-pos image) 0))

(defun release-source (image stream)
  "Leaves a chunk-read STREAM positioned just after the data decoded"
  (when (and stream (eq (descriptor-source image) (descriptor-stream-buffer image)))
    (file-position stream (- (file-position stream)
                             (- (descriptor-source-end image) (descriptor-source-pos image))))))

;;; Reads an JPEG marker from the stream
(defun read-marker (s)
  (loop for b fixnum = (read-jpeg-byte s)
        when (/= b #xff) do (return b)))

;;; Reads 16-bit word from the stream
(defun read-word (s)
  "Reads 16-bit word from the stream"
  (let* ((msb (ash (read-jpeg-byte s) 8))
         (lsb (read-jpeg-byte s))
         (word (logior msb lsb)))
    word))

(eval-when (:compile-toplevel :load-toplevel :execute)
;;; APPn marker reading: just skipping the whole marker
  (defun read-app (s)
    "APPn marker reading: just skipping the whole marker"
    (loop for i fixnum from 0 below (minus (read-word s) 2) do
         (read-jpeg-byte s)))

;;; COM marker reading, same as read-app
  (setf (symbol-function 'read-com) #'read-app))

;;; Sets up restart interval
(defun read-dri (image)
  "Reads restart interval"
  (read-jpeg-byte image) ; skipping length
  (read-jpeg-byte image)
  (setf (descriptor-restart-interval image) (read-word image)))

;;; 'Inverse zigzag transform'
(defun izigzag8 (inbuf zzbuf)
  (declare #.*optimize*
           (type uint8-array inbuf)
	   (type uint8-2d-array zzbuf +zigzag-index+))
  "Performs inverse zigzag block arrangement"
  (loop for zrow of-type uint8-array across +zigzag-index+
        for row of-type uint8-array across zzbuf do
        (loop for pos fixnum across zrow
              for x fixnum from 0 do
              (setf (aref row x) (aref inbuf pos))))
  zzbuf)

;;; Reads in quantization tables
(defun read-dqt (image)
  "Reads in quantization tables"
  (let ((len (minus (read-word image) 2)))
    (loop for i fixnum from (1- len) downto 0 by 65
          for tq fixnum = (logand (read-jpeg-byte image) 7)
          with intable of-type uint8-array = (make-array 64 :element-type 'uint8)
          for table = (aref (descriptor-qtables image) tq) do
          (loop for pos from 0 to 63 do
                (setf (aref intable pos) (read-jpeg-byte image)))
          (izigzag8 intable table))))

;;; Builds up decoder tables
(defun build-decoder-tables (bits huffcode)
  "Builds up decoder-specific tables"
  (let ((maxcode (make-array 17 :element-type 'fixnum))
        (mincode (make-array 17 :element-type 'fixnum))
        (valptr (make-array 17 :element-type 'fixnum)))
    (loop with i fixnum = 0
          and j fixnum = 0 do
          (when (loop
                 (incf i)
                 (when (> i 16)
                   (return t))
                 (cond ((zerop (aref bits (1- i)))
                        (setf (aref maxcode i) -1))
                       (t (return nil))))
            (return (values maxcode mincode valptr)))
          (setf (aref valptr i) j)
          (setf (aref mincode i) (aref huffcode j))
          (incf j (1- (aref bits (1- i))))
          (setf (aref maxcode i) (aref huffcode j))
          (incf j))))

;;; Builds the lookahead table for fast decoding of short codes
(defun build-lookup-table (bits huffcode huffval)
  "Maps every 9-bit prefix starting with a code of at most 9 bits to (length << 8) | value"
  (let ((lookup (make-array 512 :element-type 'uint16 :initial-element 0)))
    (declare (type uint8-array bits huffval)
             (type fixnum-array huffcode))
    (loop with k fixnum = 0
          for l fixnum from 1 to 9 do
          (loop repeat (aref bits (1- l)) do
                (let ((start (ash (aref huffcode k) (- 9 l))))
                  (fill lookup (logior (ash l 8) (aref huffval k))
                        :start start :end (+ start (ash 1 (- 9 l)))))
                (incf k)))
    lookup))

;;; Loads huffman tables
(defun read-dht (image)
  "Loads huffman tables on specified destinations"
  (let ((len (minus (read-word image) 2))
        (count 0))
    (loop for tcth fixnum = (read-jpeg-byte image)
          for tc fixnum = (ash tcth -4)
          for th fixnum = (logand tcth 15)
          for tables = (if (zerop tc)
                           (aref (descriptor-huff-ac image) th)
                         (aref (descriptor-huff-dc image) th))
          for bits = (huffstruct-bits tables)
          for sum fixnum = 0 do
          (loop for i fixnum from 0 to 15
                for entry fixnum = (read-jpeg-byte image) do
                (incf sum entry)
                (setf (aref bits i) entry))
          (setf (huffstruct-huffval tables)
                (make-array sum :element-type 'uint8
			    :initial-contents (loop for i fixnum from 0 below sum
                                                        collecting (read-jpeg-byte image))))
          (incf count (plus sum 17))
	 (multiple-value-bind (maxcode mincode valptr)
              (build-decoder-tables bits (setf (huffstruct-huffcode tables)
                                               (build-universal-tables bits)))
            ;;(declare (type uint8-array mincode valptr))
            (setf (huffstruct-maxcode tables) maxcode)
            (setf (huffstruct-mincode tables) mincode)
            (setf (huffstruct-valptr tables) valptr))
          (setf (huffstruct-lookup tables)
                (build-lookup-table bits (huffstruct-huffcode tables) (huffstruct-huffval tables)))
          (setf (huffstruct-fast-ac tables)
                (build-fast-ac-table (huffstruct-lookup tables)))
          (unless (< count len) (return t)))))

;;; APP14 is assumed to be Adobe proprietary extension marker
;;; We parse it to figure out if some special color transform is necessary
(defun read-app14 (image)
  (let ((length (minus (read-word image) 2)))
    (loop repeat 11 do (read-jpeg-byte image))
    (setf (descriptor-adobe-app14-transform image)
	  (case (read-jpeg-byte image)
	    (0 :unknown)
	    (1 :ycbcr-rgb)
	    (2 :ycck-cmyk)
	    (otherwise :invalid)))
    (loop repeat (- length 12) do (read-jpeg-byte image))))

;;; Reads tables etc., returns the first unrecognized marker it met
(defun interpret-markers (image term)
  "Reads tables etc., returns the first unrecognized marker it met"
  (loop for mk fixnum = (cond ((zerop term) (read-marker image))
                              (t term)) do
       (setf term 0)
       (cond ((= mk +M_APP14+) (read-app14 image)) ;Adobe marker
	     ((= #xe0 (logand #xf0 mk)) ; Unrecognized APPn marker
	      (read-app image))
	     (t (cond ((= mk +M_DAC+) (error 'unsupported-arithmetic-encoding))
		      ((= mk +M_DRI+) (read-dri image))
		      ((= mk +M_DHT+) (read-dht image))
		      ((= mk +M_DQT+) (read-dqt image))
		      ((= mk +M_COM+) (read-com image))		      
		      (t (return mk)))))))

;;; EXTEND procedure, as described in the standard
(defun extend (v tt)
  "EXTEND procedure, as described in spec. Branchless, as the sign is unpredictable."
  (declare (type (unsigned-byte 16) v)
           (type (integer 0 16) tt)
           #.*optimize*)
  ;; A clear top bit (bit TT-1) means a negative value: subtract 2^TT - 1
  (let ((top (ash v (- (logand (1- tt) 15)))))
    (- v (logand (1- top) (1- (ash 1 tt))))))

;;; Builds the combined code + value lookahead table for AC coefficients
(defun build-fast-ac-table (lookup)
  "Maps 9-bit prefixes holding both an AC code and its value bits to the decoded coefficient"
  (let ((fast (make-array 512 :element-type 'sint16 :initial-element 0)))
    (dotimes (i 512)
      (let* ((entry (aref lookup i))
             (l (ash entry -8))
             (r (ash entry -4))
             (s (logand entry 15)))
        (setf r (logand r 15))
        (when (and (/= entry 0) (/= s 0) (<= (+ l s) 9))
          (let ((k (extend (ldb (byte s (- 9 l s)) i) s)))
            (when (<= -128 k 127)
              (setf (aref fast i) (+ (* k 256) (* r 16) l s)))))))
    fast))

;;; Bit reader for entropy-coded segments. The low CNT bits of BUF are the
;;; ones not yet consumed, most significant first. A marker met while filling
;;; is kept in MARKER, and zero bits (counted in PAD) are supplied from then
;;; on: consuming those throws the marker, as reading it bit by bit would.
(defstruct (bitreader (:constructor make-bitreader ()))
  (buf 0 :type (unsigned-byte 64))
  (cnt 0 :type (integer 0 64))
  (pad 0 :type fixnum)
  (marker nil))

(defun fill-bits (br s)
  "Reads bytes into the bit buffer until it holds more than 56 bits"
  (declare #.*optimize*
           (type bitreader br))
  (loop while (<= (bitreader-cnt br) 56) do
        (let ((b (if (bitreader-marker br) 0 (read-jpeg-byte s))))
          (declare (type uint8 b))
          (when (= b #xff)
            (let ((b2 (loop for b2 of-type uint8 = (read-jpeg-byte s) ; skipping fill bytes
                            while (= b2 #xff)
                            finally (return b2))))
              (declare (type uint8 b2))
              (unless (zerop b2)
                (when (= b2 +M_DNL+)
                  (error 'unsupported-dnl-marker))
                (setf (bitreader-marker br)
                      (if (<= +M_RST0+ b2 +M_RST7+) 'restart b2)
                      b 0))))
          (when (bitreader-marker br)
            (incf (bitreader-pad br) 8))
          (setf (bitreader-buf br)
                (logand (logior (ash (bitreader-buf br) 8) b) #xffffffffffffffff))
          (incf (bitreader-cnt br) 8))))

(defun peek-bits (br s n)
  "Returns the next N (at most 16) bits without consuming them"
  (declare #.*optimize*
           (type bitreader br)
           (type (integer 0 16) n))
  (when (< (bitreader-cnt br) n)
    (fill-bits br s))
  (logand (ash (bitreader-buf br) (- (the (integer 0 64) (- (bitreader-cnt br) n))))
          (1- (ash 1 n))))

(defun skip-bits (br n)
  "Consumes N bits, throwing the pending marker if they run past the data"
  (declare #.*optimize*
           (type bitreader br)
           (type (integer 0 17) n))
  (let ((cnt (- (bitreader-cnt br) n)))
    (when (< cnt (bitreader-pad br))
      (throw 'marker (bitreader-marker br)))
    (setf (bitreader-cnt br) cnt)))

;;; Recieves n bits from the stream
(defun get-bits (br s n)
  "Reads N (at most 16) bits from the stream"
  (declare #.*optimize*
           (type (integer 0 16) n))
  (prog1 (peek-bits br s n)
    (skip-bits br n)))

;;; The DECODE procedure, for codes longer than the 9-bit lookup table
(defun huff-decode-slow (table code16)
  "Decodes the Huffman code at the start of the 16 bits CODE16. Returns the
value and the code length (17 for an invalid code)."
  (declare #.*optimize*
           (type huffstruct table)
           (type (unsigned-byte 16) code16))
  (let ((maxcode (huffstruct-maxcode table))
        (mincode (huffstruct-mincode table))
        (valptr (huffstruct-valptr table))
        (huffval (huffstruct-huffval table)))
    (declare (type (simple-array fixnum (*)) maxcode mincode valptr)
             (type uint8-array huffval))
    (loop for l fixnum from 10 to 16
          for code fixnum = (ash code16 (minus l 16))
          when (<= code (aref maxcode l))
            do (return (values (aref huffval (plus (aref valptr l) (minus code (aref mincode l)))) l))
          finally (return (values 0 17)))))

;;; The DECODE procedure, with a table lookup for codes of up to 9 bits
(defun huff-decode (table br s)
  "Decodes one Huffman-coded value"
  (declare #.*optimize*
           (type huffstruct table))
  (let* ((code16 (peek-bits br s 16))
         (entry (aref (huffstruct-lookup table) (ash code16 -7))))
    (declare (type (unsigned-byte 16) code16 entry))
    (if (/= entry 0)
        (progn (skip-bits br (ash entry -8))
               (logand entry 255))
        (multiple-value-bind (value length) (huff-decode-slow table code16)
          (skip-bits br length)
          value))))

;;; The same operations on a bit buffer held in local variables
(defmacro with-local-bits ((br s) &body body)
  "Evaluates BODY with the bit buffer of BR in local variables, written back
when BODY returns. Within BODY, (PEEK N), (SKIP N), (BITS N) and (HUFF TABLE)
work like PEEK-BITS, SKIP-BITS, GET-BITS and HUFF-DECODE."
  (let ((buf (gensym "BUF")) (cnt (gensym "CNT")))
    `(let ((,buf (bitreader-buf ,br))
           (,cnt (bitreader-cnt ,br)))
       (declare (type (unsigned-byte 64) ,buf)
                (type (integer 0 64) ,cnt))
       (macrolet ((peek (n)
                    `(progn
                       (when (< ,',cnt ,n)
                         (setf (bitreader-buf ,',br) ,',buf (bitreader-cnt ,',br) ,',cnt)
                         (fill-bits ,',br ,',s)
                         (setf ,',buf (bitreader-buf ,',br) ,',cnt (bitreader-cnt ,',br)))
                       (logand (ash ,',buf (- (the (integer 0 64) (- ,',cnt ,n)))) (1- (ash 1 ,n)))))
                  (skip (n)
                    `(let ((left (- ,',cnt ,n)))
                       (when (< left (bitreader-pad ,',br))
                         (throw 'marker (bitreader-marker ,',br)))
                       (setf ,',cnt left)))
                  (bits (n)
                    `(let ((nbits ,n))
                       (prog1 (peek nbits) (skip nbits))))
                  (huff (table)
                    `(let* ((tab ,table)
                            (code16 (peek 16))
                            (entry (aref (huffstruct-lookup tab) (ash code16 -7))))
                       (declare (type (unsigned-byte 16) code16 entry))
                       (if (/= entry 0)
                           (progn (skip (ash entry -8))
                                  (logand entry 255))
                           (multiple-value-bind (value length) (huff-decode-slow tab code16)
                             (skip length)
                             value)))))
         (multiple-value-prog1 (progn ,@body)
           (setf (bitreader-buf ,br) ,buf
                 (bitreader-cnt ,br) ,cnt))))))

;;; Natural (row-major) position of each zigzag-ordered coefficient
(declaim (type fixnum-array +zigzag-natural+))
(define-constant +zigzag-natural+
    (let ((table (make-array 64 :element-type 'fixnum)))
      (dotimes (row 8 table)
        (dotimes (col 8)
          (setf (aref table (u8ref +zigzag-index+ col row)) (+ (* row 8) col))))))

(defun dequant-table (image c)
  "Returns the quantization table of component C in zigzag order"
  (let ((q (aref (descriptor-qtables image) (aref (descriptor-qdest image) c)))
        (qz (make-array 64 :element-type 'fixnum)))
    (dotimes (k 64 qz)
      (let ((n (aref +zigzag-natural+ k)))
        (setf (aref qz k) (u8ref q (mod n 8) (floor n 8)))))))

;;; Decodes single 8x8 block
(defun decode-block (block dc-table ac-table qz br s preds comp)
  "Reads one 8x8 block into BLOCK, dequantized and in natural order"
  (declare #.*optimize*
           (type sint32-array block)
           (type fixnum-array qz)
           (type (simple-array sint16 (*)) preds)
           (type fixnum comp))
  (fill block 0)
  (with-local-bits (br s)
    ;; DC coefficient
    (let* ((tt (min 16 (the fixnum (huff dc-table))))
           (dc (plus (aref preds comp) (extend (bits tt) tt))))
      (setf (aref preds comp) dc
            (aref block 0) (mul dc (aref qz 0))))
    ;; AC coefficients
    (loop with fast-ac of-type (simple-array sint16 (512)) = (huffstruct-fast-ac ac-table)
          with natural of-type fixnum-array = +zigzag-natural+
          with k fixnum = 1
          until (> k 63)
          do (let ((fast (aref fast-ac (peek 9))))
               (declare (type fixnum fast))
               (if (/= fast 0)
                   ;; Short code and value: decoded with a single lookup
                   (progn (skip (logand fast 15))
                          (incf k (logand (ash fast -4) 15))
                          (let ((z (logand k 63)))
                            (setf (aref block (aref natural z)) (mul (ash fast -8) (aref qz z))))
                          (incf k))
                   (let* ((rs (huff ac-table))
                          (ssss (logand rs 15))
                          (r (ash rs -4)))
                     (declare (type fixnum rs ssss r))
                     (cond ((zerop ssss)
                            (if (= r 15)
                                (incf k 16)
                                (return)))
                           (t (incf k r)
                              (let ((z (logand k 63)))
                                (setf (aref block (aref natural z))
                                      (mul (extend (bits ssss) ssss) (aref qz z))))
                              (incf k))))))))
  block)

;;; Dequanitzation
(defun dequantize (x y block table)
  "Dequantizes a single sample"
  (declare #.*optimize*
           (type fixnum x y))
  (mul (s16ref block x y) (u8ref table x y)))

;;;Macro that bounds value in IDCT
(defmacro dct-limit (n)
  `(aref *idct-limit-array* (logand (plus ,n 255) 511)))

;;; Inverse LLM DCT and dequantization
(defun inverse-llm-dct (block q-table ws)
  "Performs Inverse LMM DCT and dequantization"
  (let ((tmp0 0) (tmp1 0) (tmp2 0) (tmp3 0)
        (tmp10 0) (tmp11 0) (tmp12 0) (tmp13 0)
        (z1 0) (z2 0) (z3 0) (z4 0) (z5 0)
        (dcval 0))
    (declare #.*optimize*
             (type fixnum tmp0 tmp1 tmp2 tmp3 tmp10 tmp11 tmp12 tmp13 z1 z2 z3 z4 z5 dcval)
             (type sint16-2d-array block)
             (dynamic-extent tmp0 tmp1 tmp2 tmp3 tmp10 tmp11 tmp12 tmp13 z1 z2 z3 z4 z5 dcval))
    (loop for dptr fixnum from 0 to 7 ; iterating over columns
          if (and (zerop (s16ref block dptr 1))
                  (zerop (s16ref block dptr 2))
                  (zerop (s16ref block dptr 3))
                  (zerop (s16ref block dptr 4))
                  (zerop (s16ref block dptr 5))
                  (zerop (s16ref block dptr 6))
                  (zerop (s16ref block dptr 7))) do
          (setf dcval (ash (the fixnum (dequantize dptr 0 block q-table)) 1))
          (setf (s16ref ws dptr 0) dcval)
          (setf (s16ref ws dptr 1) dcval)
          (setf (s16ref ws dptr 2) dcval)
          (setf (s16ref ws dptr 3) dcval)
          (setf (s16ref ws dptr 4) dcval)
          (setf (s16ref ws dptr 5) dcval)
          (setf (s16ref ws dptr 6) dcval)
          (setf (s16ref ws dptr 7) dcval)
          else do
          (setf z2 (dequantize dptr 2 block q-table))
          (setf z3 (dequantize dptr 6 block q-table))
          (setf z1 (mul (plus z2 z3) +FIX-0-541196100+))
          (setf tmp2 (plus z1 (mul z3 (- +FIX-1-847759065+))))
          (setf tmp3 (plus z1 (mul z2 +FIX-0-765366865+)))
          (setf z2 (dequantize dptr 0 block q-table))
          (setf z3 (dequantize dptr 4 block q-table))
          (setf tmp0 (ash (plus z2 z3) dct-shift))
          (setf tmp1 (ash (minus z2 z3) dct-shift))
          (setf tmp10 (plus tmp0 tmp3))
          (setf tmp13 (minus tmp0 tmp3))
          (setf tmp11 (plus tmp1 tmp2))
          (setf tmp12 (minus tmp1 tmp2))
          (setf tmp0 (dequantize dptr 7 block q-table))
          (setf tmp1 (dequantize dptr 5 block q-table))
          (setf tmp2 (dequantize dptr 3 block q-table))
          (setf tmp3 (dequantize dptr 1 block q-table))
          (setf z1 (plus tmp0 tmp3))
          (setf z2 (plus tmp1 tmp2))
          (setf z3 (plus tmp0 tmp2))
          (setf z4 (plus tmp1 tmp3))
          (setf z5 (mul (plus z3 z4) +FIX-1-175875602+))
          (setf tmp0 (mul tmp0 +FIX-0-298631336+))
          (setf tmp1 (mul tmp1 +FIX-2-053119869+))
          (setf tmp2 (mul tmp2 +FIX-3-072711026+))
          (setf tmp3 (mul tmp3 +FIX-1-501321110+))
          (setf z1 (mul z1 (- +FIX-0-899976223+)))
          (setf z2 (mul z2 (- +FIX-2-562915447+)))
          (setf z3 (mul z3 (- +FIX-1-961570560+)))
          (setf z4 (mul z4 (- +FIX-0-390180644+)))
          (incf z3 z5)
          (incf z4 z5)
          (incf tmp0 (plus z1 z3))
          (incf tmp1 (plus z2 z4))
          (incf tmp2 (plus z2 z3))
          (incf tmp3 (plus z1 z4))
          (setf (s16ref ws dptr 0) (descale (plus tmp10 tmp3) +shift-1+))
          (setf (s16ref ws dptr 7) (descale (minus tmp10 tmp3) +shift-1+))
          (setf (s16ref ws dptr 1) (descale (plus tmp11 tmp2) +shift-1+))
          (setf (s16ref ws dptr 6) (descale (minus tmp11 tmp2) +shift-1+))
          (setf (s16ref ws dptr 2) (descale (plus tmp12 tmp1) +shift-1+))
          (setf (s16ref ws dptr 5) (descale (minus tmp12 tmp1) +shift-1+))
          (setf (s16ref ws dptr 3) (descale (plus tmp13 tmp0) +shift-1+))
          (setf (s16ref ws dptr 4) (descale (minus tmp13 tmp0) +shift-1+)))

    (loop for row of-type sint16-array across block ; iterating over rows
          for inrow of-type sint16-array across ws
          if (not (find-if-not #'zerop inrow :start 1)) do
          (setf dcval (dct-limit (descale (aref inrow 0) 4)))
          (setf (aref row 0) dcval)
          (setf (aref row 1) dcval)
          (setf (aref row 2) dcval)
          (setf (aref row 3) dcval)
          (setf (aref row 4) dcval)
          (setf (aref row 5) dcval)
          (setf (aref row 6) dcval)
          (setf (aref row 7) dcval)
          else do
          (setf z2 (aref inrow 2))
          (setf z3 (aref inrow 6))
          (setf z1 (mul (plus z2 z3) +FIX-0-541196100+))
          (setf tmp2 (plus z1 (mul z3 (- +FIX-1-847759065+))))
          (setf tmp3 (plus z1 (mul z2 +FIX-0-765366865+)))
          (setf tmp0 (ash (plus (aref inrow 0) (aref inrow 4)) dct-shift))
          (setf tmp1 (ash (minus (aref inrow 0) (aref inrow 4)) dct-shift))
          (setf tmp10 (plus tmp0 tmp3))
          (setf tmp13 (minus tmp0 tmp3))
          (setf tmp11 (plus tmp1 tmp2))
          (setf tmp12 (minus tmp1 tmp2))
          (setf tmp0 (aref inrow 7))
          (setf tmp1 (aref inrow 5))
          (setf tmp2 (aref inrow 3))
          (setf tmp3 (aref inrow 1))
          (setf z1 (plus tmp0 tmp3))
          (setf z2 (plus tmp1 tmp2))
          (setf z3 (plus tmp0 tmp2))
          (setf z4 (plus tmp1 tmp3))
          (setf z5 (mul (plus z3 z4) +FIX-1-175875602+))
          (setf tmp0 (mul tmp0 +FIX-0-298631336+))
          (setf tmp1 (mul tmp1 +FIX-2-053119869+))
          (setf tmp2 (mul tmp2 +FIX-3-072711026+))
          (setf tmp3 (mul tmp3 +FIX-1-501321110+))
          (setf z1 (mul z1 (- +FIX-0-899976223+)))
          (setf z2 (mul z2 (- +FIX-2-562915447+)))
          (setf z3 (mul z3 (- +FIX-1-961570560+)))
          (setf z4 (mul z4 (- +FIX-0-390180644+)))
          (incf z3 z5)
          (incf z4 z5)
          (incf tmp0 (plus z1 z3))
          (incf tmp1 (plus z2 z4))
          (incf tmp2 (plus z2 z3))
          (incf tmp3 (plus z1 z4))
          (setf (aref row 0) (dct-limit (descale (plus tmp10 tmp3) +shift+4+)))
          (setf (aref row 7) (dct-limit (descale (minus tmp10 tmp3) +shift+4+)))
          (setf (aref row 1) (dct-limit (descale (plus tmp11 tmp2) +shift+4+)))
          (setf (aref row 6) (dct-limit (descale (minus tmp11 tmp2) +shift+4+)))
          (setf (aref row 2) (dct-limit (descale (plus tmp12 tmp1) +shift+4+)))
          (setf (aref row 5) (dct-limit (descale (minus tmp12 tmp1) +shift+4+)))
          (setf (aref row 3) (dct-limit (descale (plus tmp13 tmp0) +shift+4+)))
          (setf (aref row 4) (dct-limit (descale (minus tmp13 tmp0) +shift+4+))))))

;;; One-dimensional inverse LLM DCT, generic over the arithmetic used
(defmacro llm-idct-1d ((add sub mulc shl) inputs outputs &body body)
  "Binds OUTPUTS to the 1-D inverse LLM DCT of the 8 INPUTS, scaled by
2^dct-shift, and evaluates BODY. ADD, SUB, MULC (multiplication by a constant)
and SHL (shift left by dct-shift) name the operators to use."
  (let ((in (loop repeat 8 collect (gensym "IN")))
        (tmp (loop repeat 17 collect (gensym "TMP"))))
    (destructuring-bind (i0 i1 i2 i3 i4 i5 i6 i7) in
      (destructuring-bind (z1 tmp2 tmp3 tmp0 tmp1 tmp10 tmp11 tmp12 tmp13 z5 z1b z2 z3 z4 t0 t1 t2) tmp
        (let ((t3 (gensym "TMP")))
          `(let* (,@(mapcar #'list in inputs)
                  ;; even part
                  (,z1 (,mulc (,add ,i2 ,i6) +FIX-0-541196100+))
                  (,tmp2 (,add ,z1 (,mulc ,i6 (- +FIX-1-847759065+))))
                  (,tmp3 (,add ,z1 (,mulc ,i2 +FIX-0-765366865+)))
                  (,tmp0 (,shl (,add ,i0 ,i4)))
                  (,tmp1 (,shl (,sub ,i0 ,i4)))
                  (,tmp10 (,add ,tmp0 ,tmp3))
                  (,tmp13 (,sub ,tmp0 ,tmp3))
                  (,tmp11 (,add ,tmp1 ,tmp2))
                  (,tmp12 (,sub ,tmp1 ,tmp2))
                  ;; odd part
                  (,z5 (,mulc (,add (,add ,i7 ,i3) (,add ,i5 ,i1)) +FIX-1-175875602+))
                  (,z1b (,mulc (,add ,i7 ,i1) (- +FIX-0-899976223+)))
                  (,z2 (,mulc (,add ,i5 ,i3) (- +FIX-2-562915447+)))
                  (,z3 (,add (,mulc (,add ,i7 ,i3) (- +FIX-1-961570560+)) ,z5))
                  (,z4 (,add (,mulc (,add ,i5 ,i1) (- +FIX-0-390180644+)) ,z5))
                  (,t0 (,add (,mulc ,i7 +FIX-0-298631336+) (,add ,z1b ,z3)))
                  (,t1 (,add (,mulc ,i5 +FIX-2-053119869+) (,add ,z2 ,z4)))
                  (,t2 (,add (,mulc ,i3 +FIX-3-072711026+) (,add ,z2 ,z3)))
                  (,t3 (,add (,mulc ,i1 +FIX-1-501321110+) (,add ,z1b ,z4)))
                  ,@(mapcar #'list outputs
                            `((,add ,tmp10 ,t3) (,add ,tmp11 ,t2) (,add ,tmp12 ,t1) (,add ,tmp13 ,t0)
                              (,sub ,tmp13 ,t0) (,sub ,tmp12 ,t1) (,sub ,tmp11 ,t2) (,sub ,tmp10 ,t3))))
             ,@body))))))

;;; Inverse LLM DCT of a decoded block, written straight into a component plane
(defun idct-block-scalar (block ws plane pos stride)
  "Performs inverse LLM DCT on BLOCK (dequantized, natural order) and stores the
samples, level shifted and clamped, in PLANE at POS, rows STRIDE apart"
  (declare #.*optimize*
           (type sint32-array block)
           (type fixnum-array ws)
           (type uint8-array plane)
           (type fixnum pos stride))
  (macrolet ((mulc (x c) `(mul ,x ,c))
             (shl (x) `(ash ,x dct-shift))
             (sample (v) ; level shift and clamp
               `(let ((s (plus ,v 127)))
                  (declare (type fixnum s))
                  (if (logtest s -256) (if (minusp s) 0 255) s))))
    (dotimes (col 8) ; iterating over columns
      (macrolet ((in (row) `(aref block (plus ,(* row 8) col)))
                 (out (row v) `(setf (aref ws (plus ,(* row 8) col)) ,v)))
        (if (and (zerop (in 1)) (zerop (in 2)) (zerop (in 3)) (zerop (in 4))
                 (zerop (in 5)) (zerop (in 6)) (zerop (in 7)))
            (let ((dcval (ash (in 0) 1)))
              (dotimes (row 8) (setf (aref ws (plus (mul row 8) col)) dcval)))
            (llm-idct-1d (plus minus mulc shl) ((in 0) (in 1) (in 2) (in 3) (in 4) (in 5) (in 6) (in 7))
                         (o0 o1 o2 o3 o4 o5 o6 o7)
              (out 0 (descale o0 +shift-1+)) (out 1 (descale o1 +shift-1+))
              (out 2 (descale o2 +shift-1+)) (out 3 (descale o3 +shift-1+))
              (out 4 (descale o4 +shift-1+)) (out 5 (descale o5 +shift-1+))
              (out 6 (descale o6 +shift-1+)) (out 7 (descale o7 +shift-1+))))))
    (loop for rp fixnum from 0 below 64 by 8 ; iterating over rows
          for op fixnum from pos by stride do
          (macrolet ((in (col) `(aref ws (plus rp ,col)))
                     (out (col v) `(setf (aref plane (plus op ,col)) (sample ,v))))
            (if (and (zerop (in 1)) (zerop (in 2)) (zerop (in 3)) (zerop (in 4))
                     (zerop (in 5)) (zerop (in 6)) (zerop (in 7)))
                (let ((dcval (sample (descale (in 0) 4))))
                  (fill plane dcval :start op :end (plus op 8)))
                (llm-idct-1d (plus minus mulc shl) ((in 0) (in 1) (in 2) (in 3) (in 4) (in 5) (in 6) (in 7))
                             (o0 o1 o2 o3 o4 o5 o6 o7)
                  (out 0 (descale o0 +shift+4+)) (out 1 (descale o1 +shift+4+))
                  (out 2 (descale o2 +shift+4+)) (out 3 (descale o3 +shift+4+))
                  (out 4 (descale o4 +shift+4+)) (out 5 (descale o5 +shift+4+))
                  (out 6 (descale o6 +shift+4+)) (out 7 (descale o7 +shift+4+))))))))

#+cl-jpeg-neon
(defmacro neon-idct-block (block plane pos stride)
  "Expands into the inverse DCT of IDCT-BLOCK-SCALAR done four columns or rows at
a time with NEON: a column pass over the block rows, a 4x4 transposition of each
quarter, a row pass and a transposition back."
  (labels ((syms (prefix)
             (loop for i below 8 collect (loop for j below 2 collect (gensym (format nil "~A~D~D-" prefix i j)))))
           (ref (m i j) (nth j (nth i m))))
    (let ((p (syms "P")) (q (syms "Q")) (o (syms "O")) (r (syms "R"))
          (raw (loop repeat 8 collect (gensym "RAW"))))
      (labels ((columns (h body) ; block columns 4h..4h+3 -> P[row][h]
                 `(llm-idct-1d (add sub mulc shl)
                               ,(loop for row below 8 collect `(neon:s32.4-aref ,block ,(+ (* 8 row) (* 4 h))))
                               ,raw
                    (let ,(loop for row below 8 collect `(,(ref p row h) (descale ,(nth row raw) ,+shift-1+)))
                      ,body)))
               (rows (g body) ; rows 4g..4g+3, Q[col][g] -> O[col][g]
                 `(llm-idct-1d (add sub mulc shl)
                               ,(loop for k below 8 collect (ref q k g))
                               ,raw
                    (let ,(loop for k below 8 collect `(,(ref o k g) (sample ,(nth k raw))))
                      ,body)))
               (transpose (src dst g h body) ; 4x4 tile src[4g+j][h] -> dst[4h+j][g]
                 `(multiple-value-bind ,(loop for j below 4 collect (ref dst (+ (* 4 h) j) g))
                      (transpose4 ,@(loop for j below 4 collect (ref src (+ (* 4 g) j) h)))
                    ,body))
               (transpose-all (src dst body)
                 (transpose src dst 0 0 (transpose src dst 0 1 (transpose src dst 1 0 (transpose src dst 1 1 body))))))
        `(macrolet ((add (a b) `(neon:s32.4+ ,a ,b))
                    (sub (a b) `(neon:s32.4- ,a ,b))
                    (mulc (a c) `(neon:s32.4* ,a (neon:s32.4-broadcast ,c)))
                    (shl (a) `(neon:s32.4-shiftl ,a dct-shift))
                    (descale (v n) `(neon:s32.4-shiftr (neon:s32.4+ ,v (neon:s32.4-broadcast ,(ash 1 (1- n)))) ,n))
                    ;; descale, level shift by 127 and round in one go; clamped when narrowing
                    (sample (v) `(neon:s32.4-shiftr
                                  (neon:s32.4+ ,v (neon:s32.4-broadcast ,(+ (ash 1 (1- +shift+4+)) (ash 127 +shift+4+))))
                                  +shift+4+)))
           (flet ((transpose4 (r0 r1 r2 r3)
                    (let ((t0 (neon:s64.2! (neon:s32.4-transpose-even r0 r1)))
                          (t1 (neon:s64.2! (neon:s32.4-transpose-odd r0 r1)))
                          (t2 (neon:s64.2! (neon:s32.4-transpose-even r2 r3)))
                          (t3 (neon:s64.2! (neon:s32.4-transpose-odd r2 r3))))
                      (values (neon:s32.4! (neon:s64.2-transpose-even t0 t2))
                              (neon:s32.4! (neon:s64.2-transpose-even t1 t3))
                              (neon:s32.4! (neon:s64.2-transpose-odd t0 t2))
                              (neon:s32.4! (neon:s64.2-transpose-odd t1 t3)))))
                  (row-bytes (lo hi)
                    ;; 8 samples of a row, clamped to 0..255, as u16.8
                    (neon:u16.8! (neon:s16.8-max (neon:s16.8-broadcast 0)
                                                 (neon:s16.8-min (neon:s16.8-broadcast 255)
                                                                 (neon:s16.8-from-s32.4-saturating-hi
                                                                  (neon:s16.8-from-s32.4-saturating lo) hi))))))
             (declare (inline transpose4 row-bytes))
             ,(columns 0 (columns 1 (transpose-all p q
                (rows 0 (rows 1 (transpose-all o r
                  `(progn
                     ,@(loop for row below 8 by 2
                             collect `(multiple-value-bind (a b)
                                          (neon:u64.2-values
                                           (neon:u64.2! (neon:u8.16-from-u16.8-hi
                                                         (neon:u8.16-from-u16.8 (row-bytes ,(ref r row 0) ,(ref r row 1)))
                                                         (row-bytes ,(ref r (1+ row) 0) ,(ref r (1+ row) 1)))))
                                        ;; 8 byte stores: block rows are 8-aligned in the plane
                                        (setf (sb-kernel:%vector-raw-bits ,plane (ash (plus ,pos (mul ,row ,stride)) -3)) a
                                              (sb-kernel:%vector-raw-bits ,plane (ash (plus ,pos (mul ,(1+ row) ,stride)) -3)) b))))))))))))))))

(defun idct-block (block ws plane pos stride)
  "Performs inverse LLM DCT on BLOCK (dequantized, natural order) and stores the
samples, level shifted and clamped, in PLANE at POS, rows STRIDE apart"
  (declare #.*optimize*
           (type sint32-array block)
           (type fixnum-array ws)
           (type uint8-array plane)
           (type fixnum pos stride)
           #+cl-jpeg-neon (ignore ws))
  #+cl-jpeg-neon (neon-idct-block block plane pos stride)
  #-cl-jpeg-neon (idct-block-scalar block ws plane pos stride)
  nil)

;;; Scan geometry, shared by sequential and progressive decoding
(defun scan-components (image scan)
  "Returns the image component indices of the components of SCAN"
  (let ((comps (make-array (scan-ncomp scan) :element-type 'fixnum)))
    (dotimes (i (scan-ncomp scan) comps)
      (setf (aref comps i) (position (first (aref (scan-cdesc scan) i)) (descriptor-cid image))))))

(defun scan-units (image comps)
  "Returns the number of data units (MCUs, or blocks of a non-interleaved scan) in a scan"
  (if (= (length comps) 1)
      (multiple-value-bind (bw bh) (component-blocks image (aref comps 0))
        (* bw bh))
      (* (descriptor-mcus-x image) (descriptor-mcus-y image))))

(defun map-scan-blocks (image scan comps start end fn)
  "Calls FN with the scan component index, the image component index and the
row and column of each block in data units START below END of SCAN, in decoding
order. SCAN-X is kept as the number of data units done."
  (declare #.*optimize*
           (type fixnum start end)
           (type (simple-array fixnum (*)) comps)
           (type function fn))
  (if (= (length comps) 1)
      ;; Non-interleaved scan: raster order over the blocks of one component
      (let ((bw (component-blocks image (aref comps 0))))
        (declare (type fixnum bw))
        (loop for unit fixnum from start below end do
              (multiple-value-bind (row col) (floor unit bw)
                (funcall fn 0 (aref comps 0) row col))
              (setf (scan-x scan) (1+ unit))))
      ;; Interleaved scan: H x V blocks of each component per MCU
      (let ((mcus-x (descriptor-mcus-x image)))
        (declare (type fixnum mcus-x))
        (loop for unit fixnum from start below end do
              (multiple-value-bind (mcu-y mcu-x) (floor unit mcus-x)
                (loop for sc fixnum from 0 below (length comps)
                      for c fixnum = (aref comps sc)
                      for h fixnum = (aref (descriptor-H image) c)
                      for v fixnum = (aref (descriptor-V image) c) do
                      (dotimes (by v)
                        (dotimes (bx h)
                          (funcall fn sc c (plus (mul mcu-y v) by) (plus (mul mcu-x h) bx))))))
              (setf (scan-x scan) (1+ unit))))))

(defun interval-end (image scan total-units)
  "Returns the end of the restart interval starting at the current data unit"
  (let ((ri (descriptor-restart-interval image)))
    (if (zerop ri) total-units (min total-units (+ (scan-x scan) ri)))))

(defun chunk-result (scan br total-units)
  "Returns what DECODE-SCAN-INTERVALS expects from a chunk decoder: :RESTART (or
:RESTART-READ, if the RSTn marker was already consumed) when an interval ended
with more data units left in the scan, otherwise NIL or the marker that the
bit reader met"
  ;; The bit reader may have read ahead into the marker that follows
  (let ((marker (bitreader-marker br)))
    (cond ((>= (scan-x scan) total-units) marker)
          ((eq marker 'restart) :restart-read)
          (marker)
          (t :restart))))

(defun read-scan-header (image)
  "Reads a SOS header, returning the new scan"
  (let ((scan (make-scan)))
    (read-jpeg-byte image) ; length
    (read-jpeg-byte image)
    (loop with ncomp fixnum = (setf (scan-ncomp scan) (read-jpeg-byte image))
          for j fixnum from 0 below ncomp do
          (setf (first (aref (scan-cdesc scan) j)) (read-jpeg-byte image)) ; component ID
          (setf (second (aref (scan-cdesc scan) j)) (read-jpeg-byte image))) ; Td and Ta nibbles
    (setf (scan-ss scan) (read-jpeg-byte image))          ; spectral selection start
    (setf (scan-se scan) (read-jpeg-byte image))          ; spectral selection end
    (let ((ahal (read-jpeg-byte image)))                   ; successive approximation
      (setf (scan-ah scan) (ash ahal -4))
      (setf (scan-al scan) (logand ahal 15)))
    scan))

(defun decode-scan-intervals (image scan chunk-decoder)
  "Decodes SCAN by calling CHUNK-DECODER for each restart interval. Returns the
marker that terminated the scan, or 0 if it ended cleanly."
  ;; Progressive data units may consume no bits at all (EOB runs) or a
  ;; single bit (DC refinement), so restart intervals can't be delimited by
  ;; waiting for the bit reader to hit a marker: data units are counted instead.
  (let ((ri (descriptor-restart-interval image)))
    (loop for term = (funcall chunk-decoder) do
          (case term
            ((nil) (return 0))
            (:restart-read)
            ;; Interval completed: consume its RSTn marker
            (:restart
             (let ((mk (read-marker image)))
               (unless (<= +M_RST0+ mk +M_RST7+)
                 (return mk))))
            ;; Bit reader ran into RSTn early (corrupt data): resync at the
            ;; start of the next interval
            (restart
             (if (zerop ri)
                 (return 0)
                 (setf (scan-x scan) (* (1+ (floor (scan-x scan) ri)) ri))))
            (t (return term))))))

;;; Reads and decodes either whole scan or restart interval
(defun decode-chunk (image scan comps total-units dc-tables ac-tables dequant)
  "Decodes one restart interval of a sequential scan (or the whole scan) into the component planes"
  (let ((br (make-bitreader))
        (preds (make-array (length comps) :initial-element 0 :element-type 'sint16))
        (block (descriptor-coefs image))
        (ws (descriptor-idct-ws image))
        (planes (descriptor-planes image))
        (bpr (descriptor-blocks-per-row image)))
    (declare #.*optimize*
             (type simple-vector dc-tables ac-tables dequant planes bpr)
             (type (simple-array sint16 (*)) preds))
    (flet ((decode-one (sc c row col)
             (declare (type fixnum sc c row col))
             (let ((stride (mul 8 (the fixnum (svref bpr c)))))
               (declare (type fixnum stride))
               (decode-block block (svref dc-tables sc) (svref ac-tables sc) (svref dequant sc)
                             br image preds sc)
               (idct-block block ws (svref planes c)
                           (plus (mul (mul row 8) stride) (mul col 8)) stride))))
      (declare (dynamic-extent #'decode-one))
      (catch 'marker
        (map-scan-blocks image scan comps (scan-x scan) (interval-end image scan total-units)
                         #'decode-one)
        (chunk-result scan br total-units)))))

;;; ============================================================
;;; Progressive JPEG decoding functions
;;; ============================================================

;;; Decodes DC coefficient for first DC scan (Ss=0, Se=0, Ah=0)
(defun decode-dc-first (coef-buf offset al dc-table br image preds comp)
  "Decode DC coefficient for first scan. Stores ash(value, al) into coef buffer."
  (declare #.*optimize*
           (type fixnum offset al comp)
           (type (simple-array sint16 (*)) coef-buf)
           (type (simple-array sint16 (*)) preds)
           (type huffstruct dc-table)
           (type bitreader br))
  (with-local-bits (br image)
    (let* ((tt (min 16 (the fixnum (huff dc-table))))
           (diff (extend (bits tt) tt)))
      (declare (type fixnum tt diff))
      (incf diff (aref preds comp))
      (setf (aref preds comp) diff)
      (setf (aref coef-buf offset) (ash diff al)))))

;;; Decodes DC refinement scan (Ss=0, Se=0, Ah>0) - one raw bit per block
(defun decode-dc-refine (coef-buf offset al br image)
  "Refine DC coefficient: read one bit and OR into position al."
  (declare #.*optimize*
           (type fixnum offset al)
           (type (simple-array sint16 (*)) coef-buf)
           (type bitreader br))
  (with-local-bits (br image)
    (when (= (bits 1) 1)
      (setf (aref coef-buf offset)
            (logior (aref coef-buf offset) (ash 1 al))))))

;;; Decodes AC coefficients for first AC scan (Ss>0, Ah=0) with EOBRUN
(defun decode-ac-first (coef-buf offset ss se al ac-table br image eobrun)
  "Decode AC first scan for coefficients ss..se with point transform al.
   Returns updated eobrun value."
  (declare #.*optimize*
           (type fixnum offset ss se al eobrun)
           (type (simple-array sint16 (*)) coef-buf)
           (type huffstruct ac-table)
           (type bitreader br))
  (when (> eobrun 0)
    (return-from decode-ac-first (1- eobrun)))
  (with-local-bits (br image)
    (loop with k fixnum = ss
          while (<= k se) do
          (let* ((rs (huff ac-table))
                 (s (logand rs 15))
                 (r (ash rs -4)))
            (declare (type fixnum rs s r))
            (cond
              ;; Non-zero coefficient
              ((> s 0)
               (incf k r)
               (setf (aref coef-buf (+ offset (logand k 63)))
                     (ash (extend (bits s) s) al))
               (incf k))
              ;; ZRL: skip 16 zeros
              ((= r 15)
               (incf k 16))
              ;; EOBn: end of band run; the current block is the first in the run
              (t
               (return (1- (+ (ash 1 r) (if (> r 0) (bits r) 0)))))))
          finally (return 0))))

;;; Decodes AC refinement scan (Ss>0, Ah>0)
(defun decode-ac-refine (coef-buf offset ss se al ac-table br image eobrun)
  "Refine AC coefficients with correction bits and new coefficient introduction.
   Returns updated eobrun value."
  (declare #.*optimize*
           (type fixnum offset ss se al eobrun)
           (type (simple-array sint16 (*)) coef-buf)
           (type huffstruct ac-table)
           (type bitreader br))
  (with-local-bits (br image)
    (let ((p1 (ash 1 al))
          (m1 (- (ash 1 al)))
          (k ss))
      (declare (type fixnum p1 m1 k))
      (macrolet ((apply-correction (pos)
                   ;; Reads one correction bit for a nonzero coefficient at coef-buf[pos]
                   `(let* ((pos ,pos)
                           (coeff (aref coef-buf pos)))
                      (declare (type fixnum pos coeff))
                      (when (and (/= coeff 0)
                                 (= (bits 1) 1)
                                 (zerop (logand coeff p1)))
                        (incf (aref coef-buf pos) (if (> coeff 0) p1 m1))))))
        (block decode
          ;; If in an EOB run, just apply correction bits to existing nonzeros
          (when (> eobrun 0)
            (loop for j fixnum from ss to se do
                  (apply-correction (+ offset j)))
            (return-from decode (1- eobrun)))
          ;; Decode new symbols
          (loop while (<= k se) do
                (let* ((rs (huff ac-table))
                       (s (logand rs 15))
                       (r (ash rs -4)))
                  (declare (type fixnum rs s r))
                  (cond
                    ;; s=1: new nonzero coefficient
                    ((= s 1)
                     (let ((new-value (if (= (bits 1) 1) p1 m1)))
                       (declare (type fixnum new-value))
                       ;; Skip r zero-valued positions (applying corrections to nonzeros)
                       (loop while (and (<= k se) (> r 0)) do
                             (if (/= (aref coef-buf (+ offset k)) 0)
                                 (apply-correction (+ offset k))
                                 (decf r))
                             (incf k))
                       ;; Skip past remaining nonzeros to find the zero position
                       (loop while (and (<= k se)
                                        (/= (aref coef-buf (+ offset k)) 0))
                             do (apply-correction (+ offset k))
                                (incf k))
                       ;; Place the new coefficient
                       (when (<= k se)
                         (setf (aref coef-buf (+ offset k)) new-value)
                         (incf k))))
                    ;; s=0, r=15: ZRL with correction bits
                    ((= r 15)
                     (let ((zeros-to-skip 16))
                       (declare (type fixnum zeros-to-skip))
                       (loop while (and (<= k se) (> zeros-to-skip 0)) do
                             (if (/= (aref coef-buf (+ offset k)) 0)
                                 (apply-correction (+ offset k))
                                 (decf zeros-to-skip))
                             (incf k))))
                    ;; s=0, r<15: EOBn
                    (t
                     (let ((run (+ (ash 1 r) (if (> r 0) (bits r) 0))))
                       (declare (type fixnum run))
                       ;; Apply correction bits to remaining nonzeros in this block
                       (loop while (<= k se) do
                             (apply-correction (+ offset k))
                             (incf k))
                       (return-from decode (1- run)))))))
          ;; Normal completion (no EOB)
          0)))))

;;; Main progressive chunk decoder - processes one restart interval
(defun decode-progressive-chunk (image scan comps total-units)
  "Decode one restart interval of a progressive scan into coefficient buffers."
  (let* ((br (make-bitreader))
         (ncomp (scan-ncomp scan))
         (ss (scan-ss scan))
         (se (scan-se scan))
         (al (scan-al scan))
         (dc-scan-p (and (zerop ss) (zerop se)))
         (first-scan-p (zerop (scan-ah scan)))
         ;; huff-ac stores DC tables (tc=0), huff-dc stores AC tables (tc=1)
         ;; For DC scans use Td (high nibble) to select DC table from huff-ac
         ;; For AC scans use Ta (low nibble) to select AC table from huff-dc
         (tables (coerce (loop for i fixnum from 0 below ncomp
                               for tdta fixnum = (second (aref (scan-cdesc scan) i))
                               collecting (if dc-scan-p
                                              (aref (descriptor-huff-ac image) (ash tdta -4))
                                              (aref (descriptor-huff-dc image) (logand tdta 15))))
                         'simple-vector))
         (preds (make-array ncomp :initial-element 0 :element-type 'sint16))
         (eobrun 0)
         (coef-buffers (descriptor-coef-buffers image))
         (bpr (descriptor-blocks-per-row image)))
    (declare #.*optimize*
             (type fixnum ncomp ss se al eobrun)
             (type simple-vector tables coef-buffers bpr)
             (type (simple-array sint16 (*)) preds))
    (flet ((decode-one (sc c row col)
             (declare (type fixnum sc c row col))
             (let ((coef-buf (svref coef-buffers c))
                   (offset (mul 64 (plus (mul row (the fixnum (svref bpr c))) col)))
                   (table (svref tables sc)))
               (declare (type (simple-array sint16 (*)) coef-buf)
                        (type fixnum offset))
               (cond
                 ;; DC first
                 ((and dc-scan-p first-scan-p)
                  (decode-dc-first coef-buf offset al table br image preds sc))
                 ;; DC refine
                 (dc-scan-p
                  (decode-dc-refine coef-buf offset al br image))
                 ;; AC first
                 (first-scan-p
                  (setf eobrun (decode-ac-first coef-buf offset ss se al table br image eobrun)))
                 ;; AC refine
                 (t
                  (setf eobrun (decode-ac-refine coef-buf offset ss se al table br image eobrun)))))))
      (declare (dynamic-extent #'decode-one))
      (catch 'marker
        (map-scan-blocks image scan comps (scan-x scan) (interval-end image scan total-units)
                         #'decode-one)
        (chunk-result scan br total-units)))))

;;; Reads SOS header and decodes one progressive scan
(defun decode-progressive-scan (image)
  "Read SOS header and decode one progressive scan into coefficient buffers.
Returns the marker that terminated the scan, or 0 if it ended cleanly."
  (let* ((scan (read-scan-header image))
         (comps (scan-components image scan))
         (total-units (scan-units image comps)))
    (decode-scan-intervals image scan
                           (lambda () (decode-progressive-chunk image scan comps total-units)))))

;;; Convert accumulated coefficients to pixel data
(defun finalize-progressive (image)
  "Dequantize and inverse transform the accumulated coefficients into the component planes."
  (let ((block (descriptor-coefs image))
        (ws (descriptor-idct-ws image))
        (natural +zigzag-natural+))
    (declare #.*optimize*
             (type sint32-array block)
             (type fixnum-array ws natural))
    (dotimes (c (descriptor-ncomp image))
      (let* ((coef-buf (aref (descriptor-coef-buffers image) c))
             (qz (dequant-table image c))
             (bpr (aref (descriptor-blocks-per-row image) c))
             (bpc (aref (descriptor-blocks-per-col image) c))
             (plane (aref (descriptor-planes image) c))
             (stride (mul 8 bpr)))
        (declare (type (simple-array sint16 (*)) coef-buf)
                 (type fixnum-array qz)
                 (type fixnum bpr bpc stride))
        (dotimes (row bpc)
          (dotimes (col bpr)
            (let ((offset (mul 64 (plus (mul row bpr) col))))
              (declare (type fixnum offset))
              (dotimes (k 64)
                (setf (aref block (aref natural k))
                      (mul (aref coef-buf (plus offset k)) (aref qz k))))
              (idct-block block ws plane (plus (mul (mul row 8) stride) (mul col 8)) stride))))))))

;;; Progressive frame decoding subroutine
(defun decode-progressive-frame (image buffer)
  "Decode a progressive JPEG frame (SOF2)."
  (decode-frame-beginning image buffer)
  (read-frame-components image)
  (setf (descriptor-progressive-p image) t)
  (allocate-coef-buffers image)
  ;; Process scans until EOI
  (loop with term fixnum = 0 do
        (let ((marker (interpret-markers image term)))
          (cond ((= marker +M_SOS+)
                 (setf term (or (decode-progressive-scan image) 0)))
                ((= marker +M_EOI+)
                 (return))
                (t (error 'unsupported-jpeg-frame-marker)))))
  ;; All scans done - finalize: IDCT into the component planes
  (finalize-progressive image))

;;; Scan decoding subroutine
(defun decode-scan (image)
  "Reads SOS header and decodes one sequential scan into the component planes.
Returns the marker that terminated the scan, or 0 if it ended cleanly."
  (let* ((scan (read-scan-header image))
         (comps (scan-components image scan))
         (total-units (scan-units image comps))
         (dc-tables (map 'simple-vector
                         (lambda (cd) (aref (descriptor-huff-ac image) (ash (the fixnum (second cd)) -4)))
                         (subseq (scan-cdesc scan) 0 (length comps))))
         (ac-tables (map 'simple-vector
                         (lambda (cd) (aref (descriptor-huff-dc image) (logand (the fixnum (second cd)) 15)))
                         (subseq (scan-cdesc scan) 0 (length comps))))
         (dequant (map 'simple-vector (lambda (c) (dequant-table image c)) comps)))
    (decode-scan-intervals image scan
                           (lambda () (decode-chunk image scan comps total-units
                                                    dc-tables ac-tables dequant)))))

;;; Function that bounds value in 0..255 range
(defun limit (n)
  (cond ((> n 254) 255)
        ((< n 1) 0)
        (t n)))

;;; Clamps v+256 to 0..255, for v in -256..511
(declaim (type uint8-array +clamp-table+))
(define-constant +clamp-table+
    (let ((table (make-array 768 :element-type 'uint8)))
      (dotimes (i 768 table)
        (setf (aref table i) (max 0 (min 255 (- i 256)))))))

(defun component-xmap (image c)
  "Maps each output column to the column of component C's plane it samples,
or returns NIL if they are the same"
  (let ((xmap (make-array (descriptor-width image) :element-type 'fixnum))
        (h (aref (descriptor-H image) c))
        (hmax (descriptor-hmax image)))
    (unless (= h hmax)
      (dotimes (x (length xmap) xmap)
        (setf (aref xmap x) (floor (* x h) hmax))))))

;;; YCbCr to RGB conversion coefficients, 16-bit fixed point. Samples are
;;; level shifted by 127, as in the IDCT, so the chroma is centered on 127.
(defconstant +cr-r+ 91881)  ; 1.402
(defconstant +cb-g+ -22554) ; -0.34414
(defconstant +cr-g+ -46802) ; -0.71414
(defconstant +cb-b+ 116130) ; 1.772

(defmacro ycc-term (c1 k1 &optional c2 k2)
  "Color difference contribution of centered chroma values"
  `(ash (plus (plus (mul ,c1 ,k1) ,(if c2 `(mul ,c2 ,k2) 0)) 32768) -16))

#+cl-jpeg-neon
(defun ycc-to-bgr-neon (buffer out py ry pcb rcb pcr rcr count half)
  "Converts COUNT (a multiple of 16) pixels of a row from the YCbCr planes to
BGR at OUT in BUFFER, 16 at a time. HALF means the chroma planes are
horizontally subsampled by two."
  (declare #.*optimize*
           (type uint8-array buffer py pcb pcr)
           (type fixnum out ry rcb rcr count))
  (macrolet ((interleave-index (m c)
               ;; picks channel C's bytes for the Mth 16 bytes of BGRBGR...
               `(neon:make-u8.16 ,@(loop for j below 16
                                         for g = (+ (* 16 m) j)
                                         collect (if (= (mod g 3) c) (floor g 3) 255)))))
    (let ((k127 (neon:s16.8-broadcast 127))
          (k0 (neon:s16.8-broadcast 0))
          (k255 (neon:s16.8-broadcast 255))
          (half-unit (neon:s32.4-broadcast 32768))
          (k0-32 (neon:s32.4-broadcast 0))
          (kcbb (neon:s32.4-broadcast +cb-b+))
          (kcbg (neon:s32.4-broadcast +cb-g+))
          (kcrg (neon:s32.4-broadcast +cr-g+))
          (kcrr (neon:s32.4-broadcast +cr-r+))
          (b0 (interleave-index 0 0)) (g0 (interleave-index 0 1)) (r0 (interleave-index 0 2))
          (b1 (interleave-index 1 0)) (g1 (interleave-index 1 1)) (r1 (interleave-index 1 2))
          (b2 (interleave-index 2 0)) (g2 (interleave-index 2 1)) (r2 (interleave-index 2 2)))
      (flet ((lo (v) (neon:s16.8! (neon:u16.8-from-u8.16 v)))
             (hi (v) (neon:s16.8! (neon:u16.8-from-u8.16-hi v)))
             (term (c1 k1 c2 k2)
               ;; (c1*k1 + c2*k2 + 1/2) >> 16 for the 8 lanes of c1 and c2
               (flet ((half (a1 a2)
                        (neon:s32.4-shiftr (neon:s32.4+ (neon:s32.4* a1 k1) (neon:s32.4* a2 k2) half-unit) 16)))
                 (declare (inline half))
                 (neon:s16.8-from-s32.4-saturating-hi
                  (neon:s16.8-from-s32.4-saturating
                   (half (neon:s32.4-from-s16.8 c1) (neon:s32.4-from-s16.8 c2)))
                  (half (neon:s32.4-from-s16.8-hi c1) (neon:s32.4-from-s16.8-hi c2)))))
             (pack (lo hi)
               ;; clamps two s16.8 to 0..255 and narrows them to one u8.16
               (neon:u8.16-from-u16.8-hi
                (neon:u8.16-from-u16.8 (neon:u16.8! (neon:s16.8-max k0 (neon:s16.8-min lo k255))))
                (neon:u16.8! (neon:s16.8-max k0 (neon:s16.8-min hi k255)))))
             (pick (v0 i0 v1 i1 v2 i2)
               (neon:u8.16-or (neon:u8.16-or (neon:u8.16-shuffle v0 i0) (neon:u8.16-shuffle v1 i1))
                              (neon:u8.16-shuffle v2 i2))))
        (declare (inline lo hi term pack pick))
        (loop for x fixnum from 0 below count by 16
              for p fixnum from out by 48 do
              (let* ((y16 (neon:u8.16-aref py (plus ry x)))
                     (cb16 (if half
                               (let ((c (neon:u8.16-aref pcb (plus rcb (ash x -1))))) (neon:u8.16-zip-even c c))
                               (neon:u8.16-aref pcb (plus rcb x))))
                     (cr16 (if half
                               (let ((c (neon:u8.16-aref pcr (plus rcr (ash x -1))))) (neon:u8.16-zip-even c c))
                               (neon:u8.16-aref pcr (plus rcr x))))
                     (ylo (lo y16)) (yhi (hi y16))
                     (cblo (neon:s16.8- (lo cb16) k127)) (cbhi (neon:s16.8- (hi cb16) k127))
                     (crlo (neon:s16.8- (lo cr16) k127)) (crhi (neon:s16.8- (hi cr16) k127))
                     (b (pack (neon:s16.8+ ylo (term cblo kcbb cblo k0-32)) (neon:s16.8+ yhi (term cbhi kcbb cbhi k0-32))))
                     (g (pack (neon:s16.8+ ylo (term cblo kcbg crlo kcrg)) (neon:s16.8+ yhi (term cbhi kcbg crhi kcrg))))
                     (r (pack (neon:s16.8+ ylo (term crlo kcrr crlo k0-32)) (neon:s16.8+ yhi (term crhi kcrr crhi k0-32)))))
                (setf (neon:u8.16-aref buffer p) (pick b b0 g g0 r r0)
                      (neon:u8.16-aref buffer (plus p 16)) (pick b b1 g g1 r r1)
                      (neon:u8.16-aref buffer (plus p 32)) (pick b b2 g g2 r r2))))))))

;;; Writes the decoded image to the output buffer
(defun output-planes (image convert)
  "Interleaves the component planes into the output buffer, replicating the
samples of subsampled components. With CONVERT, three components are converted
from YCbCr to BGR on the way."
  (let* ((buffer (descriptor-buffer image))
         (width (descriptor-width image))
         (height (descriptor-height image))
         (ncomp (descriptor-ncomp image))
         (vmax (descriptor-vmax image))
         (planes (descriptor-planes image))
         (strides (map 'simple-vector (lambda (n) (* 8 n)) (descriptor-blocks-per-row image)))
         (xmaps (coerce (loop for c below ncomp
                              ;; identity maps where no resampling is needed, for the fused loop
                              collect (or (component-xmap image c)
                                          (let ((id (make-array width :element-type 'fixnum)))
                                            (dotimes (x width id) (setf (aref id x) x)))))
                        'simple-vector)))
    (declare #.*optimize*
             (type uint8-array buffer)
             (type fixnum width height ncomp vmax)
             (type simple-vector planes strides xmaps))
    (flet ((plane-row (c y)
             ;; offset of the plane row that output row Y samples
             (mul (floor (mul y (the fixnum (aref (descriptor-V image) c))) vmax)
                  (the fixnum (svref strides c)))))
      (declare (inline plane-row))
      (if (and convert (= ncomp 3))
          (let* ((py (svref planes 0)) (pcb (svref planes 1)) (pcr (svref planes 2))
                 (my (svref xmaps 0)) (mcb (svref xmaps 1)) (mcr (svref xmaps 2))
                 (clamp +clamp-table+)
                 (hmax (descriptor-hmax image))
                 (hy (aref (descriptor-H image) 0))
                 (hc (aref (descriptor-H image) 1))
                 ;; pixels per row converted 16 at a time with SIMD: needs full
                 ;; resolution luma and full or half resolution chroma
                 (vector-width (if (and #+cl-jpeg-neon t #-cl-jpeg-neon nil
                                        (= hy hmax) (= hc (aref (descriptor-H image) 2))
                                        (or (= hc hmax) (= (* 2 hc) hmax)))
                                   (logandc2 width 15)
                                   0)))
            (declare (type uint8-array py pcb pcr clamp)
                     (type fixnum-array my mcb mcr)
                     (type fixnum hmax hy hc vector-width)
                     (ignorable hmax hy hc))
            (loop for y fixnum from 0 below height
                  for out fixnum from 0 by (mul width 3)
                  for ry fixnum = (plane-row 0 y)
                  for rcb fixnum = (plane-row 1 y)
                  for rcr fixnum = (plane-row 2 y) do
                  #+cl-jpeg-neon
                  (when (plusp vector-width)
                    (ycc-to-bgr-neon buffer out py ry pcb rcb pcr rcr vector-width (/= hc hmax)))
                  (loop for x fixnum from vector-width below width
                        for p fixnum from (plus out (mul vector-width 3)) by 3
                        for yy fixnum = (plus 256 (aref py (plus ry (aref my x))))
                        for cb fixnum = (minus (aref pcb (plus rcb (aref mcb x))) 127)
                        for cr fixnum = (minus (aref pcr (plus rcr (aref mcr x))) 127) do
                        (setf (aref buffer p) ; BLUE
                              (aref clamp (plus yy (ycc-term cb +cb-b+))))
                        (setf (aref buffer (plus p 1)) ; GREEN
                              (aref clamp (plus yy (ycc-term cb +cb-g+ cr +cr-g+))))
                        (setf (aref buffer (plus p 2)) ; RED
                              (aref clamp (plus yy (ycc-term cr +cr-r+)))))))
          (dotimes (c ncomp)
            (let ((plane (svref planes c))
                  (xmap (svref xmaps c)))
              (declare (type uint8-array plane)
                       (type fixnum-array xmap))
              (loop for y fixnum from 0 below height
                    for out fixnum from c by (mul width ncomp)
                    for row fixnum = (plane-row c y) do
                    (if (and (= ncomp 1) (= (the fixnum (aref (descriptor-H image) c)) (descriptor-hmax image)))
                        (replace buffer plane :start1 out :start2 row :end2 (plus row width))
                        (loop for x fixnum from 0 below width
                              for p fixnum from out by ncomp do
                              (setf (aref buffer p) (aref plane (plus row (aref xmap x)))))))))))))

(defun ycck-cmyk-convert (image)
  (let* ((buffer (descriptor-buffer image))
         (nw (mul (descriptor-width image) 4)))
    (declare #.*optimize*
	     (type (simple-array uint8 (*)) buffer)
             (type fixnum nw))
    (loop for y fixnum from 0 below (descriptor-height image)
       for yp fixnum from 0 by nw do
	 (loop for x fixnum from 0 below (descriptor-width image)
	    for py fixnum from yp by 4
	    for pu fixnum = (1+ py)
	    for pv fixnum = (plus py 2)
	    for yy fixnum = (aref buffer py)
	    for cb fixnum = (aref buffer pu)
	    for cr fixnum = (aref buffer pv) do
	      (setf (aref buffer pv)	; BLUE
		    (the uint8 (limit (minus +max-sample+ (plus yy (aref +cb-b-tab+ cb))))))
	      (setf (aref buffer pu)	; GREEN
		    (the uint8 (limit (minus +max-sample+
					     (plus yy (ash (plus
							    (aref +cb-g-tab+ cb)
							    (aref +cr-g-tab+ cr))
							   (- shift)))))))
	      (setf (aref buffer py)	; RED
		    (the uint8 (limit (minus +max-sample+ (plus yy (aref +cr-r-tab+ cr))))))))))

(defun convert-cmyk-to-rgb (buffer h w &key rgb-buffer)
  (unless rgb-buffer
    (setf rgb-buffer (make-array (* h w 3) :element-type 'uint8)))
  (loop for y fixnum from 0 below h
     for yrgb fixnum from 0 by (* w 3)
     for yp fixnum from 0 by (* w 4) do
       (loop for x fixnum from 0 below w
	  for py fixnum from yp by 4
	  for pu fixnum = (1+ py)
	  for pv fixnum = (plus py 2)
	  for pb fixnum from yrgb by 3
	  for pg fixnum = (1+ pb)
	  for pr fixnum = (plus pb 2)
	  for cyan fixnum = (aref buffer py)
	  for magenta fixnum = (aref buffer pu)
	  for yellow fixnum = (aref buffer pv)
	  for black fixnum = (aref buffer (1+ pv)) do
	    (setf (aref rgb-buffer pr) (round (mul cyan black) 255)
		  (aref rgb-buffer pg) (round (mul magenta black) 255)
		  (aref rgb-buffer pb) (round (mul yellow black) 255))))
  rgb-buffer)

(defun allocate-buffer (height width ncomp)
  (make-array (* height width ncomp) 
	      :element-type 'uint8
	      :initial-element 0))

(defun decode-frame-beginning (image buffer)
  (read-jpeg-byte image) ; length
  (read-jpeg-byte image)
  (read-jpeg-byte image) ; sample precision
  (let ((height (read-word image))
        (width (read-word image))
        (ncomp (read-jpeg-byte image)))
    (if (arrayp buffer)
        (if (< (length buffer) (* (setf (descriptor-height image) height)
                                  (setf (descriptor-width image) width)
                                  (setf (descriptor-ncomp image) ncomp)))
            (error 'invalid-buffer-supplied :buffer buffer)
            (setf (descriptor-buffer image) buffer))
        (setf (descriptor-buffer image)
              (allocate-buffer (setf (descriptor-height image) height)
                               (setf (descriptor-width image) width)
                               (setf (descriptor-ncomp image) ncomp))))))

;;; Frame decoding subroutine
(defun decode-frame (image buffer)
  (decode-frame-beginning image buffer)
  (read-frame-components image)
  (loop with term fixnum = 0
        until (= term +M_EOI+) do
        (when (/= (interpret-markers image term) +M_SOS+)
          (error 'unsupported-jpeg-frame-marker))
        (setf term (decode-scan image))))

(defun decode-stream (stream &key buffer (colorspace-conversion t) descriptor cached-source-p (decode-frame t))
  "Return image array, height, width, number of components and APP14 Adobe transform.
Supports both baseline and progressive DCT-based JPEGs."
  (when (and (null stream) (not cached-source-p))
    (error 'invalid-buffer-supplied))
  (when descriptor
    (loop for scan across (descriptor-scans descriptor) do ;required if we reuse descriptors
	 (setf (scan-x scan) 0
	       (scan-y scan) 0)))
  (let ((image (or descriptor (make-descriptor))))
    (set-source image stream cached-source-p)
     (unless (= (read-marker image) +M_SOI+)
      (error 'unrecognized-file-format))
     (let ((marker (interpret-markers image 0)))
       (if decode-frame
           (let ((ycck (eql (descriptor-adobe-app14-transform image) :ycck-cmyk)))
             (cond ((= +M_SOF0+ marker)
                    (decode-frame image buffer))
                   ((= +M_SOF2+ marker)
                    (decode-progressive-frame image buffer))
                   (t (error 'unsupported-jpeg-format :code marker)))
             (output-planes image (and colorspace-conversion (not ycck)
                                       (= (descriptor-ncomp image) 3)))
             (when (and colorspace-conversion ycck)
               (ycck-cmyk-convert image)))
           ;; decode-frame-beginning supports baselnie DCT frames
           ;; and progressive DCT frames, so allow those
           (cond ((or (= +M_SOF0+ marker)
                      (= +M_SOF2+ marker))
                  (decode-frame-beginning image nil))
                 (t (error 'unsupported-jpeg-format :code marker)))))
     (release-source image stream)
     (values (when decode-frame
               (descriptor-buffer image))
             (descriptor-height image)
             (descriptor-width image)
             (descriptor-ncomp image)
             (descriptor-adobe-app14-transform image))))

;;; Top level decoder function
(defun decode-image (filename &key buffer (colorspace-conversion t) cached-source-p (decode-frame t))
  (with-open-file (in filename :direction :input :element-type 'uint8)
    (decode-stream in
                   :buffer buffer
                   :colorspace-conversion colorspace-conversion
                   :cached-source-p cached-source-p
                   :decode-frame decode-frame)))

(defun decode-stream-height-width-ncomp (stream &key descriptor cached-source-p)
  "Return the height and width of the JPEG data read from STREAM. Does less work than
DECODE-STREAM and also supports progressive DCT-based JPEGs."
  (multiple-value-bind (nil-buffer height width ncomp adobe-app14-transform)
      (apply #'decode-image stream
             :decode-frame nil
             (append
              (when descriptor
                `(:descriptor ,descriptor))
              (when cached-source-p
                `(:cached-source-p ,cached-source-p))))
    (declare (ignore nil-buffer))
    (values height width ncomp adobe-app14-transform)))

(defun jpeg-file-dimensions (filename)
  "Return image height, width and number of components, plus the type of Adobe colorpsace transform"
  (with-open-file (in filename :direction :input :element-type 'uint8)
    (decode-stream-height-width-ncomp in)))
