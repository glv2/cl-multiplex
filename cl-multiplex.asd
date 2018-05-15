;;;; This file is part of cl-multiplex
;;;; Copyright 2018 Guillaume LE VAILLANT
;;;; Distributed under the GNU GPL v3 or later.
;;;; See the file LICENSE for terms of use and distribution.


(defsystem "cl-multiplex"
  :name "cl-multiplex"
  :description "Multiplexing library for binary data"
  :version "1.0"
  :license "GPL-3"
  :author "Guillaume LE VAILLANT"
  :depends-on ("cl-octet-streams")
  :in-order-to ((test-op (test-op "cl-multiplex/tests")))
  :components ((:file "multiplex")))

(defsystem "cl-multiplex/tests"
  :name "cl-multiples/tests"
  :description "Tests for cl-multiplex"
  :version "1.0"
  :license "GPL-3"
  :author "Guillaume LE VAILLANT"
  :depends-on ("cl-multiplex" "cl-octet-streams" "fiveam")
  :in-order-to ((test-op (load-op "cl-multiplex/tests")))
  :perform (test-op (o s)
                    (let ((tests (uiop:find-symbol* 'cl-multiplex
                                                    :cl-multiplex/tests)))
                      (uiop:symbol-call :fiveam 'run! tests)))
  :components ((:file "tests")))
