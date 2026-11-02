(asdf:defsystem :cl-jpeg
  :name "cl-jpeg"
  :version "2.9"
  :license "BSD"
  :description "A self-contained baseline JPEG codec implementation"
  :author "Eugene Zaikonnikov; contributions by Kenan Bölükbaşı, Manuel Giraud, Cyrus Harmon and William Halliburton"
  :components ((:file "package")
	       (:file "jpeg" :depends-on ("package"))
	       (:file "io" :depends-on ("jpeg")))
  :in-order-to ((asdf:test-op (asdf:test-op :cl-jpeg/tests))))

(asdf:defsystem :cl-jpeg/tests
  :description "Tests for cl-jpeg: (asdf:test-system :cl-jpeg)"
  :license "BSD"
  :depends-on (:cl-jpeg)
  :components ((:module "tests" :components ((:file "tests"))))
  :perform (asdf:test-op (o c)
             (unless (uiop:symbol-call :cl-jpeg-tests :run-tests)
               (error "cl-jpeg tests failed"))))
