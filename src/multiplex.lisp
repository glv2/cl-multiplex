;;;; This file is part of cl-multiplex
;;;; Copyright 2018 Guillaume LE VAILLANT
;;;; Distributed under the GNU GPL v3 or later.
;;;; See the file LICENSE for terms of use and distribution.


(defpackage :cl-multiplex
  (:nicknames :multiplex)
  (:use :cl)
  (:export #:make-multiplex-stream
           #:multiplex
           #:finish-multiplex-output
           #:clear-multiplex-input
           #:demultiplex
           #:write-data
           #:read-data
           #:channel-length
           #:clear-channel-input))

(in-package :multiplex)


(defconstant +initial-buffer-length+ 128)

(defstruct (multiplex-stream (:constructor %make-multiplex-stream))
  stream
  (data (make-array +initial-buffer-length+
                    :element-type '(unsigned-byte 8)
                    :adjustable t))
  (data-length 0)
  current-frame-channel
  current-frame-length
  inputs
  input-starts
  input-ends
  outputs
  output-ends)

(defun make-multiplex-stream (stream channels)
  (let ((inputs (make-array channels))
        (input-starts (make-array channels
                                  :element-type 'unsigned-byte
                                  :initial-element 0))
        (input-ends (make-array channels
                                :element-type 'unsigned-byte
                                :initial-element 0))
        (outputs (make-array channels))
        (output-ends (make-array channels
                                 :element-type 'unsigned-byte
                                 :initial-element 0)))
    (dotimes (i channels)
      (setf (aref inputs i) (make-array +initial-buffer-length+
                                        :element-type '(unsigned-byte 8)
                                        :adjustable t))
      (setf (aref outputs i) (make-array +initial-buffer-length+
                                         :element-type '(unsigned-byte 8)
                                         :adjustable t)))
    (%make-multiplex-stream :stream stream
                            :inputs inputs
                            :input-starts input-starts
                            :input-ends input-ends
                            :outputs outputs
                            :output-ends output-ends)))

(defun multiplex (multiplex-stream)
  (let ((stream (multiplex-stream-stream multiplex-stream))
        (outputs (multiplex-stream-outputs multiplex-stream))
        (ends (multiplex-stream-output-ends multiplex-stream)))
    (flet ((write-integer (n)
             (do* ((l (max 1 (ceiling (integer-length n) 7)) (1- l))
                   (x n (ash x -7)))
                  ((zerop l) n)
               (write-byte (logior (logand x #x7f) (if (= l 1) 0 #x80)) stream))))
      (dotimes (channel (length outputs) t)
        (let ((output (aref outputs channel))
              (end (aref ends channel)))
          (when (plusp end)
            (write-integer channel)
            (write-integer end)
            (write-sequence output stream :end end)
            (setf (aref ends channel) 0)))))))

(defun finish-multiplex-output (multiplex-stream)
  (multiplex multiplex-stream)
  (finish-output (multiplex-stream-stream multiplex-stream)))

(defun clear-multiplex-input (multiplex-stream)
  (clear-input (multiplex-stream-stream multiplex-stream))
  (fill (multiplex-stream-input-starts multiplex-stream) 0)
  (fill (multiplex-stream-input-ends multiplex-stream) 0)
  (setf (multiplex-stream-data-length multiplex-stream) 0)
  (setf (multiplex-stream-current-frame-channel multiplex-stream) nil)
  (setf (multiplex-stream-current-frame-length multiplex-stream) nil))

(defun demultiplex (multiplex-stream)
  (let ((complete-frame-p nil))
    (with-slots (stream
                 data
                 data-length
                 (channel current-frame-channel)
                 (length current-frame-length)
                 inputs
                 (starts input-starts)
                 (ends input-ends))
        multiplex-stream
      (flet ((read-integer ()
               (handler-case
                   (loop
                     (let ((b (read-byte stream)))
                       (when (= data-length (length data))
                         (adjust-array data (1+ data-length)))
                       (setf (aref data data-length) b)
                       (incf data-length)
                       (when (zerop (logand b #x80))
                         (do* ((i 0 (1+ i))
                               (j 0 (+ j 7))
                               (b (aref data i) (aref data i))
                               (n (logand b #x7f) (+ n (ash (logand b #x7f) j))))
                              ((= i (1- data-length)) (return-from read-integer n))))))
                 (end-of-file ()
                   (return-from demultiplex complete-frame-p)))))
        (loop
          (unless channel
            (setf channel (read-integer))
            (setf data-length 0))
          (unless length
            (setf length (read-integer))
            (setf data-length 0))
          (when (< (length data) length)
            (adjust-array data length))
          (let ((input (aref inputs channel))
                (start (aref starts channel))
                (end (aref ends channel)))
            (when (< (- (length input) end) length)
              (replace input input :start2 start)
              (decf end start)
              (setf start 0)
              (setf (aref starts channel) start)
              (setf (aref ends channel) end))
            (when (< (- (length input) end) length)
              (adjust-array input (+ end length)))
            (let ((n (read-sequence data stream :start data-length :end length)))
              (unless (= n length)
                (setf data-length n)
                (return-from demultiplex complete-frame-p)))
            (setf complete-frame-p t)
            (replace input data :start1 end :end2 length)
            (incf (aref ends channel) length)
            (setf data-length 0)
            (setf channel nil)
            (setf length nil)))))))

(defun write-data (data multiplex-stream channel &key (start 0) end)
  (let* ((end (or end (length data)))
         (length (- end start))
         (output (aref (multiplex-stream-outputs multiplex-stream) channel))
         (output-end (aref (multiplex-stream-output-ends multiplex-stream) channel)))
    (when (< (- (length output) output-end) length)
      (adjust-array output (+ (length output) length)))
    (replace output data :start1 output-end :start2 start :end2 end)
    (incf (aref (multiplex-stream-output-ends multiplex-stream) channel) length)
    data))

(defun read-data (data multiplex-stream channel &key (start 0) end)
  (let* ((end (or end (length data)))
         (input (aref (multiplex-stream-inputs multiplex-stream) channel))
         (input-start (aref (multiplex-stream-input-starts multiplex-stream) channel))
         (input-end (aref (multiplex-stream-input-ends multiplex-stream) channel))
         (length (min (- end start) (- input-end input-start))))
    (replace data input :start1 start :end1 end :start2 input-start :end2 input-end)
    (incf (aref (multiplex-stream-input-starts multiplex-stream) channel) length)
    (+ start length)))

(defun channel-length (multiplex-stream channel)
  (- (aref (multiplex-stream-input-ends multiplex-stream) channel)
     (aref (multiplex-stream-input-starts multiplex-stream) channel)))

(defun clear-channel-input (multiplex-stream channel)
  (setf (aref (multiplex-stream-input-starts multiplex-stream) channel) 0)
  (setf (aref (multiplex-stream-input-ends multiplex-stream) channel) 0))
