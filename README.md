[![Build Status](https://travis-ci.org/sharplispers/cl-jpeg.svg?branch=master)](https://travis-ci.org/sharplispers/cl-jpeg)

# CL-JPEG
JPEG codec written in Common Lisp: a baseline encoder, and a decoder for baseline and progressive JPEGs. Up-to-date source is hosted on [GitHub](https://github.com/sharplispers/cl-jpeg).

Written by Eugene Zaikonnikov, 1999-2017. Valuable contributors, in no particular order: Henry Harrington, Kenan Bölükbaşı, Manuel Giraud, Cyrus Harmon and William Halliburton.

## Image Format

* B, G, R pixels in case of colorspace-converted three component image
* Y, Cb, Cr pixels in case where colorspace conversion of three component image was disabled
* array of grayscale pixels in case of single component
* array of 2 or 4 pixels in the case of two or four component image respectively

Pixels are stored row by row in a one-dimensional `(unsigned-byte 8)` array.


## Decoding

The decoder handles baseline (sequential) and progressive JPEGs with 8-bit samples, 1 to 4 components, any sampling factors and restart intervals. Arithmetic coding, 12-bit samples and lossless JPEG are not supported.

Images are decoded one row of MCUs at a time, so apart from the output image a decode needs little memory (tens to hundreds of kilobytes), progressive images included. With a row callback even the output image is not needed. The exceptions: sequential images that store each component in a separate scan need component planes for the whole image, and progressive images keep their compressed data in memory while decoding (no extra copy when decoding from the source cache).

### `(DECODE-IMAGE FILENAME &KEY BUFFER (COLORSPACE-CONVERSION T) CACHED-SOURCE-P SCALE ROW-CALLBACK)`
* FILENAME - jpeg file name
* BUFFER - optional reusable storage for output image
* COLORSPACE-CONVERSION controls if YUV to RGB should be performed
* CACHED-SOURCE-P - read the whole file into memory first (the file is otherwise read in 32 KB chunks)
* SCALE - 1 (default), 1/2, 1/4 or 1/8: decode a reduced image, using reduced inverse DCTs. The returned height and width are the scaled ones, rounded up. Faster, and for progressive images much faster, than decoding at full size.
* ROW-CALLBACK - a function of three arguments, BUFFER, START and Y, called for each row of the image from top to bottom instead of filling an image array: the samples of row Y are the next width × ncomp bytes of BUFFER from START. BUFFER is reused, so the samples are only valid during the call.

Returns (multiple-valued) decoded IMAGE array in the same format as encoder source image (NIL with a row callback), image HEIGHT and image WIDTH.

### `(DECODE-STREAM STREAM &KEY BUFFER (COLORSPACE-CONVERSION T) DESCRIPTOR CACHED-SOURCE-P SCALE ROW-CALLBACK)`
* STREAM - jpeg image stream, or NIL when the data is in the DESCRIPTOR's source cache or comes from its byte reader
* BUFFER, COLORSPACE-CONVERSION, CACHED-SOURCE-P, SCALE, ROW-CALLBACK - as for DECODE-IMAGE
* DESCRIPTOR is a JPEG:DESCRIPTOR structure. Can be reused for performance reasons bulk processing applications. Set its `DESCRIPTOR-SOURCE-CACHE` to an octet vector holding a JPEG file to decode it from memory, or its `DESCRIPTOR-BYTE-READER` to a function returning the next byte of input on each call.

Returns (multiple-valued) decoded IMAGE array in the same format as encoder source image (NIL with a row callback), image HEIGHT and image WIDTH.

A file stream is left positioned just after the decoded image, so several images can be read from one stream.

### Errors

Invalid or unsupported input signals a `JPEG-DECODER-ERROR`. Invalid data signals its subclass `INVALID-JPEG-DATA`, and data ending too early `TRUNCATED-JPEG-DATA` (which is also an `END-OF-FILE`). The decoder is compiled for speed without runtime checks, so header values are validated before use; corrupt or hostile files are expected to signal one of these conditions.

### `(ALLOCATE-BUFFER HEIGHT WIDTH NCOMP)`
* HEIGHT - image height
* WIDTH - image width
* NCOMP - number of image components

Allocates and retruns a buffer suitable for storage of the output image in the specified geometry.

### `(JPEG-FILE-DIMENSIONS FILENAME)`
* FILENAME - the file to be probed

Returns image height, width, number of components, and the type of Adobe colorpsace transform encoded in the image (:YCBCR-RGB, :YCCK-CMYK).

### `(CONVERT-CMYK-TO-RGB BUFFER H W &key RGB-BUFFER)`
* BUFFER - the input CMYK pixel buffer
* H,W - image dimensions
* RGB-BUFFER - optional reusable storage for output RGB image

Returns an RGB conversion of the supplied CMYK image.

###`(JPEG-TO-BMP &key INFILE OUTFILE)`

Converts JPEG file to BMP file.

## Encoding

### `(ENCODE-IMAGE FILENAME IMAGE NCOMP H W &key SAMPLING Q-TABS Q-FACTOR)`
* FILENAME - output file name
* IMAGE - input array of pixels
* NCOMP - number of components in the image
* H, W - image dimensions
* SAMPLING - sampling frequency for ncomp components by X and Y axis, e.g. '((2 2) (1 1) (1 1)) for three components, can be omitted for grayscale and RGB images
* Q-TABS - specifies quantization tables vector, should be 1 for 1, 2 for 2, 2 for 3 and 4 entries for 4 components
* Q-FACTOR - quality specifier (1-64), default is 64

Encodes the supplied image using the sampling specifier, quantization tables and quantization factor.

### `(ENCODING-WRAPPER FILENAME IMAGE NCOMP H W &key (QUALITY 4))`
* FILENAME - output file name
* IMAGE - input array of pixels
* NCOMP - number of components in the image
* H, W - image dimensions
* QUALITY - quality factor on scale from 1 to 5

## SIMD

On SBCL for ARM64 the decoder can use NEON instructions through SBCL's `sb-simd` module for the inverse DCT and color conversion, decoding 1.4 to 2 times as fast. This is opt-in: push `:cl-jpeg-simd` onto `*features*` before cl-jpeg is compiled.

```lisp
(pushnew :cl-jpeg-simd *features*)
(asdf:load-system :cl-jpeg :force t) ; :force recompiles after changing the feature
```

Both versions produce identical output.

## Tests

```lisp
(asdf:test-system :cl-jpeg)
```

The tests use small fixture files in `tests/data` and need no external tools. The `bench/` directory has a benchmark against stb_image and more extensive checks against libjpeg, which need ImageMagick and libjpeg's tools (see `bench/setup.sh`).

## Notes

* Decoded samples are level shifted by 128, as the JPEG standard specifies. Versions before 2.9 shifted by 127, making decoded images one level darker than libjpeg's.

## TODO

* Progressive encoding
