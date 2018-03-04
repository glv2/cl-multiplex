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
  :components ((:module "src"
                :components ((:file "multiplex")))))
